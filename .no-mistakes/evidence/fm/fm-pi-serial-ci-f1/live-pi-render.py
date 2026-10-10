import datetime, json, os, pathlib, shlex, shutil, subprocess, sys, time

root = pathlib.Path.cwd()
evidence = pathlib.Path('/Users/dela/.no-mistakes/evidence/01M4KH5FZRRFSMMY78W2PE62ZX')
version, stage = sys.argv[1:3]
label = f'pi-{version}-{stage}'
lab = root / '.no-mistakes' / label
project, home, config = lab/'project', lab/'home', lab/'config'
for directory in [project, home/'state', home/'config', config]: directory.mkdir(parents=True, exist_ok=True)
shutil.copytree(root/'.pi/extensions', project/'.pi/extensions', dirs_exist_ok=True)
if stage == 'before':
    (project/'.pi/extensions/fm-branch-supervision.ts').write_bytes(subprocess.check_output(['git','show','cbad273fc16f39ed37c2a6425746085e10853e68:.pi/extensions/fm-branch-supervision.ts']))
package = root/'.no-mistakes/test-runtime'/('pi-new-nested' if version=='1.1.0' else 'pi-old-nested')/'node_modules/@earendil-works/pi-coding-agent'
for name, target in [('pi-coding-agent', package), ('pi-tui',package/'node_modules/@earendil-works/pi-tui'), ('pi-ai',package/'node_modules/@earendil-works/pi-ai')]:
    link = project/'node_modules/@earendil-works'/name
    link.parent.mkdir(parents=True,exist_ok=True)
    if not link.exists(): link.symlink_to(target, target_is_directory=True)
if not (project/'node_modules/typebox').exists():
    (project/'node_modules/typebox').symlink_to(package/'node_modules/typebox', target_is_directory=True)
(config/'settings.json').write_text(json.dumps({'theme':'dark','hideThinkingBlock':True}))
session = lab/'session.jsonl'
stamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
rows=[{'type':'session','version':3,'id':'11111111-1111-4111-8111-111111111111','timestamp':stamp,'cwd':str(project)}]
usage={'input':1,'output':1,'cacheRead':0,'cacheWrite':0,'totalTokens':2,'cost':dict(input=0,output=0,cacheRead=0,cacheWrite=0,total=0)}
def add(message):
    n=len(rows)
    rows.append({'type':'message','id':f'a{n:07d}','parentId':None if n==1 else f'a{n-1:07d}','timestamp':stamp,'message':dict(message,timestamp=n)})
def assistant(content, stop='stop'):
    return dict(role='assistant',content=content,api='anthropic-messages',provider='anthropic',model='claude-sonnet-4-5',usage=usage,stopReason=stop)
add(dict(role='user',content=[dict(type='text',text='Read two supervision outcomes and acknowledge the first.')]))
add(assistant([dict(type='toolCall',id='outcomes-1',name='fm_branch_outcomes',arguments={'recent':2})],'toolUse'))
add(dict(role='toolResult',toolCallId='outcomes-1',toolName='fm_branch_outcomes',content=[dict(type='text',text='Outcome one: build completed.\nOutcome two: review ready.')],details={'ok':True},isError=False))
add(assistant([dict(type='toolCall',id='processed-1',name='fm_branch_processed',arguments={'through':1})],'toolUse'))
add(dict(role='toolResult',toolCallId='processed-1',toolName='fm_branch_processed',content=[dict(type='text',text='Acknowledged through 1.')],isError=False))
add(assistant([dict(type='text',text='The supervision rendering probe is complete.')]))
session.write_text(''.join(json.dumps(row)+'\n' for row in rows))
socket='fm-live-render-'+str(os.getpid())
def tmux(*args): return subprocess.check_output(['tmux','-L',socket,*args],text=True)
env=dict(os.environ,FM_HOME=str(home),FM_ROOT_OVERRIDE=str(root),PI_CODING_AGENT_DIR=str(config),PI_OFFLINE='1',TMPDIR=str(root/'.no-mistakes/tmp'),SHELL='/bin/bash')
cmd = ['env']+[f'{k}={v}' for k,v in env.items() if k in ['FM_HOME','FM_ROOT_OVERRIDE','PI_CODING_AGENT_DIR','PI_OFFLINE','TMPDIR']]+[str(package.parent.parent/'.bin/pi')]
if version=='1.1.0': cmd += ['--tui-mode','regular']
cmd += ['--approve','--no-context-files','--no-skills','--no-prompt-templates','--no-extensions','-e','./.pi/extensions/fm-calm.ts','-e','./.pi/extensions/fm-branch-supervision.ts','--session',str(session)]
shellcmd='cd '+shlex.quote(str(project))+' && '+shlex.join(cmd)
subprocess.run(['tmux','-L',socket,'-f','/dev/null','new-session','-d','-s','render','-x','150','-y','42',shellcmd],env=env,check=True)
report=[]
def capture(name, predicate):
    for _ in range(200):
        pane=tmux('capture-pane','-p','-t','render')
        if predicate(pane): break
        time.sleep(.05)
    else: raise AssertionError(f'{name} did not settle: {pane}')
    (evidence/f'{label}-{name}.txt').write_text(pane)
    (evidence/f'{label}-{name}.ansi').write_text(tmux('capture-pane','-e','-p','-t','render'))
    return pane
def command(text):
    tmux('send-keys','-t','render','-l',text)
    tmux('send-keys','-t','render','Enter')
def has_tools(pane): return 'fm_branch_outcomes' in pane and 'fm_branch_processed' in pane
try:
    pane=capture('collapsed',lambda p: has_tools(p) and 'probe is complete' in p)
    shows_args=version=='1.1.0' and stage!='before'
    assert ('recent=2' in pane)==shows_args, pane
    assert ('through=1' in pane)==shows_args, pane
    report.append(f'collapsed headers: recent=2 and through=1 {"shown" if shows_args else "absent"}')
    tmux('send-keys','-t','render','C-o')
    pane=capture('expanded',lambda p: ('recent: 2' in p and 'through: 1' in p) if shows_args else has_tools(p))
    assert ('recent: 2' in pane)==shows_args, pane
    assert ('through: 1' in pane)==shows_args, pane
    report.append(f'expanded headers: recent: 2 and through: 1 {"shown" if shows_args else "absent"}')
    command('/calm')
    pane=capture('calm-on',lambda p: not has_tools(p) and (home/'config/calm').exists() and (home/'config/calm').read_text().strip()=='on')
    assert 'fm_branch_outcomes' not in pane and 'fm_branch_processed' not in pane, pane
    assert 'probe is complete' in pane
    report.append('Calm on hides both tool rows and preserves the genuine reply')
    export = evidence/f'{label}-export.html'
    command('/export '+str(export))
    capture('export',lambda p: export.exists() and 'Session exported to:' in p)
    report.append('real /export created '+str(export))
    command('/calm')
    pane=capture('calm-off',has_tools)
    assert (home/'config/calm').read_text().strip()=='off'
    report.append('Calm off restores both tool rows')
    command('/quit')
    (evidence/f'{label}-result.json').write_text(json.dumps({'version':version,'stage':stage,'result':'pass','checks':report},indent=2))
    print('\n'.join(report))
finally:
    subprocess.run(['tmux','-L',socket,'kill-server'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
