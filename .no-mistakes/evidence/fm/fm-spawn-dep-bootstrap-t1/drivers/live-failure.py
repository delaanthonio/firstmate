import pathlib
s=pathlib.Path('.live-bootstrap.py').read_text().split("run([ROOT/'bin/fm-lab-home.sh','create',LAB])")[0].replace("E/'live-bootstrap.log'","E/'live-failure.log'")
exec(compile(s,'.live-bootstrap.py','exec'))
p=LAB/'cases/npm-mise_toml/project';w=LAB/'cases/npm-mise_toml/worker'
d=json.loads((w/'package.json').read_text());d['scripts']['postinstall']='if test -f .fail-bootstrap; then echo REAL_NPM_LIFECYCLE_FAILURE >&2; exit 42; fi; echo REAL_NPM_LIFECYCLE_SUCCESS'
write(w/'package.json',json.dumps(d));boot(p,w)
shutil.rmtree(w/'node_modules');write(w/'.fail-bootstrap','')
r=boot(p,w,False);check(r.returncode!=0 and 'REAL_NPM_LIFECYCLE_FAILURE' in r.stdout,'real package-manager lifecycle failure refuses bootstrap')
check((w/'node_modules').is_dir(),'failed npm lifecycle leaves dependency directory present, challenging stale receipt reuse')
(w/'.fail-bootstrap').unlink();r=boot(p,w);check('dependencies unchanged' not in r.stdout and 'REAL_NPM_LIFECYCLE_SUCCESS' in r.stdout,'failed sync invalidates older success even when dependency output exists on retry')
write(w/'.npmrc','audit=false\n');r=boot(p,w);check('dependencies unchanged' not in r.stdout,'adding manager configuration invalidates receipt')
(w/'.npmrc').unlink();r=boot(p,w);check('dependencies unchanged' not in r.stdout,'removing manager configuration invalidates receipt')
log.write('FAILURE RECOVERY LIVE SCENARIOS COMPLETE\n')
