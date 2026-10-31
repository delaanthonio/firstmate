import json,os,pathlib,subprocess,time
R=pathlib.Path.cwd(); E=pathlib.Path('/Users/dela/.no-mistakes/evidence/01M69KKFF9E37XAEP269Z4Y68R'); prev=json.loads((E/'moved-missing.json').read_text()); H=pathlib.Path(prev['home']); I='moved-missing'; M=H/'state'/f'{I}.meta'
text=f'window=fm-lab-dead:fm-{I}\nbackend=tmux\nworktree={R}/.validation-temp/missing-worktree-{I}\nproject={R}/.validation-temp/missing-project\nharness=claude\nkind=ship\nmode=local-only\nyolo=off\ntasktmp={prev["recorded_temp"]}\n'; M.write_text(text)
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND'): env.pop(k,None)
env.update(FM_HOME=str(H),TMPDIR=str(R/'.validation-temp'),TMUX='.validation-temp/absent-private.sock,0,0')
p=subprocess.run(['bash','.validation-temp/base/bin/fm-teardown.sh',I],env=env,capture_output=True,text=True,timeout=60)
result=dict(command='bash .validation-temp/base/bin/fm-teardown.sh moved-missing',exit=p.returncode,stdout=p.stdout,stderr=p.stderr,meta_unchanged=M.exists() and M.read_text()==text)
(E/'relocation-counterfactual.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result)); assert p.returncode==1 and result['meta_unchanged'] and 'unsafe task temp root' in p.stderr
