import pathlib
s=pathlib.Path('.live-bootstrap.py').read_text().split("run([ROOT/'bin/fm-lab-home.sh','create',LAB])")[0].replace("E/'live-bootstrap.log'","E/'live-mise.log'")
exec(compile(s,'.live-bootstrap.py','exec'))
cargobin=LAB/'tools/cargo-1.85.1-aarch64-apple-darwin/cargo/bin';rustbin=LAB/'tools/rustc-1.85.1-aarch64-apple-darwin/rustc/bin'
# Deliberately leave Cargo and rustc off the spawning process PATH: mise must activate them.
for config in ('mise.toml','.mise.toml'):
 p,w=repo('combined-'+config.replace('.','_'),{'pyproject.toml':'[project]\nname="combined-proof"\nversion="0.1.0"\nrequires-python=">=3.10"\ndependencies=[]\n', 'Cargo.toml':'[package]\nname="combined-proof"\nversion="0.1.0"\nedition="2021"\n','src/lib.rs':'pub fn proof() {}\n','Gemfile':'# no remote dependencies\n','package.json':json.dumps({'name':'combined-proof','version':'1.0.0','scripts':{'postinstall':"node -e \"if(process.version!=='v22.16.0'||process.env.BOOTSTRAP_PROBE!=='active')process.exit(32); console.log('PINNED_TOOLCHAIN '+process.version)\""}})})
 run(['uv','lock'],p);run([cargobin/'cargo','generate-lockfile'],p,extra={'PATH':str(rustbin)+':'+env['PATH']});run(['bundle','lock'],p);run(['npm','install','--package-lock-only','--ignore-scripts','--no-audit','--no-fund'],p)
 write(p/config,'[tools]\nnode="22.16.0"\n[env]\nBOOTSTRAP_PROBE="active"\n_.path=['+json.dumps(str(cargobin))+','+json.dumps(str(rustbin))+']\n')
 run(['git','add','.'],p);run(['git','commit','-m','lock combined dependencies and pin Node'],p);run(['git','reset','--hard','main'],w)
 r=boot(p,w);check('PINNED_TOOLCHAIN v22.16.0' in r.stdout and 'Bundle complete!' in r.stdout and r.returncode==0,'all four real dependency managers succeeded after mise installation and activation using '+config)
log.write('PINNED TOOLCHAIN SCENARIOS COMPLETE\n')
