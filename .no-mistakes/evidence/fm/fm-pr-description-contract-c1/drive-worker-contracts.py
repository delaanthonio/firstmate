from pathlib import Path
import os, subprocess, shutil, json
root = Path.cwd()
setup = root / '.nm-test-pr-contract'
evidence = Path('/Users/dela/.no-mistakes/evidence/01M4FNKN7PFEGXMT8J21KMYYAQ')
transcript = []

def run(args, home):
    env = dict(os.environ, FM_HOME=str(home), FM_STATE_OVERRIDE=str(home/'state'), FM_DATA_OVERRIDE=str(home/'data'), FM_CONFIG_OVERRIDE=str(home/'config'), TMPDIR=str(setup/'tmp'))
    result = subprocess.run([str(root / args[0]), *args[1:]], cwd=root, env=env, text=True, capture_output=True)
    transcript.append('$ FM_HOME=<disposable-home> ' + ' '.join(args) + '\n' + result.stdout + result.stderr)
    if result.returncode: raise RuntimeError(result.stderr)
    return result.stdout

def contract(text):
    start = text.find('# PR description contract\n')
    if start < 0: return ''
    return text[start:text.index('# UI screenshot contract\n', start)]

contracts = []
for mode, short in [('no-mistakes','pipeline'), ('direct-PR','direct'), ('local-only','local')]:
    home = setup / ('home-' + short)
    for child in ['state','data','config']: (home/child).mkdir(parents=True, exist_ok=True)
    ordinary_id = 'verify-' + short
    run(['bin/fm-brief.sh',ordinary_id,'fixture-project','--mode',mode],home)
    ordinary = (home/'data'/ordinary_id/'brief.md').read_text()
    shutil.copyfile(home/'data'/ordinary_id/'brief.md', evidence/f'ordinary-{short}-brief.md')
    if mode != 'local-only':
        assert '-F text=@body.md' in contract(ordinary)
        assert '-f text=@body.md' not in contract(ordinary)
        contracts.append(contract(ordinary))
    else: assert not contract(ordinary)
    promoted_id = 'promote-' + short
    run(['bin/fm-brief.sh',promoted_id,'fixture-project','--scout'],home)
    scout_path = home/'data'/promoted_id/'brief.md'
    assert not contract(scout_path.read_text())
    scout_path.write_text(scout_path.read_text().replace('{TASK}', 'Improve the fixture project PR description.').replace('{FIRSTMATE_SPEC}', 'Investigate the fixture project description.'))
    (home/'state'/f'{promoted_id}.meta').write_text(f'window=fm-{promoted_id}\nkind=scout\nworktree={setup}/fixture-project\n')
    run(['bin/fm-promote.sh',promoted_id,'--mode',mode,'--yolo','off'],home)
    instructions = home/'data'/promoted_id/'ship-instructions.md'
    promoted_contract = contract(instructions.read_text())
    assert promoted_contract == contract(ordinary)
    assert contract(scout_path.read_text()) == contract(ordinary)
    assert 'kind=ship\n' in (home/'state'/f'{promoted_id}.meta').read_text()
    shutil.copyfile(instructions, evidence/f'promoted-{short}-instructions.md')
    shutil.copyfile(scout_path, evidence/f'promoted-{short}-persisted-brief.md')
    transcript.append(f'Observed {mode}: ordinary and promoted contracts agree; relaunch brief persists current contract; task kind is ship.\n')
assert contracts[0] == contracts[1]
(evidence/'worker-pr-contract.md').write_text(contracts[0])
(evidence/'live-cli-transcript.txt').write_text('\n'.join(transcript))
print('Generated ordinary briefs and promoted ship instructions for all three delivery modes; persisted contracts matched.')
