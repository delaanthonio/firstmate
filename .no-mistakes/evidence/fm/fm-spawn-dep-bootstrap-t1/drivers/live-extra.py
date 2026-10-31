import pathlib
s=pathlib.Path('.live-bootstrap.py').read_text().split("run([ROOT/'bin/fm-lab-home.sh','create',LAB])")[0]
s=s.replace("E/'live-bootstrap.log'","E/'live-extra.log'")
exec(compile(s,'.live-bootstrap.py','exec'))
env['PATH']=str(LAB/'tools/cargo-1.85.1-aarch64-apple-darwin/cargo/bin')+':'+str(LAB/'tools/rustc-1.85.1-aarch64-apple-darwin/rustc/bin')+':'+env['PATH']
p,w=repo('rust',{'Cargo.toml':'[package]\nname="bootstrap-proof"\nversion="0.1.0"\nedition="2021"\n','src/lib.rs':'pub fn proof() {}\n'})
run(['cargo','generate-lockfile'],p);run(['git','add','Cargo.lock'],p);run(['git','commit','-m','lock cargo'],p);run(['git','reset','--hard','main'],w)
boot(p,w);r=boot(p,w);check('dependencies unchanged' not in r.stdout,'real cargo fetch repeats for globally cached dependencies')
p=LAB/'cases/python/project';w=LAB/'cases/python/worker'
write(w/'frontend/package.json','{}');r=boot(p,w,False);check(r.returncode!=0 and 'frontend/package.json' in r.stdout,'existing root receipt cannot hide a new nested dependency layout');(w/'frontend/package.json').unlink();(w/'frontend').rmdir()
wnew=LAB/'concurrent';run(['git','worktree','add','-b','concurrent',wnew],p)
a=subprocess.Popen([str(ROOT/'bin/fm-project-bootstrap.sh'),str(p),str(wnew)],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
b=subprocess.Popen([str(ROOT/'bin/fm-project-bootstrap.sh'),str(p),str(wnew)],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
aout=a.communicate(timeout=90)[0];bout=b.communicate(timeout=90)[0];log.write('CONCURRENT A:\n'+aout+'CONCURRENT B:\n'+bout)
check(a.returncode==0 and b.returncode==0 and (aout+bout).count('dependencies unchanged')==1,'concurrent real bootstrap invocations serialize and reuse one successful sync');run([wnew/'.venv/bin/basedpyright','--version'])
src=LAB/'inherit-primary';dst=LAB/'inherit-mate';(src/'config').mkdir(parents=True);(dst/'config').mkdir(parents=True)
write(src/'config/project-bootstrap.json',json.dumps({'project':{'command':'uv sync --all-groups'}}))
run(['bash','-c','. "$1"; propagate_inheritable_config "$2" "$3"','_',ROOT/'bin/fm-config-inherit-lib.sh',src/'config',dst/'config'])
check((dst/'config/project-bootstrap.json').read_bytes()==(src/'config/project-bootstrap.json').read_bytes(),'project override propagates through real inheritance implementation')
r=run([ROOT/'bin/fm-project-bootstrap.sh',p,w],extra={'FM_HOME':str(dst)});check('uv sync --all-groups' in r.stdout,'inherited override executes in the secondmate worker copy');run([w/'.venv/bin/basedpyright','--version'])
log.write('ADDITIONAL LIVE SCENARIOS COMPLETE\n')
