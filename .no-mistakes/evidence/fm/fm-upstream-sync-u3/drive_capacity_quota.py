import json
import os
from pathlib import Path
import subprocess

root = Path.cwd()
lab = root / '.test-phase/quota-home'
for d in ('bin', 'config', 'state', 'data', 'user'):
    (lab / d).mkdir(parents=True, exist_ok=True)
(lab / 'config/lane-capacity').write_text('3\nquota-provider claude\n')
quota = lab / 'bin/quota-axi'
quota.write_text('#!/bin/sh\ncat "${0%/*}/rows.json"\n')
quota.chmod(0o700)
env = {'PATH': str(lab / 'bin') + ':/Users/dela/.local/share/mise/installs/node/24.20.0/bin:' + os.environ['PATH'], 'HOME': str(lab / 'user'), 'FM_HOME': str(lab), 'LC_ALL': 'C', 'TMPDIR': str(root / '.test-phase/tmp'), 'FM_LANE_CAPACITY_PUBLISH_INTERVAL': '0', 'MISE_AUTO_INSTALL': '0'}
def row(account, status):
    return {'provider': 'claude', 'accountKey': account, 'quotaSemantics': {'status': 'known', 'effectiveAvailability': [{'scope': 'all_models', 'status': 'known', 'effectivePercentRemaining': 50, 'runway': {'status': status}}]}}
cases = [('work-first', [row('work', 'exhausted_now'), row('default', 'through_reset')], 'through_reset'), ('default-first', [row('default', 'through_reset'), row('work', 'exhausted_now')], 'through_reset'), ('unmatched', [row('work', 'exhausted_now')], 'unknown'), ('empty', [], 'unknown')]
with Path('/Users/dela/.no-mistakes/evidence/01M6C0X5BHNQ0K1NAZ55FZ12GF/capacity-quota-r2.log').open('w') as log:
    for name, rows, expected in cases:
        snapshot = {'schemaVersion': 6, 'providers': rows}
        (lab / 'bin/rows.json').write_text(json.dumps(snapshot))
        log.write(f'\nInput {name}: {json.dumps(snapshot)}\n')
        for mode in ('--json', '--publish'):
            p = subprocess.run(['bash', 'bin/fm-capacity.sh', mode], env=env, capture_output=True, text=True, timeout=20)
            assert p.returncode == 0, p.stderr
            data = json.loads(p.stdout if mode == '--json' else (lab / 'state/lane-capacity.json').read_text())
            log.write(f'$ FM_HOME=<disposable quota-home> bash bin/fm-capacity.sh {mode}\n')
            log.write(json.dumps({'schema':data['schema'], 'quota': data['quota']}) + '\n')
            assert data['quota'] == {'provider':'claude', 'runway':expected}, data['quota']
