import json, os, pathlib, shutil, subprocess, time

ROOT = pathlib.Path('/Users/dela/.no-mistakes/worktrees/296f7f7a6690/01M69T3KBCD1G1QNNJGT8JFA3T')
FIXTURES = ROOT / '.test-watch-plumbing-live'
BASE_ENV = {k: v for k, v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX', 'HERDR_SESSION', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND')}
BASE_ENV['GIT_CONFIG_GLOBAL'] = '/dev/null'
BASE_ENV['GIT_CONFIG_NOSYSTEM'] = '1'


def run_case(name, ordinary, allowance, duration, sibling=False, checkpoint=False):
    home = FIXTURES / name
    env = dict(BASE_ENV, FM_HOME=str(home))
    subprocess.run(['bash', str(ROOT / 'bin/fm-lab-home.sh'), 'create', str(home)], env=env, check=True, capture_output=True)
    (home / 'config/supervision-host-off').touch()
    (home / 'tmp').mkdir()
    env['TMPDIR'] = str(home / 'tmp')
    if ordinary is not None:
        env['FM_CHECK_TIMEOUT'] = str(ordinary)
    if allowance is not None:
        env['FM_CONTRIBUTIONS_CHECK_TIMEOUT'] = str(allowance)
    env.update(FM_CHECK_INTERVAL='300', FM_POLL='1', FM_HEARTBEAT='999999')
    if not checkpoint:
        subprocess.run(['git', 'init', '-q', str(home)], env=env, check=True)
        (home / 'AGENTS.md').touch()
        (home / 'bin').mkdir()
        env['FM_ROOT_OVERRIDE'] = str(home)
    for check_id in (['contributions', 'ordinary'] if sibling else ['contributions']):
        script = home / f'state/{check_id}.check.sh'
        script.write_text(f'#!/usr/bin/env bash\nsleep {duration}\nprintf "{check_id}: workload completed after {duration}s\\n"\n')
        script.chmod(0o700)
        reg = subprocess.run(['bash', str(ROOT / 'bin/fm-check-register.sh'), check_id], env=env, capture_output=True, text=True, check=True)
        print(reg.stdout.strip(), flush=True)
    cmd = ['bash', str(ROOT / ('bin/fm-watch-checkpoint.sh' if checkpoint else 'bin/fm-turnend-guard.sh'))]
    if checkpoint:
        cmd += ['--seconds', '105']
    print(f'\nCASE {name}: ordinary={ordinary if ordinary is not None else "unset (upstream 30s)"}, contributions={allowance!r}, registered workload={duration}s, sibling={sibling}', flush=True)
    print('EXEC ' + ' '.join(cmd), flush=True)
    started = time.monotonic()
    result = subprocess.run(cmd, input='{"stop_hook_active":false}', capture_output=True, text=True, env=env, timeout=130)
    elapsed = time.monotonic() - started
    print(f'exit={result.returncode}; elapsed={elapsed:.2f}s\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}', flush=True)
    queue_file = home / 'state/.wake-queue'
    queue = queue_file.read_text() if queue_file.exists() else ''
    print('PERSISTED WAKE QUEUE:\n' + (queue or '(absent)'), flush=True)
    success = name in ('explicit-120-real-78', 'tuned-with-ordinary-sibling', 'larger-ordinary-budget')
    if success:
        assert 'contributions: workload completed' in queue
        assert result.returncode == (0 if checkpoint else 2)
        if sibling:
            assert 'ordinary: workload completed' not in queue
            assert 'timed out after 1s:' in result.stderr
    else:
        assert 'workload completed' not in queue
        expected = max(ordinary or 30, int(allowance)) if allowance and str(allowance).isdigit() and not str(allowance).startswith("0") else ordinary or 30
        assert f'timed out after {expected}s:' in result.stderr
        assert elapsed < expected + 6
    print(f'OBSERVED {name}: expected runtime and durable-wake behavior confirmed', flush=True)
    shutil.rmtree(home)


assert not FIXTURES.exists()
FIXTURES.mkdir()
try:
    run_case('explicit-120-real-78', None, 120, 78, checkpoint=True)
    run_case('untuned-upstream-30', None, None, 32)
    run_case('tuned-with-ordinary-sibling', 1, 4, 2, sibling=True)
    run_case('larger-ordinary-budget', 4, 1, 2)
    for name, value in [('unset', None), ('empty', ''), ('zero', '0'), ('leading-zero', '01'), ('negative', '-1'), ('invalid', 'invalid')]:
        run_case('fallback-' + name, 1, value, 2)
    run_case('explicit-bound', 1, 2, 4)
finally:
    shutil.rmtree(FIXTURES)
