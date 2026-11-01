import os,subprocess,tempfile,json,hashlib,shutil,stat
from pathlib import Path
root=Path.cwd()
lab=Path(tempfile.mkdtemp(prefix='product-',dir=root/'.test-phase-tmp'))
log=[]
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','GIT_CONFIG','TASKS_AXI','HERDR_','REX_')) and k not in ['TMUX','TMUX_PANE','GIT_DIR','GIT_WORK_TREE']}
env.update(HOME=str(lab/'user'),TMPDIR=str(root/'.test-phase-tmp'),PYTHONDONTWRITEBYTECODE='1')
(lab/'user').mkdir()
home=lab/'home'
for name in ['config','state','data','projects']: (home/name).mkdir(parents=True)
env['FM_HOME']=str(home)
def run(label,args,expected=0,extra=None):
 r=subprocess.run([str(x) for x in args],env={**env,**(extra or {})},text=True,capture_output=True,timeout=35)
 log.append({'action':label,'command':[str(x).replace(str(lab),'$LAB') for x in args], 'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr})
 assert r.returncode==expected,(label,r.returncode,r.stdout,r.stderr)
 return r
try:
 exporter=root/'bin/fm-record-export.sh'
 run('Export disabled without local opt-in',[exporter,'sync'])
 assert not (lab/'export').exists()
 (home/'config/record-export-root').write_text(str(lab/'export')+'\n')
 (home/'data/projects.md').write_text('Synthetic project ledger\n')
 (home/'data/private.txt').write_text('Excluded fixture\n')
 (home/'state/task-a.meta').write_text('task=task-a\nspawn_gen=evidence-generation\nkind=ship\n')
 (home/'state/task-a.status').write_text('done: synthetic landed task\n')
 run('Publish an allowlisted live snapshot',[exporter,'sync'])
 assert (lab/'export/live/data/projects.md').read_text()=='Synthetic project ledger\n'
 assert not (lab/'export/live/data/private.txt').exists()
 log.append({'published_live_projects':(lab/'export/live/data/projects.md').read_text(),'excluded_private_file_present':False})
 (home/'data/projects.md').write_text('Updated synthetic ledger\n')
 run('Update the live snapshot',[exporter,'sync'])
 assert (lab/'export/live/data/projects.md').read_text()=='Updated synthetic ledger\n'
 external=lab/'external-sentinel'
 external.write_text('Untouched fixture sentinel\n')
 (home/'data/projects.md').unlink()
 (home/'data/projects.md').symlink_to(external)
 run('Refuse a linked source and preserve prior complete snapshot',[exporter,'sync'],1)
 assert external.read_text()=='Untouched fixture sentinel\n'
 assert (lab/'export/live/data/projects.md').read_text()=='Updated synthetic ledger\n'
 (home/'data/projects.md').unlink()
 (home/'data/projects.md').write_text('Updated synthetic ledger\n')
 run('Archive a task generation',[exporter,'archive-task','task-a'])
 archive=lab/'export/archive/task-a/evidence-generation'
 manifest=archive/'manifest.v1.json'
 initial=manifest.read_bytes()
 data=json.loads(initial)
 for row in data['files']:
  payload=(archive/row['archive']).read_bytes()
  assert hashlib.sha256(payload).hexdigest()==row['sha256']
 run('Retry a committed generation without rewriting it',[exporter,'archive-task','task-a'])
 assert manifest.read_bytes()==initial
 log.append({'committed_archive_manifest':data,'idempotent_retry_preserved_manifest_bytes':True})
 (archive/'status').write_text('tampered fixture\n')
 run('Refuse retry of a tampered committed archive',[exporter,'archive-task','task-a'],1)
 assert (home/'state/task-a.meta').exists()
 # Real capacity CLI; quota-axi is a disposable external-data fixture.
 fakebin=lab/'fakebin'; fakebin.mkdir()
 quota=fakebin/'quota-axi'
 quota.write_text('#!/bin/sh\ncat "'+str(lab/'quota.json')+'"\n'); quota.chmod(0o755)
 qenv={'PATH':str(fakebin)+':'+env['PATH'],'FM_LANE_CAPACITY_PUBLISH_INTERVAL':'0'}
 (home/'config/lane-capacity').write_text('3\nquota-provider claude\n')
 def row(key,status):
  return {'provider':'claude','accountKey':key,'quotaSemantics':{'status':'known','effectiveAvailability':[{'scope':'all_models','status':'known','effectivePercentRemaining':50,'runway':{'status':status}}]}}
 rows=[row('work','exhausted_now'),row('default','through_reset')]
 for name,records,expect in [('work-first',rows,'through_reset'),('default-first',list(reversed(rows)),'through_reset'),('unmatched',[rows[0]],'unknown')]:
  (lab/'quota.json').write_text(json.dumps({'schemaVersion':6,'providers':records}))
  r=run('Capacity JSON: '+name,[root/'bin/fm-capacity.sh','--json'],extra=qenv)
  assert json.loads(r.stdout)['quota']['runway']==expect
  run('Capacity publication: '+name,[root/'bin/fm-capacity.sh','--publish'],extra=qenv)
  doc=json.loads((home/'state/lane-capacity.json').read_text())
  assert doc['quota']['runway']==expect
  assert stat.S_IMODE((home/'state/lane-capacity.json').stat().st_mode)==0o600
  log.append({'quota_order':name,'published_quota':doc['quota'],'published_mode':'0600'})
 # Public busy-event CLI, using synthetic native events (no harness).
 busy=root/'bin/fm-busy-event.sh'; state=home/'state'
 old=run('Arm the initial worker generation',[busy,'arm',state,'worker','--source','pi-ext','--event','turn-start']).stdout.strip()
 run('Open stream request 1',[busy,'stream',state,'worker','open','--gen',old,'--request','1'])
 run('Observe stream progress',[busy,'stream',state,'worker','progress','--gen',old,'--request','1'])
 run('Settle the worker and clear stream observations',[busy,'apply',state,'worker','idle','--gen',old,'--source','pi-ext','--event','turn-end','--turn-ended'])
 assert not (state/'worker.model-stream').exists()
 new=run('Replace the worker incarnation',[busy,'arm',state,'worker','--source','pi-ext','--event','turn-start']).stdout.strip()
 assert old!=new
 marker_before=(state/'worker.turn-ended').stat().st_mtime_ns
 run('Refuse a stale hook event',[busy,'apply',state,'worker','idle','--gen',old,'--source','pi-ext','--event','turn-end','--turn-ended'],1)
 assert (state/'worker.turn-ended').stat().st_mtime_ns==marker_before
 log.append({'replacement_generation_record':(state/'worker.busy-state').read_text(),'stale_hook_did_not_signal_replacement':True})
 run('Retire the owned worker generation',[busy,'retire',state,'worker','--gen',new])
 assert not (state/'worker.busy-state').exists()
 log.append({'result':'All direct CLI assertions passed; disposable fixture removed in finally.'})
finally:
 Path('/Users/dela/.no-mistakes/evidence/01M6C0X5BHNQ0K1NAZ55FZ12GF/product-cli-r3.json').write_text(json.dumps(log,indent=2)+'\n')
 shutil.rmtree(lab)
