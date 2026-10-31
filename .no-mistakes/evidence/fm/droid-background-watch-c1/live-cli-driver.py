import os, pathlib, subprocess, time, signal, json, shutil
ROOT=pathlib.Path.cwd()
E=pathlib.Path('/Users/dela/.no-mistakes/evidence/01M694GRQYDD44K8ZT36BVTW8R')
log=(E/'live-cli-transcript.txt').open('w',buffering=1)
def note(s):
 print(s,flush=True); log.write(s+'\n')
def home(name):
 h=ROOT/'.validation'/name
 for d in ('state','config','data','projects','tmp'): (h/d).mkdir(parents=True,exist_ok=True)
 return h
def env(h,**extra):
 e=os.environ.copy()
 for k in ('FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_TEST_SEAM','FM_GATE_REFUSE_BYPASS'): e.pop(k,None)
 e.update(FM_HOME=str(h),TMPDIR=str(h/'tmp'),FM_POLL='1',FM_SIGNAL_GRACE='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999')
 e.update(extra); return e
def run(args,h,**extra):
 r=subprocess.run([str(x) for x in args],env=env(h,**extra),capture_output=True,text=True,timeout=30)
 note('$ '+' '.join(str(x) for x in args)+'\nexit='+str(r.returncode)+'\nstdout:\n'+r.stdout+'stderr:\n'+r.stderr)
 return r
def read(p):
 try:return p.read_text()
 except FileNotFoundError:return ''
def wait_pid(h,last='',timeout=10):
 end=time.monotonic()+timeout
 while time.monotonic()<end:
  v=read(h/'state/.watch.lock/pid').strip()
  if v and v!=last and (h/'state/.last-watcher-beat').exists():
   try:os.kill(int(v),0);return v
   except ProcessLookupError:pass
  time.sleep(.05)
 raise AssertionError('watcher did not acquire a new lock')
def stop(p):
 if p.poll() is None:
  os.killpg(p.pid,signal.SIGINT)
  try:p.wait(timeout=10)
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
for initial in ('absent','acked'):
 h=home('live-'+initial); marker='acked:downtime:previous.1.aaa\n'
 if initial=='acked':(h/'state/.watcher-down').write_text(marker)
 with (h/'out').open('w') as out,(h/'err').open('w') as err:
  note('\nSCENARIO: quiet rotations, recovery='+initial)
  p=subprocess.Popen([str(ROOT/'bin/fm-watch-droid-background.sh')],env=env(h,FM_DROID_WATCH_CHECKPOINT='3'),stdout=out,stderr=err,start_new_session=True)
  stopped=None
  try:
   old=''
   for rotation in range(1,4):
    old=wait_pid(h,old)
    note(json.dumps({'cycle_pid':p.pid,'checkpoint':rotation,'watcher_pid':old,'cycle_running':p.poll() is None,'stdout_bytes':(h/'out').stat().st_size,'stderr_bytes':(h/'err').stat().st_size,'queue':read(h/'state/.wake-queue'),'recovery':read(h/'state/.watcher-down')}))
    assert p.poll() is None and not read(h/'out') and not read(h/'err') and not read(h/'state/.wake-queue')
    assert read(h/'state/.watcher-down')==('' if initial=='absent' else marker)
   stopped=int(old);os.kill(stopped,signal.SIGSTOP)
   note('Paused watcher '+old+' across checkpoint timeout; appending a durable real wake through fm_wake_append.')
   r=run(['bash','-c','. "$1"; fm_wake_append check concurrent "check: event queued during rotation"','_',ROOT/'bin/fm-wake-lib.sh'],h)
   assert r.returncode==0
   pending=read(h/'state/.watcher-down')
   time.sleep(4)
   try:os.kill(stopped,signal.SIGCONT)
   except ProcessLookupError:pass
   stopped=None
   p.wait(timeout=20)
   note('cycle exit='+str(p.returncode)+'\nstdout:\n'+read(h/'out')+'stderr:\n'+read(h/'err'))
   note('durable queue:\n'+read(h/'state/.wake-queue')+'recovery:\n'+read(h/'state/.watcher-down'))
   assert p.returncode==0 and 'check: rearm-resurface' in read(h/'out') and 'checkpoint:' not in read(h/'out')
   assert 'event queued during rotation' in read(h/'state/.wake-queue')
   assert read(h/'state/.watcher-down')==pending.replace('pending:','announced:',1)
  finally:
   if stopped:
    try:os.kill(stopped,signal.SIGCONT)
    except ProcessLookupError:pass
   stop(p)
h=home('live-failure')
with (h/'watch-out').open('w') as out,(h/'watch-err').open('w') as err:
 note('\nSCENARIO: real singleton failure terminates at configured retry bound')
 watcher=subprocess.Popen([str(ROOT/'bin/fm-watch.sh')],env=env(h),stdout=out,stderr=err,start_new_session=True)
 try:
  wait_pid(h)
  r=run([ROOT/'bin/fm-watch-droid-background.sh'],h,FM_DROID_WATCH_CHECKPOINT='3',FM_DROID_BG_CYCLE_MAX_FAILURES='2')
  assert r.returncode==1 and r.stdout.count('watcher: already running')==2 and 'failed 2 consecutive times; exiting with code 1' in r.stderr
 finally:stop(watcher)
h=home('live-fallback')
note('\nSCENARIO: ordinary foreground fallback retains bounded timeout and downtime recovery')
r=run([ROOT/'bin/fm-watch-checkpoint.sh','--seconds','2'],h)
assert r.returncode==124 and 'checkpoint: no actionable wake within 2s' in r.stdout
note('fallback recovery: '+read(h/'state/.watcher-down'))
assert read(h/'state/.watcher-down').startswith('pending:downtime:')
for posture in ('away','quiet'):
 h=home('live-'+posture);(h/'state/.afk').write_text(posture+'\n')
 note('\nSCENARIO: Droid rotation preserves '+posture+' cleanup and posture')
 r=run([ROOT/'bin/fm-watch-checkpoint.sh','--seconds','2'],h,FM_DROID_BACKGROUND_CYCLE='1')
 note('posture: '+read(h/'state/.afk')+'recovery: '+read(h/'state/.watcher-down'))
 assert r.returncode==124 and read(h/'state/.afk')==posture+'\n' and read(h/'state/.watcher-down').startswith('pending:downtime:')
h=home('live-policy')
for command,expected in [('bin/fm-watch-droid-background.sh',0),('bin/fm-watch-droid-background.sh &',2),('nohup bin/fm-watch-droid-background.sh',2)]:
 note('\nSCENARIO: tracked Execute payload policy: '+command)
 r=subprocess.run([str(ROOT/'bin/fm-arm-pretool-check.sh')],input=json.dumps({'tool_name':'Execute','tool_input':{'command':command,'fireAndForget':True}}),text=True,capture_output=True,env=env(h))
 note('exit='+str(r.returncode)+'\nstdout:\n'+r.stdout+'stderr:\n'+r.stderr)
 assert r.returncode==expected
note('\nAll independent live CLI assertions passed. Native Droid completion remains unproven: isolated interactive Droid requires login.')
