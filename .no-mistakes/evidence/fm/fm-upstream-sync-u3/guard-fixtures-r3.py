import os,subprocess,tempfile,json,shutil
from pathlib import Path
root=Path.cwd(); lab=Path(tempfile.mkdtemp(prefix='guards-',dir=root/'.test-phase-tmp'))
log=[]
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','REX_','HERDR_','GIT_CONFIG')) and k not in ['TMUX','GIT_DIR','GIT_WORK_TREE']}
env.update(HOME=str(lab/'user'),TMPDIR=str(root/'.test-phase-tmp'),FM_TEST_SKIP_ORPHAN_REAP='1',FM_BACKEND_REX_BUNDLE_BIN=str(lab/'missing-bundle'))
(lab/'user').mkdir(); bin=lab/'bin'; bin.mkdir()
(bin/'jq').symlink_to(subprocess.check_output(['which','jq'],text=True).strip())
env['PATH']=str(bin)+':/usr/bin:/bin'
def call(name,args,wanted,extra={}):
 r=subprocess.run([str(x) for x in args],env={**env,**extra},capture_output=True,text=True,timeout=20)
 log.append({'scenario':name,'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr})
 assert r.returncode==wanted,(name,r.returncode,r.stdout,r.stderr)
 return r
try:
 guard=root/'tests/fm-backend-rex-composer-live-e2e.test.sh'
 r=call('Unrequested run capability-skips missing Rex',['/bin/bash',guard],0)
 assert 'rex absent' in r.stdout
 for v in ['FM_REX_COMPOSER_LIVE','FM_LIVE']:
  r=call('Explicit '+v+' refuses missing Rex',['/bin/bash',guard],1,{v:'1'})
  assert 'rex is not installed' in r.stderr
 stub=bin/'rex'; calls=lab/'rex-calls'
 stub.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "'+str(calls)+'"\nexit 86\n'); stub.chmod(0o755)
 r=call('Default-on reaches the disposable Rex executable',['/bin/bash',guard],2)
 assert calls.exists() and 'server run' in calls.read_text()
 log.append({'stub_calls':calls.read_text(),'note':'Local executable stub only; no real Rex lifecycle.'})
 calls.unlink()
 call('Per-guard off overrides global on',['/bin/bash',guard],0,{'FM_REX_COMPOSER_LIVE':'0','FM_LIVE':'1'})
 assert not calls.exists()
 call('Per-guard on overrides global off',['/bin/bash',guard],2,{'FM_REX_COMPOSER_LIVE':'1','FM_LIVE':'0'})
 assert calls.exists()
 env['PATH']=str(bin)+':'+os.environ['PATH']
 # T3 cleanup ownership: no server, credential, or harness is involved.
 home=lab/'owned-home'; home.mkdir()
 outside=lab/'outside-fixture'; outside.mkdir()
 settings=outside/'settings.local.json'
 data={'env':{'OUTSIDE':'keep','FM_T3CODE_ENV_KEYS':'OUTSIDE'}}
 settings.write_text(json.dumps(data)+'\n'); before=settings.read_bytes()
 (home/'.claude').symlink_to(outside)
 cleanup=['/bin/bash','-c','. "$1/bin/fm-backend.sh"; fm_backend_source t3code; fm_backend_t3code_home_env_cleanup "$2"','_',root,home]
 call('T3 cleanup refuses linked parent before touching external settings',cleanup,1)
 assert settings.read_bytes()==before
 log.append({'external_settings_after_refusal':json.loads(settings.read_text())})
 (home/'.claude').unlink(); (home/'.claude').mkdir()
 owned=home/'.claude/settings.local.json'
 owned.write_text(json.dumps({'env':{'CAPTAIN_VAR':'keep','FM_HOME':'temporary','FM_T3CODE_ENV_KEYS':'FM_HOME'},'permissions':{'allow':['Bash(ls:*)']}}))
 call('T3 cleanup removes only its own environment keys',cleanup,0)
 assert json.loads(owned.read_text())=={'env':{'CAPTAIN_VAR':'keep'},'permissions':{'allow':['Bash(ls:*)']}}
 log.append({'owned_settings_after_cleanup':json.loads(owned.read_text())})
finally:
 Path('/Users/dela/.no-mistakes/evidence/01M6C0X5BHNQ0K1NAZ55FZ12GF/guard-fixtures-r3.json').write_text(json.dumps(log,indent=2)+'\n')
 shutil.rmtree(lab)
