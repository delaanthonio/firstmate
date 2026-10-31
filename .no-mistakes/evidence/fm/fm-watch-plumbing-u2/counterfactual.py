import json,os,pathlib,shlex,subprocess,time
ROOT=pathlib.Path.cwd(); BASE=ROOT/'.validation-temp'; EVID=pathlib.Path('/Users/dela/.no-mistakes/evidence/01M69KKFF9E37XAEP269Z4Y68R')
e=os.environ.copy()
for k in list(e):
    if k.startswith('FM_') or k in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND'): e.pop(k,None)
e['TMPDIR']=str(BASE)
results=[]
for version,code in [('base',BASE/'base'),('target',ROOT)]:
    home=BASE/f'counterfactual-{version}'; (home/'state').mkdir(parents=True); (home/'config').mkdir(); (home/'data').mkdir()
    (home/'bin').symlink_to(code/'bin',target_is_directory=True); (home/'AGENTS.md').symlink_to(ROOT/'AGENTS.md')
    subprocess.run(['git','init','-q',str(home)],env=e,check=True)
    check=home/'state/contributions.check.sh'; check.write_text('#!/usr/bin/env bash\nsleep 3\nprintf "completed contributions poll\\n"\n'); check.chmod(0o700)
    ce=e.copy(); ce.update(FM_HOME=str(home),FM_ROOT_OVERRIDE=str(home),FM_CHECK_TIMEOUT='1')
    subprocess.run(['bash',str(code/'bin/fm-check-register.sh'),'contributions'],env=ce,check=True,capture_output=True)
    command=['bash',str(code/'bin/fm-turnend-guard.sh')]; start=time.monotonic()
    p=subprocess.run(command,input='{"stop_hook_active":false}',env=ce,capture_output=True,text=True,timeout=30)
    queue=home/'state/.wake-queue'
    result=dict(version=version,command=shlex.join(command),exit=p.returncode,elapsed_seconds=round(time.monotonic()-start,2),stdout=p.stdout,stderr=p.stderr,wake_queue=queue.read_text() if queue.exists() else '')
    results.append(result)
(EVID/'counterfactual.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
assert not results[0]['wake_queue'] and 'timed out' in results[0]['stderr']
assert 'completed contributions poll' in results[1]['wake_queue']
