import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess

root = Path.cwd()
work = root / '.test-phase/manual'
evidence = Path('/Users/dela/.no-mistakes/evidence/01M6C0X5BHNQ0K1NAZ55FZ12GF')
work.mkdir(parents=True, exist_ok=True)
log = (evidence / 'product-cli-r2.log').open('w')
env = {k: v for k, v in os.environ.items() if k in ('PATH', 'LANG', 'LC_ALL', 'TERM', 'NO_MISTAKES_GATE')}
env.update(HOME=str(work / 'user'), TMPDIR=str(root / '.test-phase/tmp'), LC_ALL='C')
Path(env['HOME']).mkdir(exist_ok=True)

def home(name):
    p = work / name
    for d in ('data', 'state', 'config', 'projects'):
        (p / d).mkdir(parents=True, exist_ok=True)
    return p

def put(p, text):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)

def show(text):
    log.write(text + '\n')
    log.flush()

def run(h, command, expected=0):
    e = dict(env, FM_HOME=str(h))
    show('$ FM_HOME=' + shlex.quote(str(h)) + ' ' + shlex.join(command))
    r = subprocess.run(command, cwd=root, env=e, text=True, capture_output=True, timeout=45)
    show(r.stdout.rstrip())
    if r.stderr:
        show('stderr: ' + r.stderr.rstrip())
    show('exit=' + str(r.returncode))
    assert r.returncode == expected, (command, r.returncode, r.stderr)
    return r

# Real filesystem exporter, no tool or production function replacement.
h = home('export-home')
x = work / 'export-destination'
put(h / 'data/projects.md', 'synthetic project registry\n')
put(h / 'data/secret.txt', 'must stay private\n')
put(h / 'data/task-a/brief.md', 'synthetic brief\n')
put(h / 'state/task-a.meta', 'task=task-a\nspawn_gen=lab-generation-1\nkind=ship\n')
put(h / 'state/task-a.status', 'working: preparing\ndone: landed\n')
put(h / 'state/task-a.inbox/001.msg', 'synthetic pending message\n')
put(h / 'state/task-a.inbox/handled/002.msg', 'synthetic handled message\n')
cmd = ['bash', 'bin/fm-record-export.sh']
r = run(h, cmd + ['sync'])
assert not r.stdout and not r.stderr and not x.exists()
put(h / 'config/record-export-root', str(x) + '\n')
run(h, cmd + ['sync'])
assert (x / 'live/data/projects.md').read_bytes() == (h / 'data/projects.md').read_bytes()
assert not (x / 'live/data/secret.txt').exists()
old = (x / 'live').resolve()
put(h / 'data/projects.md', 'updated synthetic registry\n')
run(h, cmd + ['sync'])
assert (x / 'live/data/projects.md').read_text() == 'updated synthetic registry\n'
assert (old / 'data/projects.md').read_text() == 'synthetic project registry\n'
show('Published live snapshot: ' + str((x / 'live').readlink()))
show('Live projects.md: ' + (x / 'live/data/projects.md').read_text().rstrip())
show('Allowlist exclusion: data/secret.txt absent; prior generation still readable.')
run(h, cmd + ['archive-task', 'task-a'])
a = x / 'archive/task-a/lab-generation-1'
m = json.loads((a / 'manifest.v1.json').read_text())
for f in m['files']:
    b = (a / f['archive']).read_bytes()
    assert b == (h / f['source']).read_bytes()
    assert len(b) == f['bytes'] and hashlib.sha256(b).hexdigest() == f['sha256']
show('Archive manifest: ' + json.dumps(m, indent=2))
(evidence / 'archive-manifest-r2.json').write_text(json.dumps(m, indent=2) + '\n')
before = (a / 'manifest.v1.json').read_bytes()
run(h, cmd + ['archive-task', 'task-a'])
assert (a / 'manifest.v1.json').read_bytes() == before
show('Retry preserves the committed manifest byte-for-byte.')

# Adversarial traversal and committed-generation corruption.
sentinel = work / 'external-fixture-sentinel'
put(sentinel, 'outside fixture sentinel\n')
(h / 'data/projects.md').unlink()
(h / 'data/projects.md').symlink_to(sentinel)
r = run(h, cmd + ['sync'], expected=1)
assert 'symlink' in r.stderr.lower() or 'regular file' in r.stderr.lower()
assert sentinel.read_text() == 'outside fixture sentinel\n'
assert (x / 'live/data/projects.md').read_text() == 'updated synthetic registry\n'
put(a / 'status', 'corrupted archive bytes\n')
r = run(h, cmd + ['archive-task', 'task-a'], expected=1)
assert (a / 'manifest.v1.json').read_bytes() == before
assert (h / 'state/task-a.meta').exists()
show('Refusals preserve the last published snapshot, sentinel, manifest, and source metadata.')

# Real CLI + real host probes + explicit synthetic lookout input.
h = home('capacity-home')
put(h / 'state/ship-a.meta', 'kind=ship\n')
put(h / 'state/secondmate-a.meta', 'kind=secondmate\n')
cc = ['bash', 'bin/fm-capacity.sh']
r = run(h, cc)
assert 'reason=no-target lanes=1 target=none secondmates=1' in r.stdout
beat = {'schema': 'lookout.beat', 'schema_version': '1.0', 'host': 'disposable-lab', 'os': 'darwin', 'interval_s': 15,
        'machine': {'id': 'lab', 'status': 'ok', 'load': {'l1': 0.5, 'runq_per_core': 0.1},
                    'mem': {'avail_gb': 20, 'total_gb': 32, 'swap_rate_pps_1m': 0},
                    'disks': [{'label': 'lab', 'free_gb': 500}], 'on_battery': False,
                    'pressure': {'level': 'ok', 'why': []}, 'beat': {'errors': []}}}
put(h / 'beat.json', json.dumps(beat))
put(h / 'config/lane-capacity', f'3\nmin-avail-gb 2\nmin-disk-gb 10\nmax-load1 10\npressure-file {h}/beat.json\nreserve-flag {h}/reserved.flag maintenance\n')
r = run(h, cc + ['--json'])
d = json.loads(r.stdout)
assert d['lanes']['count'] == 1 and d['verdict']['admit'] and d['verdict']['free_lanes'] == 2
run(h, cc + ['--admit'])
run(h, cc + ['--publish'])
published = json.loads((h / 'state/lane-capacity.json').read_text())
assert published['verdict']['admit']
(evidence / 'capacity-published-r2.json').write_text(json.dumps(published, indent=2) + '\n')
put(h / 'reserved.flag', '')
run(h, cc + ['--admit'], expected=75)
put(h / 'config/lane-capacity', '3\nunknown-setting 2\n')
run(h, cc + ['--admit'], expected=1)

# Generate a delivery contract, without creating a worker or publishing.
h = home('brief-home')
bc = ['bash', 'bin/fm-brief.sh']
run(h, bc + ['lab-brief', 'synthetic-repo', '--mode', 'no-mistakes', '--pr', 'manual', '--branch-prefix', 'sync/'])
brief = (h / 'data/lab-brief/brief.md').read_text()
show('Generated delivery brief:\n' + brief)
(evidence / 'generated-brief-r2.md').write_text(brief)
assert 'Ship branch: sync/lab-brief' in brief and 'pr=manual' in brief
assert 'gh-axi' in brief and 'Summary' in brief and 'What changed' in brief and 'Why' in brief and 'How it was tested' in brief
run(h, bc + ['invalid-brief', 'synthetic-repo', '--mode', 'local-only', '--forge', 'external'], expected=1)
assert not (h / 'data/invalid-brief/brief.md').exists()
show('COMPLETE: live export, archive safety, capacity admission/publication, and brief generation/refusal.')
log.close()
