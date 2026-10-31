import os, pathlib, subprocess, sys, json, shutil, time
ROOT=pathlib.Path.cwd(); LAB=ROOT/'.l'; E=pathlib.Path('/Users/dela/.no-mistakes/evidence/01M69Q3VH6Y1QYYGN31B26JEJ7')
log=open(E/'live-bootstrap.log','w',buffering=1)
env=os.environ.copy()
for key in list(env):
 if key.startswith('FM_') or key in ('GIT_DIR','GIT_COMMON_DIR','GIT_WORK_TREE','GIT_INDEX_FILE'): env.pop(key,None)
env.update(FM_HOME=str(LAB),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Lab',GIT_AUTHOR_EMAIL='lab@example.invalid',GIT_COMMITTER_NAME='Lab',GIT_COMMITTER_EMAIL='lab@example.invalid',UV_CACHE_DIR=str(LAB/'cache/uv'),UV_PYTHON_DOWNLOADS='never',UV_NO_MANAGED_PYTHON='1',npm_config_cache=str(LAB/'cache/npm'),MISE_DATA_DIR=str(LAB/'mise/data'),MISE_STATE_DIR=str(LAB/'mise/state'),MISE_CACHE_DIR=str(LAB/'mise/cache'),MISE_CONFIG_DIR=str(LAB/'mise/config'),MISE_TRUSTED_CONFIG_PATHS=str(LAB),BUNDLE_USER_HOME=str(LAB/'bundle'),TREEHOUSE_ROOT=str(LAB/'pool'))
def run(args,cwd=ROOT,ok=True,extra=None):
 log.write('$ '+ ' '.join(map(str,args))+'\n')
 p=subprocess.run(list(map(str,args)),cwd=cwd,env=env| (extra or {}),stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
 log.write(p.stdout+f'[exit {p.returncode}]\n')
 if ok and p.returncode: raise RuntimeError(p.stdout)
 return p

def write(p,s): p.parent.mkdir(parents=True,exist_ok=True);p.write_text(s)
def repo(name,files):
 p=LAB/'cases'/name/'project'; w=p.parent/'worker';p.mkdir(parents=True)
 run(['git','init','-b','main',p])
 for f,s in files.items():write(p/f,s)
 write(p/'.gitignore','.venv/\nnode_modules/\n.bundle/\nvendor/\n')
 run(['git','add','.'],p);run(['git','commit','-m','fixture'],p)
 run(['git','worktree','add','-b','worker',w],p)
 return p,w

def boot(p,w,ok=True):return run([ROOT/'bin/fm-project-bootstrap.sh',p,w],ok=ok)
def check(v,label):
 log.write(('PROVEN: ' if v else 'FAIL: ')+label+'\n')
 if not v:raise AssertionError(label)
run([ROOT/'bin/fm-lab-home.sh','create',LAB])
write(LAB/'config/backlog-backend','manual\n');write(LAB/'config/crew-harness','codex\n');write(LAB/'config/supervision-host-off','')
# Real uv dev-group sync, receipt reuse, deletion and manifest invalidation.
p,w=repo('python',{'pyproject.toml':'[project]\nname="bootstrap-proof"\nversion="0.0.0"\nrequires-python=">=3.10"\ndependencies=[]\n[dependency-groups]\ndev=["basedpyright"]\n','setup.py':'# compatibility companion\n','setup.cfg':'# compatibility companion\n'})
run(['uv','lock'],p);run(['git','add','uv.lock'],p);run(['git','commit','-m','lock dev dependencies'],p);run(['git','reset','--hard','main'],w)
boot(p,w);run([w/'.venv/bin/basedpyright','--version']);check(not (p/'.venv').exists(),'dev tools installed only in worker, with setuptools companions accepted')
r=boot(p,w);check('dependencies unchanged' in r.stdout,'unchanged receipt reused')
shutil.rmtree(w/'.venv');boot(p,w);run([w/'.venv/bin/basedpyright','--version']);check((w/'.venv/bin/basedpyright').exists(),'deleted virtualenv recreated on retry')
with (w/'pyproject.toml').open('a') as f:f.write('\n# dependency input changed\n')
r=boot(p,w);check('dependencies unchanged' not in r.stdout,'changed manifest forced real sync')
# Npm real install lifecycle must see mise environment for both filenames.
for config in ('mise.toml','.mise.toml'):
 name='npm-'+config.replace('.','_')
 p2,w2=repo(name,{'package.json':json.dumps({'name':'bootstrap-proof','version':'1.0.0','scripts':{'postinstall':"node -e \"if(process.env.BOOTSTRAP_PROBE!=='active')process.exit(31); console.log('ACTIVE_MISE '+process.version);\""}}),config:'[env]\nBOOTSTRAP_PROBE="active"\n'})
 run(['npm','install','--package-lock-only','--ignore-scripts','--no-audit','--no-fund'],p2);run(['git','add','package-lock.json'],p2);run(['git','commit','-m','lock npm'],p2);run(['git','reset','--hard','main'],w2)
 # npm creates no node_modules for a project without deps; add local dependency.
 dep=LAB/'local-package';write(dep/'package.json','{"name":"lab-local-dependency","version":"1.0.0"}')
 d=json.loads((p2/'package.json').read_text());d['dependencies']={'lab-local-dependency':'file:'+str(dep)};write(p2/'package.json',json.dumps(d))
 run(['npm','install','--package-lock-only','--ignore-scripts','--no-audit','--no-fund'],p2);run(['git','add','.'],p2);run(['git','commit','-m','local dep'],p2);run(['git','reset','--hard','main'],w2)
 r=boot(p2,w2);check('ACTIVE_MISE' in r.stdout,'npm lifecycle used real mise exec for '+config)
 r=boot(p2,w2);check('dependencies unchanged' in r.stdout,'npm outputs permit receipt reuse')
 shutil.rmtree(w2/'node_modules');r=boot(p2,w2);check('ACTIVE_MISE' in r.stdout,'deleted node_modules forces reinstall')
# Root and nested unresolved dependency layouts are refused; override repairs it.
p3,w3=repo('nested',{'frontend/package.json':'{"name":"nested-proof","version":"1.0.0"}','frontend/package-lock.json':'{"name":"nested-proof","version":"1.0.0","lockfileVersion":3,"packages":{"":{"name":"nested-proof","version":"1.0.0"}}}'})
r=boot(p3,w3,False);check(r.returncode!=0 and 'frontend/package-lock.json' in r.stdout and 'project-bootstrap.json' in r.stdout,'nested dependencies refuse with an actionable configuration remedy')
write(LAB/'config/project-bootstrap.json',json.dumps({'project':{'command':'cd frontend; npm ci --no-audit --no-fund'}}));boot(p3,w3);r=boot(p3,w3);check('dependencies unchanged' not in r.stdout,'custom nested command executes every time')
write(LAB/'config/project-bootstrap.json','{');r=boot(p3,w3,False);check(r.returncode!=0 and 'invalid dependency bootstrap configuration' in r.stdout,'invalid operator configuration refuses')
(LAB/'config/project-bootstrap.json').unlink()
p4,w4=repo('unresolved',{'package.json':'{}','pnpm-lock.yaml':'lockfileVersion: 9.0'})
r=boot(p4,w4,False);check(r.returncode!=0 and 'project-bootstrap.json' in r.stdout,'unsupported root dependency manager refuses')
p5,w5=repo('empty',{'README.md':'Dependency free\n','vendor/package.json':'{}','.hidden/package.json':'{}','deep/a/b/package.json':'{}'})
r=boot(p5,w5);check(r.stdout=='','dependency-free declared scan scope no-ops, excluding vendor, hidden, and third-level directories')
# Actual bundler, configured to put artifacts inside this disposable copy.
p6,w6=repo('ruby',{'Gemfile':'# no external gems needed\n'})
run(['bundle','lock'],p6);run(['git','add','Gemfile.lock'],p6);run(['git','commit','-m','lock bundle'],p6);run(['git','reset','--hard','main'],w6)
boot(p6,w6);r=boot(p6,w6);check('dependencies unchanged' not in r.stdout,'Bundler runs again rather than trusting unverifiable global output')
log.write('HELPER LIVE SCENARIOS COMPLETE\n')
