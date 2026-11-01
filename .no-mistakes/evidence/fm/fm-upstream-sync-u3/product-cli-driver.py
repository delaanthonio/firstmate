import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

root = Path.cwd()
base = root / '.test-runtime' / 'product'
base.mkdir()
env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_', 'REX_', 'TASKS_AXI_'))}
env.update(HOME=str(base / 'user'), TMPDIR=str(root / '.test-runtime' / 'tmp'), PYTHONDONTWRITEBYTECODE='1', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')
Path(env['HOME']).mkdir()
home = base / 'home'
for name in ('config', 'data', 'state', 'projects'):
    (home / name).mkdir(parents=True)
env['FM_HOME'] = str(home)

def run(script, *args, expected=0):
    cmd = ['bash', str(root / 'bin' / script), *map(str, args)]
    result = subprocess.run(cmd, env=env, text=True, capture_output=True, timeout=30)
    print('$', script, *args)
    print(result.stdout, end='')
    print(result.stderr, end='')
    print('exit:', result.returncode)
    assert result.returncode == expected, result
    return result.stdout

try:
    print('SCENARIO: capacity counts ships, keeps secondmates outside lane usage, and closes on pressure')
    (home / 'state/ship-a.meta').write_text('kind=ship\npr=https://example.invalid/pr/1\n')
    (home / 'state/scout-b.meta').write_text('kind=scout\n')
    (home / 'state/secondmate.meta').write_text('kind=secondmate\n')
    run('fm-capacity.sh')
    beat = home / 'beat.json'
    document = {'schema': 'lookout.beat', 'schema_version': '1.0', 'host': 'disposable', 'os': 'wsl', 'interval_s': 15,
        'machine': {'id': 'disposable', 'status': 'ok', 'load': {'l1': 0.1, 'runq_per_core': 0.1},
            'mem': {'avail_gb': 16, 'total_gb': 32}, 'disks': [{'label': 'disk', 'free_gb': 100}],
            'uptime_s': 1000, 'on_battery': False, 'pressure': {'level': 'ok', 'why': []}, 'beat': {'errors': []}}}
    beat.write_text(json.dumps(document))
    config = home / 'config/lane-capacity'
    config.write_text(f'4\npressure-file {beat}\n')
    report = json.loads(run('fm-capacity.sh', '--json'))
    assert report['lanes']['count'] == 2 and report['verdict']['free_lanes'] == 2
    run('fm-capacity.sh', '--admit')
    document['machine']['pressure']['level'] = 'critical'
    document['machine']['status'] = 'critical'
    beat.write_text(json.dumps(document))
    report = json.loads(run('fm-capacity.sh', '--json'))
    assert report['verdict']['free_lanes'] == 0 and 'pressure critical' in report['verdict']['reasons']
    run('fm-capacity.sh', '--admit', expected=75)
    config.write_text('4\nunknown-key 1\n')
    run('fm-capacity.sh', '--json', expected=1)

    print('SCENARIO: schema-6 quota joins default account regardless of row order; unmatched stays unknown')
    fakebin = base / 'quota-bin'
    fakebin.mkdir()
    quota = fakebin / 'quota-axi'
    quota.write_text('#!/bin/bash\ncat "${0%/*}/rows.json"\n')
    quota.chmod(0o755)
    env['PATH'] = str(fakebin) + ':' + env['PATH']
    document['machine']['pressure']['level'] = 'ok'
    document['machine']['status'] = 'ok'
    beat.write_text(json.dumps(document))
    config.write_text(f'4\npressure-file {beat}\nquota-provider claude\n')
    def row(key, status):
        return {'provider': 'claude', 'accountKey': key, 'quotaSemantics': {'status': 'known', 'effectiveAvailability': [{'scope': 'all_models', 'status': 'known', 'effectivePercentRemaining': 50, 'runway': {'status': status}}]}}
    work, default = row('work', 'exhausted_now'), row('default', 'through_reset')
    for rows, expected in (([work, default], 'through_reset'), ([default, work], 'through_reset'), ([work], 'unknown')):
        (fakebin / 'rows.json').write_text(json.dumps({'schemaVersion': 6, 'providers': rows}))
        print('quota input:', json.dumps(rows))
        report = json.loads(run('fm-capacity.sh', '--json'))
        assert report['quota']['runway'] == expected
        env['FM_LANE_CAPACITY_PUBLISH_INTERVAL'] = '0'
        run('fm-capacity.sh', '--publish')
        persisted = json.loads((home / 'state/lane-capacity.json').read_text())
        print('published quota:', persisted['quota'])
        assert persisted['quota']['runway'] == expected

    print('SCENARIO: record sync copies owned allowlist, retracts retired records, and rejects symlink escape')
    export = base / 'export'
    (home / 'config/record-export-root').write_text(str(export) + '\n')
    (home / 'data/projects.md').write_text('Synthetic project registry\n')
    (home / 'data/private.txt').write_text('MUST NOT EXPORT\n')
    (home / 'data/task-a').mkdir()
    (home / 'data/task-a/brief.md').write_text('Synthetic task brief\n')
    (home / 'state/task-a.meta').write_text('kind=ship\nspawn_gen=fixture-generation\n')
    run('fm-record-export.sh', 'sync')
    print('exported registry:', (export / 'live/data/projects.md').read_text().strip())
    assert not (export / 'live/data/private.txt').exists()
    assert (export / 'live/state/task-a.meta').exists()
    (home / 'state/task-a.meta').unlink()
    run('fm-record-export.sh', 'sync')
    assert not (export / 'live/state/task-a.meta').exists()
    print('retired task metadata absent from current snapshot')
    print('SCENARIO: archive commits an integrity manifest and retries idempotently')
    (home / 'state/task-a.meta').write_text('kind=ship\nspawn_gen=fixture-generation\n')
    (home / 'state/task-a.status').write_text('completed synthetic task\n')
    (home / 'state/task-a.inbox').mkdir()
    (home / 'state/task-a.inbox/001.msg').write_text('synthetic steering message\n')
    run('fm-record-export.sh', 'archive-task', 'task-a')
    generation = export / 'archive/task-a/fixture-generation'
    manifest = generation / 'manifest.v1.json'
    before = manifest.read_bytes()
    print('committed archive manifest:', before.decode())
    persisted = json.loads(before)
    for entry in persisted['files']:
        content = (generation / entry['archive']).read_bytes()
        assert len(content) == entry['bytes'] and hashlib.sha256(content).hexdigest() == entry['sha256']
    run('fm-record-export.sh', 'archive-task', 'task-a')
    assert manifest.read_bytes() == before
    print('archive retry preserved the complete integrity manifest byte for byte')
    sentinel = base / 'external-sentinel'
    sentinel.write_text('UNCHANGED SENTINEL\n')
    registry = home / 'data/projects.md'
    registry.unlink()
    registry.symlink_to(sentinel)
    run('fm-record-export.sh', 'sync', expected=1)
    assert sentinel.read_text() == 'UNCHANGED SENTINEL\n'
    assert (export / 'live/data/projects.md').read_text() == 'Synthetic project registry\n'
    print('outside sentinel and prior complete export preserved')

    print('SCENARIO: default role refuses self-repo publication; fork consent authorizes only the fork')
    run('fm-role.sh', 'report')
    run('fm-role.sh', 'check', root, expected=1)
    run('fm-role.sh', 'check', root, 'upstream-consent', 'github.com/kunchenguid/firstmate', expected=1)
    run('fm-role.sh', 'check', root, 'upstream-consent', 'github.com/delaanthonio/firstmate')
    print('All manual product assertions passed.')
finally:
    shutil.rmtree(base)
    print('Disposable product home removed.')
