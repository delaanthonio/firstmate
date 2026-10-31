import os,pathlib,subprocess,json,time,shlex
ROOT=pathlib.Path.cwd();LAB=ROOT/'.l';E=pathlib.Path('/Users/dela/.no-mistakes/evidence/01M69Q3VH6Y1QYYGN31B26JEJ7');log=open(E/'live-spawn.log','w',buffering=1)
env=os.environ.copy()
for key in list(env):
 if key.startswith('FM_') or key in ('TMUX','GIT_DIR','GIT_COMMON_DIR','GIT_WORK_TREE','GIT_INDEX_FILE'):env.pop(key,None)
env.update(FM_HOME=str(LAB),HOME=str(LAB),SHELL='/bin/bash',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Lab',GIT_AUTHOR_EMAIL='lab@example.invalid',GIT_COMMITTER_NAME='Lab',GIT_COMMITTER_EMAIL='lab@example.invalid',UV_CACHE_DIR=str(LAB/'cache/uv'),UV_PYTHON_DOWNLOADS='never',UV_NO_MANAGED_PYTHON='1',TREEHOUSE_ROOT=str(LAB/'pool'),TMUX_TMPDIR=str(LAB/'tmux'),TERM='xterm-256color')
def run(args,cwd=ROOT,ok=True,extra=None,timeout=150):
 log.write('$ '+shlex.join(list(map(str,args)))+'\n')
 p=subprocess.run(list(map(str,args)),cwd=cwd,env=env|(extra or {}),stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=timeout)
 log.write(p.stdout+f'[exit {p.returncode}]\n')
 if ok and p.returncode:raise RuntimeError(p.stdout)
 return p
def check(v,msg):
 log.write(('PROVEN: ' if v else 'FAIL: ')+msg+'\n')
 if not v:raise AssertionError(msg)
def write(p,s):p.parent.mkdir(parents=True,exist_ok=True);p.write_text(s)
(LAB/'tmux').mkdir(exist_ok=True)
tmux=['tmux','-L','fm-lab']
try:
 run(tmux+['-f','/dev/null','new-session','-d','-s','driver','-x','120','-y','40','-c',str(ROOT),'/bin/bash --noprofile --norc'])
 run(tmux+['set-option','-g','default-shell','/bin/bash']);run(tmux+['set-option','-g','default-command','/bin/bash --noprofile --norc'])
 env['TMUX']=run(tmux+['display-message','-p','-t','driver','#{socket_path},#{pid},0']).stdout.splitlines()[0]
 # Seed private clone with real locked dev dependencies and local origin.
 project=LAB/'projects'/'python';run(['git','clone',LAB/'cases/python/project',project]);run(['git','-C',project,'remote','set-url','origin',str(LAB/'cases/python/project')])
 # Scaffold required task interfaces, fill the requested trivial raw-command proof.
 def brief(id,scout=True):
  run([ROOT/'bin/fm-brief.sh',id,'python']+(['--scout'] if scout else ['--mode','local-only']))
  b=LAB/'data'/id/'brief.md';s=b.read_text().replace('{TASK}','Prove dependency tools are present before worker code starts.').replace('{FIRSTMATE_SPEC}','Run the supervised validation command only; no source changes or publication.');b.write_text(s)
 # Raw launch is a supported executable interface: real worker checks its dev tool immediately.
 worker="bash -c '.venv/bin/basedpyright --version && printf \"WORKER_BOOTSTRAPPED\\n\" > \"$FM_HOME/state/$FM_TASK_ID.proof\"'"
 brief('live-scout')
 r=run([ROOT/'bin/fm-spawn.sh','live-scout',project,'--scout',worker,'--backend','tmux'])
 check('spawned live-scout' in r.stdout,'scout spawn completed via real tmux and treehouse')
 for _ in range(80):
  if (LAB/'state/live-scout.proof').exists():break
  time.sleep(.25)
 check((LAB/'state/live-scout.proof').exists(),'first worker command could run basedpyright from its isolated worktree')
 run(tmux+['capture-pane','-p','-t','driver:fm-live-scout','-S','-100'])
 meta=dict(line.split('=',1) for line in (LAB/'state/live-scout.meta').read_text().splitlines() if '=' in line);wt=pathlib.Path(meta['worktree'])
 check((wt/'.venv/bin/basedpyright').exists() and not(project/'.venv').exists(),'published task uses bootstrapped isolated copy, primary clone unchanged')
 # Already-stopped raw worker relaunch: remove dependency output to actively break cached success.
 import shutil
 shutil.rmtree(wt/'.venv');(LAB/'state/live-scout.proof').unlink()
 r=run([ROOT/'bin/fm-spawn.sh','live-scout','--relaunch','--harness',worker])
 for _ in range(80):
  if (LAB/'state/live-scout.proof').exists():break
  time.sleep(.25)
 check((LAB/'state/live-scout.proof').exists(),'replacement worker starts only after deleted dependency output is rebuilt')
 run(tmux+['capture-pane','-p','-t','driver:fm-live-scout','-S','-100'])
 # Actual failing command: no worker command may run, metadata and queued backlog remain unchanged.
 brief('live-refusal',False)
 write(LAB/'data/backlog.md','# Backlog\n\n## Queued\n\n- [ ] live-refusal - bootstrap failure must remain queued\n')
 before=(LAB/'data/backlog.md').read_bytes()
 write(LAB/'config/project-bootstrap.json',json.dumps({'python':{'command':'echo INTENTIONAL_DEPENDENCY_FAILURE >&2; exit 42'}}))
 r=run([ROOT/'bin/fm-spawn.sh','live-refusal',project,'--mode','local-only','--yolo','off',worker,'--backend','tmux'],ok=False)
 check(r.returncode!=0 and 'dependency bootstrap refused spawn' in r.stdout and 'INTENTIONAL_DEPENDENCY_FAILURE' in r.stdout,'dependency failure refuses a real ship spawn and preserves diagnostics')
 check(not(LAB/'state/live-refusal.meta').exists() and not(LAB/'state/live-refusal.proof').exists() and (LAB/'data/backlog.md').read_bytes()==before,'failure publishes no task, executes no worker, and leaves queued backlog unchanged')
 # Nested guard on actual spawn path, not just helper.
 (LAB/'config/project-bootstrap.json').unlink();write(project/'frontend/package.json','{}');run(['git','add','.'],project);run(['git','commit','-m','nested layout'],project)
 # Origin must contain this commit for the fresh base refresh.
 run(['git','push','origin','main'],project)
 brief('live-nested-refusal')
 r=run([ROOT/'bin/fm-spawn.sh','live-nested-refusal',project,'--scout',worker,'--backend','tmux'],ok=False)
 check(r.returncode!=0 and 'nested dependency layout frontend/package.json' in r.stdout,'nested dependency layout fails real spawn before worker publication')
 check(not(LAB/'state/live-nested-refusal.meta').exists(),'nested refusal publishes no worker metadata')
 log.write('REAL SPAWN SCENARIOS COMPLETE\n')
finally:
 run(tmux+['kill-server'],ok=False)
 log.write('Private tmux server stopped. Disposable lab will be deleted by phase cleanup.\n')
