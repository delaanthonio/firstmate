import os
from pathlib import Path
import shutil
import subprocess

root = Path.cwd()
lab = root / '.test-phase/rex-guard'
lab.mkdir(parents=True, exist_ok=True)
bin = lab / 'bin'
bin.mkdir(exist_ok=True)
if not (bin / 'jq').exists():
    (bin / 'jq').symlink_to(shutil.which('jq'))
env = {'PATH': str(bin) + ':/usr/bin:/bin', 'HOME': str(lab), 'TMPDIR': str(root / '.test-phase/tmp'), 'LC_ALL': 'C', 'FM_TEST_SKIP_ORPHAN_REAP': '1'}
log = Path('/Users/dela/.no-mistakes/evidence/01M6C0X5BHNQ0K1NAZ55FZ12GF/rex-gate-cli-r2.log').open('w')
assert subprocess.run(['/bin/bash', '-c', 'command -v rex'], env=env, capture_output=True).returncode != 0
cases = [({},0,'skip: live: rex absent'), ({'FM_REX_COMPOSER_LIVE':'1'},1,'rex'), ({'FM_LIVE':'1'},1,'rex'), ({'FM_REX_COMPOSER_LIVE':'0','FM_LIVE':'1'},0,'disabled by FM_REX_COMPOSER_LIVE=0'), ({'FM_REX_COMPOSER_LIVE':'1','FM_LIVE':'0'},1,'rex')]
try:
    for settings, code, needle in cases:
        p = subprocess.run(['/bin/bash', 'tests/fm-backend-rex-composer-live-e2e.test.sh'], env=dict(env, **settings), capture_output=True, text=True, timeout=20)
        log.write(f'$ {settings or "unset guard variables"} /bin/bash tests/fm-backend-rex-composer-live-e2e.test.sh\n{p.stdout}{p.stderr}exit={p.returncode}\n')
        log.flush()
        assert p.returncode == code, (settings, p.stdout, p.stderr, p.returncode)
        assert needle in p.stdout + p.stderr, (needle, p.stdout, p.stderr)
finally:
    log.close()
