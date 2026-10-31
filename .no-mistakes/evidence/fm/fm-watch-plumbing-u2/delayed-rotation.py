import os, pathlib, shutil, signal, subprocess, time
ROOT = pathlib.Path('/Users/dela/.no-mistakes/worktrees/296f7f7a6690/01M69T3KBCD1G1QNNJGT8JFA3T')
LAB = ROOT / '.test-delayed-rotation'
ENV = {k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX', 'HERDR_SESSION', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND')}
assert not LAB.exists()
LAB.mkdir()
overlay = LAB / 'bin'
overlay.mkdir()
for name in ['fm-watch-droid-background.sh', 'fm-watch-checkpoint.sh']:
    shutil.copy2(ROOT / 'bin' / name, overlay / name)
(overlay / 'fm-supervision-engine-lib.sh').symlink_to(ROOT / 'bin/fm-supervision-engine-lib.sh')
wrapper = overlay / 'fm-watch.sh'
wrapper.write_text('''#!/usr/bin/env bash
set -eu
n=$(cat "$FM_HOME/starts" 2>/dev/null || echo 0)
n=$((n+1))
printf '%s\\n' "$n" > "$FM_HOME/starts"
printf '%s start=%s pid=%s\\n' "$(date +%s)" "$n" "$$" >> "$FM_HOME/launches"
if [ "$n" -ge 4 ]; then sleep 4; fi
exec "''' + str(ROOT / 'bin/fm-watch.sh') + '''" "$@"
''')
wrapper.chmod(0o700)
try:
    for initial in ['absent', 'acked']:
        home = LAB / initial
        subprocess.run(['bash', str(ROOT / 'bin/fm-lab-home.sh'), 'create', str(home)], env=ENV, check=True, capture_output=True)
        (home / 'config/supervision-host-off').touch()
        (home / 'tmp').mkdir()
        marker = 'acked:downtime:previous.1.aaa'
        if initial == 'acked': (home / 'state/.watcher-down').write_text(marker+'\n')
        env = dict(ENV, FM_HOME=str(home), TMPDIR=str(home/'tmp'), FM_DROID_WATCH_CHECKPOINT='10', FM_POLL='1', FM_SIGNAL_GRACE='1', FM_CHECK_INTERVAL='999999', FM_HEARTBEAT='999999')
        with (home / 'stdout').open('w') as out, (home / 'stderr').open('w') as err:
            cycle = subprocess.Popen(['bash', str(overlay/'fm-watch-droid-background.sh')], env=env, stdout=out, stderr=err, start_new_session=True)
        print(f'CASE {initial}: actual Droid cycle/checkpoint, actual watcher; four-second launch delay from start 4; checkpoint=10s', flush=True)
        observed=[]
        try:
            until=time.monotonic()+40
            while len(observed)<3 and time.monotonic()<until:
                assert cycle.poll() is None
                try:
                    pid=int((home/'state/.watch.lock/pid').read_text())
                    os.kill(pid, 0)
                    if (home/'state/.last-watcher-beat').exists() and pid not in observed:
                        observed.append(pid)
                        print(f'live watcher rotation={len(observed)} pid={pid}', flush=True)
                except (FileNotFoundError, ValueError, ProcessLookupError): pass
                time.sleep(.05)
            assert len(observed)==3
            assert not (home/'stdout').read_text() and not (home/'stderr').read_text()
            assert not (home/'state/.wake-queue').exists()
            recovery=home/'state/.watcher-down'
            assert (not recovery.exists()) if initial=='absent' else recovery.read_text().strip()==marker
            os.kill(observed[-1], signal.SIGSTOP)
            appendenv=dict(env, FM_STATE_OVERRIDE=str(home/'state'))
            subprocess.run(['bash','-c','. "$1"; fm_wake_append check concurrent "check: queued during quiet rotation"','_',str(ROOT/'bin/fm-wake-lib.sh')],env=appendenv,check=True)
            pending=recovery.read_text().strip()
            print('Persisted before timeout: '+pending, flush=True)
            print((home/'state/.wake-queue').read_text(), flush=True)
            time.sleep(11)
            try:
                os.kill(observed[-1], signal.SIGCONT)
            except ProcessLookupError:
                print("Timed-out stopped watcher has already exited; successor owns recovery", flush=True)
            rc=cycle.wait(timeout=30)
            text=(home/'stdout').read_text()
            print(f'cycle exit={rc}\nstdout:\n{text}\nstderr:\n'+(home/'stderr').read_text(),flush=True)
            print('actual launch ledger:\n'+(home/'launches').read_text(),flush=True)
            print('final recovery: '+recovery.read_text().strip(),flush=True)
            print('final durable queue:\n'+(home/'state/.wake-queue').read_text(),flush=True)
            assert rc==0 and 'check: rearm-resurface' in text
            assert 'checkpoint: no actionable' not in text
            assert int((home/'starts').read_text())>=4
            assert recovery.read_text().strip()=='announced:'+pending.removeprefix('pending:')
            assert 'check: queued during quiet rotation' in (home/'state/.wake-queue').read_text()
            print('OBSERVED: delayed successor surfaced the retained wake; recovery generation preserved',flush=True)
        finally:
            if cycle.poll() is None:
                os.killpg(cycle.pid, signal.SIGTERM)
                cycle.wait(timeout=10)
finally:
    shutil.rmtree(LAB)
