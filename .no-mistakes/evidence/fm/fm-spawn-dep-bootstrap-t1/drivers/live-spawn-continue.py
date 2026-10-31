import pathlib
s=pathlib.Path('.live-spawn.py').read_text().split("(LAB/'tmux').mkdir(exist_ok=True)")[0].replace("open(E/'live-spawn.log','w'","open(E/'live-spawn.log','a'")
exec(compile(s,'.live-spawn.py','exec'))
env['PATH']='/Users/dela/.local/share/mise/installs/node/24.20.0/bin:'+env['PATH']
tmux=['tmux','-L','fm-lab']
project=LAB/'projects/python'
try:
 run(tmux+['-f','/dev/null','new-session','-d','-s','driver','-x','120','-y','40','-c',str(ROOT),'/bin/bash --noprofile --norc'])
 run(tmux+['set-option','-g','default-shell','/bin/bash']);run(tmux+['set-option','-g','default-command','/bin/bash --noprofile --norc'])
 env['TMUX']=run(tmux+['display-message','-p','-t','driver','#{socket_path},#{pid},0']).stdout.splitlines()[0]
 run(['git','clone','--bare',project,LAB/'origin.git']);run(['git','remote','set-url','origin',str(LAB/'origin.git')],project)
 def brief(id,scout=True):
  run([ROOT/'bin/fm-brief.sh',id,'python']+(['--scout'] if scout else ['--mode','local-only']))
  b=LAB/'data'/id/'brief.md';b.write_text(b.read_text().replace('{TASK}','Verify refused bootstrap does not launch the worker.').replace('{FIRSTMATE_SPEC}','Supervised disposable validation only.'))
 worker="bash -c 'echo UNEXPECTED_WORKER > \"$FM_HOME/state/$FM_TASK_ID.proof\"'"
 brief('live-nested-refusal')
 r=run([ROOT/'bin/fm-spawn.sh','live-nested-refusal',project,'--scout',worker,'--backend','tmux'],ok=False)
 check(r.returncode!=0 and 'nested dependency layout frontend/package.json' in r.stdout,'nested dependency layout fails real spawn before worker publication')
 check(not(LAB/'state/live-nested-refusal.meta').exists(),'nested refusal publishes no worker metadata')
 brief('live-auto-refusal',False)
 write(LAB/'.tasks.toml','backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n')
 write(LAB/'data/backlog.md','# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
 run(['tasks-axi','add','live-auto-refusal','bootstrap refusal','--kind','ship','--file',LAB/'data/backlog.md'])
 (LAB/'config/backlog-backend').unlink()
 write(LAB/'config/project-bootstrap.json',json.dumps({'python':{'command':'echo INTENTIONAL_DEPENDENCY_FAILURE >&2; exit 42'}}))
 before=(LAB/'data/backlog.md').read_bytes()
 r=run([ROOT/'bin/fm-spawn.sh','live-auto-refusal',project,'--mode','local-only','--yolo','off',worker,'--backend','tmux'],ok=False)
 check(r.returncode!=0 and 'dependency bootstrap refused spawn' in r.stdout,'dependency failure refuses real ship with automatic backlog backend')
 check(not(LAB/'state/live-auto-refusal.meta').exists() and not(LAB/'state/live-auto-refusal.proof').exists() and (LAB/'data/backlog.md').read_bytes()==before,'automatic backlog and metadata remain unchanged before failed worker delivery')
 r=run(['tasks-axi','show','live-auto-refusal','--file',LAB/'data/backlog.md']);check('state: queued' in r.stdout,'real tasks-axi still reports queued after bootstrap refusal')
 (LAB/'config/project-bootstrap.json').unlink()
 log.write('REAL SPAWN SCENARIOS COMPLETE\n')
finally:run(tmux+['kill-server'],ok=False)
