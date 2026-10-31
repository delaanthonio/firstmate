import json,os,pathlib,shlex,subprocess,time
ROOT=pathlib.Path.cwd(); BASE=ROOT/'.validation-temp'; EVID=pathlib.Path('/Users/dela/.no-mistakes/evidence/01M69KKFF9E37XAEP269Z4Y68R')
e=os.environ.copy()
for k in list(e):
    if k.startswith('FM_') or k in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND'): e.pop(k,None)
e['TMPDIR']=str(BASE)
e['TMUX']='.validation-temp/absent-private.sock,0,0'
home=BASE/'relocation-old'
subprocess.run(['bash','bin/fm-lab-home.sh','create',str(home)],env=e,check=True)
e['FM_HOME']=str(home)
p=subprocess.run(['bash','-c','. bin/fm-backend-hometag-lib.sh; fm_backend_hometag'],env=e,text=True,capture_output=True,check=True)
tag=p.stdout.strip(); moved=BASE/'relocation-moved'; home.rename(moved); home=moved; e['FM_HOME']=str(home)
(home/'config/backlog-backend').write_text('manual\n')
for id,target in [('moved-missing',f'/tmp/fm-{tag}/moved-missing'),('unsafe-recorded','/tmp'),('unsafe-task',f'/tmp/fm-{tag}/other-task'),('unsafe-foreign','/tmp/fm-2ndmate-foreign-12345678/unsafe-foreign')]:
    meta=home/'state'/f'{id}.meta'
    text=f'window=fm-lab-dead:fm-{id}\nbackend=tmux\nworktree={BASE}/missing-worktree-{id}\nproject={BASE}/missing-project\nharness=claude\nkind=ship\nmode=local-only\nyolo=off\ntasktmp={target}\n'
    meta.write_text(text)
    start=time.monotonic(); args=['bash','bin/fm-teardown.sh',id]
    p=subprocess.run(args,env=e,text=True,capture_output=True,timeout=60)
    result=dict(name=id,command=shlex.join(args),home=str(home),recorded_temp=target,exit=p.returncode,elapsed_seconds=round(time.monotonic()-start,2),stdout=p.stdout,stderr=p.stderr,meta_present=meta.exists(),meta_unchanged=meta.exists() and meta.read_text()==text)
    (EVID/(id+'.json')).write_text(json.dumps(result,indent=2)+'\n'); print(json.dumps(result),flush=True)
