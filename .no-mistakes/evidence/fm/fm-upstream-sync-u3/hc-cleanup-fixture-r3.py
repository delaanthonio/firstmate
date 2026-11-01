import os,tempfile,subprocess,shutil,json
from pathlib import Path
root=Path.cwd(); lab=Path(tempfile.mkdtemp(prefix='hc-cleanup-',dir=root/'.test-phase-tmp')); log=[]
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','HC_','HERDR_'))}; env['TMPDIR']=str(root/'.test-phase-tmp')
fb=lab/'bin';fb.mkdir(); listing=lab/'processes';signals=lab/'signals';calls=lab/'calls';listing.write_text('')
(fb/'ps').write_text('#!/bin/sh\ncase "$*" in *ewwax*) cat "'+str(listing)+'";; *pgid*) echo 99990;; *) echo 1;; esac\n')
(fb/'sleep').write_text('#!/bin/sh\nexit 0\n')
(fb/'hc').write_text('#!/bin/sh\nprintf "%s %s %s\\n" "$HC_SOCKET" "$XDG_STATE_HOME" "$*" >> "'+str(calls)+'"\n')
for p in fb.iterdir():p.chmod(0o755)
shim=lab/'bash-env';shim.write_text('''kill() {
 printf '%s\\n' "$*" >> "$HC_FIXTURE_SIGNALS"
 pid=${*: -1}
 awk -v pid="$pid" '$1 != pid' "$HC_FIXTURE_PS" > "$HC_FIXTURE_PS.next"
 mv "$HC_FIXTURE_PS.next" "$HC_FIXTURE_PS"
}
''')
env.update(PATH=str(fb)+':'+env['PATH'],BASH_ENV=str(shim),FM_HC_BIN=str(fb/'hc'),HC_FIXTURE_SIGNALS=str(signals),HC_FIXTURE_PS=str(listing))
name='fm-hclab-same'; sessions=[]
def run(action,entry):
 e={**env,'FM_HC_LAB_DIR':str(entry[0]),'FM_HC_LAB_SOCK_DIR':str(entry[1])}
 r=subprocess.run(['/bin/bash',str(root/'bin/fm-hc-ci-cleanup.sh'),action,str(entry[2])],env=e,text=True,capture_output=True,timeout=15)
 log.append({'action':action,'root':entry[0].name,'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr})
 assert r.returncode==0
try:
 for side in ['a','b']:
  entry=(lab/('root-'+side),lab/('sockets-'+side),lab/('snapshot-'+side)); sessions.append(entry)
  run('snapshot',entry)
  (entry[0]/name/'env/xdg-state').mkdir(parents=True);entry[1].mkdir()
 for index,(base,socks,snap) in enumerate(sessions):
  with listing.open('a') as out:out.write(f'{900001+index} 1 {910001+index} fixture HC_SESSION={name} HC_SOCKET={socks}/{name}.sock XDG_STATE_HOME={base}/{name}/env/xdg-state\n')
 run('teardown',sessions[0]); first=signals.read_text(); assert first.strip()=='-TERM 900001'
 assert (sessions[1][0]/name).exists() and not (sessions[0][0]/name).exists()
 assert '900002' in listing.read_text()
 log.append({'first_root_signal_log':first,'other_root_directory_preserved':True,'other_root_synthetic_process_preserved':True})
 run('teardown',sessions[1]);assert signals.read_text().splitlines()==['-TERM 900001','-TERM 900002']
 assert not (sessions[1][0]/name).exists()
 log.append({'all_mock_signals':signals.read_text(),'stub_backend_calls':calls.read_text(),'real_signals_or_backend_calls':False})
finally:
 Path('/Users/dela/.no-mistakes/evidence/01M6C0X5BHNQ0K1NAZ55FZ12GF/hc-cleanup-fixture-r3.json').write_text(json.dumps(log,indent=2)+'\n');shutil.rmtree(lab)
