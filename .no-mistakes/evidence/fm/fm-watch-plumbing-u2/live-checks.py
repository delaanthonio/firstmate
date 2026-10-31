import concurrent.futures, json, os, pathlib, shlex, subprocess, time
ROOT=pathlib.Path.cwd()
EVID=pathlib.Path('/Users/dela/.no-mistakes/evidence/01M69KKFF9E37XAEP269Z4Y68R')
BASE=ROOT/'.validation-temp'
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND'):
        env.pop(k,None)
env['TMPDIR']=str(BASE)

def run(args,e,stdin=None,timeout=190):
    t=time.monotonic()
    p=subprocess.run(args,env=e,input=stdin,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
    return dict(command=shlex.join(map(str,args)),exit=p.returncode,elapsed_seconds=round(time.monotonic()-t,2),stdout=p.stdout,stderr=p.stderr)

def scenario(mode,ordinary,allowance,delay,sibling_delay=None):
    name=f'{mode}-ordinary{ordinary}-allowance{allowance or "default"}-delay{delay}'
    home=BASE/name
    subprocess.run(['bash',str(ROOT/'bin/fm-lab-home.sh'),'create',str(home)],env=env,check=True,stdout=subprocess.DEVNULL)
    e=env.copy(); e.update(FM_HOME=str(home),FM_POLL='1',FM_SIGNAL_GRACE='1',FM_CHECK_INTERVAL='300',FM_CHECK_TIMEOUT=str(ordinary),FM_HEARTBEAT='999999')
    if allowance is not None: e['FM_CONTRIBUTIONS_CHECK_TIMEOUT']=str(allowance)
    (home/'config/supervision-host-off').touch()
    steps=[]
    check=home/'state/contributions.check.sh'
    check.write_text('#!/usr/bin/env bash\nset -e\nsleep '+str(delay)+'\n'+shlex.quote(str(ROOT/'bin/fm-contributions.sh'))+' poll\nprintf "whole contributions poll completed\\n"\ntouch '+shlex.quote(str(home/'contributions-finished'))+'\n')
    check.chmod(0o700)
    steps.append(run(['bash',str(ROOT/'bin/fm-check-register.sh'),'contributions'],e))
    if sibling_delay:
        check=home/'state/a-ordinary.check.sh'
        check.write_text('#!/usr/bin/env bash\nsleep '+str(sibling_delay)+'\ntouch '+shlex.quote(str(home/'ordinary-finished'))+'\nprintf "ordinary late output\\n"\n')
        check.chmod(0o700)
        steps.append(run(['bash',str(ROOT/'bin/fm-check-register.sh'),'a-ordinary'],e))
    if mode=='guard':
        # A plain, disposable primary root with the shipped scripts and memory.
        subprocess.run(['git','init','-q',str(home)],env=env,check=True)
        (home/'bin').symlink_to(ROOT/'bin',target_is_directory=True)
        (home/'AGENTS.md').symlink_to(ROOT/'AGENTS.md')
        e['FM_ROOT_OVERRIDE']=str(home)
        args=['bash',str(ROOT/'bin/fm-turnend-guard.sh')]
        steps.append(run(args,e,'{"stop_hook_active":false,"session_id":"budget-lab"}'))
    else:
        args=['bash',str(ROOT/'bin/fm-watch-checkpoint.sh'),'--seconds','150' if delay==78 else '12']
        steps.append(run(args,e))
    queue=home/'state/.wake-queue'
    result=dict(name=name,environment={k:v for k,v in e.items() if k.startswith('FM_')},steps=steps,contributions_completed=(home/'contributions-finished').exists(),ordinary_completed=(home/'ordinary-finished').exists(),wake_queue=queue.read_text() if queue.exists() else '',watcher_lock_survived=(home/'state/.watch.lock/pid').exists())
    (EVID/(name+'.json')).write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result),flush=True)
    return result

with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    futures=[pool.submit(scenario,mode,30,None,78,35) for mode in ('guard','watcher')]
    for f in futures: f.result()
# Actively exceed the contributions allowance, then preserve a larger ordinary budget.
for mode in ('guard','watcher'):
    scenario(mode,1,2,6)
    scenario(mode,6,1,3)
    scenario(mode,1,'invalid',3)
