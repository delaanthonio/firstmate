import os, pathlib, subprocess, time, json, shutil
root=pathlib.Path.cwd()
evidence=pathlib.Path('/Users/dela/.no-mistakes/evidence/01M69SW8ZHZ0QCHZPN4JJQZKKX')
lab=root/'.validation-tmp/round2-live-lab'
lab.parent.mkdir(exist_ok=True)
lab.mkdir()
def run(args, env=None, check=True, timeout=60):
    p=subprocess.run(args,cwd=root,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
    if check and p.returncode: raise RuntimeError(f'{args}: {p.stdout}')
    return p.stdout
run(['bin/fm-lab-home.sh','create',str(lab)])
socket_dir=run(['bin/fm-lab-home.sh','tmux-dir',str(lab)]).strip()
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'FACTORY_', 'DROID_')) and k not in ['TMUX','CLAUDE_CONFIG_DIR','ZDOTDIR']}
env.update(FACTORY_HOME_OVERRIDE=str(lab/'user-home/.factory'),FACTORY_DROID_AUTO_UPDATE_ENABLED='false',FM_HOME=str(lab),TMUX_TMPDIR=socket_dir,HOME=str(lab/'user-home'),XDG_CONFIG_HOME=str(lab/'user-home/.config'),XDG_CACHE_HOME=str(lab/'user-home/.cache'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_SYSTEM='/dev/null',GIT_CONFIG_NOSYSTEM='1')
(lab/'user-home').mkdir()
(lab/'tmp').mkdir()
env['TMPDIR']=str(lab/'tmp')
project=lab/'project'
project.mkdir()
run(['git','init','-q','-b','main',str(project)],env)
(project/'README.md').write_text('Disposable Droid validation project.\n')
run(['git','-C',str(project),'add','README.md'],env)
run(['git','-C',str(project),'-c','user.name=Test','-c','user.email=test@example.invalid','commit','-qm','Initial'],env)
wt=lab/'worktree'
run(['git','-C',str(project),'worktree','add','-q','-b','lab-work',str(wt)],env)
(lab/'data/live-droid').mkdir()
(lab/'data/live-droid/brief.md').write_text("# Task\n## Captain's intent\nReply with exactly DROID_LAB_READY and end your turn. Do not use tools or access any files outside this worktree.\n\n## Firstmate spec\nExercise isolated spawn.\n")
(lab/'config/crew-harness').write_text('droid\n')
(lab/'state/.last-watcher-beat').touch()
shim=lab/'shim'; shim.mkdir()
(shim/'treehouse').write_text('#!/bin/sh\ncase "$1" in get) printf "%s\\n" "'+str(wt)+'" ;; esac\n')
(shim/'treehouse').chmod(0o755)
env['PATH']=str(shim)+':'+env['PATH']
rc=lab/'bashrc'
rc.write_text('treehouse() { cd '+str(wt)+'; }\n')
def tmux(*args,check=True): return run(['tmux','-L','fm-lab',*args],env,check)
try:
    tmux('new-session','-d','-s','primary','-x','120','-y','40','-c',str(root),'--','/bin/bash','--noprofile','--norc')
    tmux('set-option','-g','default-shell','/bin/bash')
    tmux('set-option','-g','default-command','exec /bin/bash --noprofile --rcfile '+str(rc)+' -i')
    tmux('new-window','-d','-t','primary:','-n','control','-c',str(wt),'--','droid','--auto','high')
    capture=''
    for i in range(35):
        capture=tmux('capture-pane','-p','-t','primary:control','-S','-0')
        if any(s in capture for s in ['Trust this folder?','Sign in','Log in','Login','Welcome to Droid','Choose a theme']): break
        time.sleep(0.5)
    (evidence/'round2-isolated-droid-control-viewport.txt').write_text(capture)
    print('CONTROL VIEWPORT\n'+capture,flush=True)
    tmux('kill-window','-t','primary:control')
    env['TMUX']=tmux('display-message','-p','-t','primary:0','#{socket_path}').strip()+',1,0'
    env['FM_DROID_READY_POLLS']='30'; env['FM_DROID_POLL_INTERVAL']='0.5'; env['FM_SPAWN_NO_GUARD']='1'
    output=run(['bash','bin/fm-spawn.sh','live-droid',str(project),'--scout','--harness','droid','--backend','tmux'],env,False,timeout=85)
    (evidence/'round2-isolated-droid-live-spawn.txt').write_text(output)
    print('SPAWN OUTPUT\n'+output,flush=True)
    for line in tmux('list-windows','-t','primary','-F','#{window_index} #{window_name}').splitlines():
        index=line.split()[0]
        screen=tmux('capture-pane','-p','-t','primary:'+index,'-S','-0')
        (evidence/f'round2-isolated-droid-live-pane-{index}.txt').write_text(screen)
        print('PANE '+line+'\n'+screen,flush=True)
    meta=lab/'state/live-droid.meta'
    if meta.exists():
        lines=[l for l in meta.read_text().splitlines() if l.startswith(('harness=','model=','effective_model=','spawn_gen='))]
        (evidence/'round2-isolated-droid-live-model-record.txt').write_text('\n'.join(lines)+'\n')
        print('MODEL RECORD\n'+'\n'.join(lines),flush=True)
finally:
    tmux('kill-server',check=False)
    run(['bin/fm-lab-home.sh','teardown',str(lab)],check=False)
    
    for d,ds,fs in os.walk(lab): os.chmod(d,0o700)
    shutil.rmtree(lab)
    print('Private tmux server stopped; disposable lab removed.',flush=True)
