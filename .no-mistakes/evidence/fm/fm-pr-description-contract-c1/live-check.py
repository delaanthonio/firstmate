from pathlib import Path
import os, subprocess, shutil, shlex, json

root = Path.cwd()
scratch = root / '.test-pr-contract'
evidence = Path('/Users/dela/.no-mistakes/evidence/01M4H0T2CWNYMY4AGZ9RGK4SSZ')
(scratch / 'tmp').mkdir(parents=True, exist_ok=True)
home = scratch / 'home'
for part in ['data', 'state', 'config', 'projects']:
    (home / part).mkdir(parents=True, exist_ok=True)
env = os.environ.copy()
for key in ['TASKS_AXI_FILE', 'TASKS_AXI_BACKEND', 'FM_TASK_ID', 'TMUX', 'FM_ROOT_OVERRIDE']:
    env.pop(key, None)
env.update(FM_HOME=str(home), FM_STATE_OVERRIDE=str(home / 'state'), FM_DATA_OVERRIDE=str(home / 'data'), FM_CONFIG_OVERRIDE=str(home / 'config'), FM_PROJECTS_OVERRIDE=str(home / 'projects'), TMPDIR=str(scratch / 'tmp'), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', FM_GATE_REFUSE_BYPASS='1', FM_BACKEND='tmux')
transcript=[]
def run(args, *, check=True):
    proc = subprocess.run(args, cwd=root, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    transcript.append('$ ' + shlex.join([str(a) for a in args]) + '\n' + proc.stdout + f'[exit {proc.returncode}]\n')
    if check and proc.returncode:
        raise RuntimeError(transcript[-1])
    return proc.stdout

def contract(body):
    return body.split('# PR description contract\n', 1)[1].split('\n# UI screenshot contract', 1)[0]

def validate_pr(body):
    pr = contract(body)
    assert '"Summary", "What changed", "Screenshots" (for UI changes), "How to review", "Testing", "Risk", and "Follow-ups"' in pr
    assert 'including when following a repository template' in pr
    for expected in ['fewer than about 120 lines', 'no first-person narration and no direct address', 'single collapsed `<details>` block', 'Omit the block when there is no supplemental evidence.', 'including after an image line', 'plain characters rather than HTML entities', '`gh api markdown -F text=@body.md -f mode=gfm`']:
        assert expected in pr, expected
    assert '"Testing" section (or the repository template\'s equivalent testing section)' in body
    return pr

# A real, separate tmux server; the wrapper only chooses its private socket.
# No operator sessions, user tmux configuration, or model account are used.
tmux = shutil.which('tmux')
assert tmux
socket = root / '.prsock'
wrapper_dir = scratch / 'bin'
wrapper_dir.mkdir(exist_ok=True)
wrapper = wrapper_dir / 'tmux'
wrapper.write_text('#!/bin/sh\nexec ' + shlex.quote(tmux) + ' -S ' + shlex.quote(str(socket)) + ' -f /dev/null "$@"\n')
wrapper.chmod(0o755)
env['PATH'] = str(wrapper_dir) + os.pathsep + env['PATH']
results=[]
try:
    run(['tmux', 'new-session', '-d', '-s', 'contract-test', '-x', '120', '-y', '40', '-n', 'idle', 'exec /bin/cat'])
    for mode in ['no-mistakes', 'direct-PR', 'local-only']:
        suffix=mode.lower()
        ship_id = 'live-ship-' + suffix
        run([str(root / 'bin/fm-brief.sh'), ship_id, 'fixture', '--mode', mode])
        brief = (home / 'data' / ship_id / 'brief.md').read_text()
        if mode != 'local-only':
            validate_pr(brief)
        else:
            assert '# PR description contract' not in brief
            assert 'Do NOT push, do NOT open a PR, do NOT merge' in brief
        (evidence / f'ship-{suffix}-brief.md').write_text(brief)
        results.append({'path':'ordinary brief', 'mode':mode, 'result':'pass'})

        scout_id = 'live-promote-' + suffix
        run([str(root / 'bin/fm-brief.sh'), scout_id, 'fixture', '--scout'])
        scout_path = home / 'data' / scout_id / 'brief.md'
        scout = scout_path.read_text()
        assert '# PR description contract' not in scout
        scout = scout.replace('{TASK}', 'Make PR instructions concise and readable.').replace('{FIRSTMATE_SPEC}', 'Preserve the chosen delivery mode.')
        scout_path.write_text(scout)
        window = 'fm-' + scout_id
        target = run(['tmux', 'new-window', '-dP', '-F', '#{window_id}', '-t', 'contract-test:', '-n', window, 'exec /bin/cat']).strip()
        run(['tmux', 'set-window-option', '-t', target, 'automatic-rename', 'off'])
        grid=run(['tmux', 'display-message', '-p', '-t', target, '#{pane_width}x#{pane_height}']).strip()
        width,height=map(int,grid.split('x'))
        assert width > 0 and height > 0
        (home / 'state' / f'{scout_id}.meta').write_text(f'window={target}\nbackend=tmux\nkind=scout\nharness=claude\nworktree={root}\n')
        promotion = run([str(root / 'bin/fm-promote.sh'), scout_id, '--mode', mode, '--yolo', 'off'])
        instructions = (home / 'data' / scout_id / 'ship-instructions.md').read_text()
        if mode != 'local-only':
            assert validate_pr(instructions) == contract(brief)
        else:
            assert '# PR description contract' not in instructions
        # Execute the real delivery command printed by promotion.
        next_command = next(line[6:] for line in promotion.splitlines() if line.startswith('next: ') and 'fm-send.sh' in line)
        run(['bash', '-c', next_command])
        records = list((home / 'state' / f'{scout_id}.inbox').glob('*.msg'))
        assert len(records) == 1
        record = records[0].read_text()
        received = record.split('\n--\n', 1)[1]
        assert received.rstrip('\n') == instructions.rstrip('\n')
        assert instructions.split('# Current delivery mode contract\n', 1)[1].rstrip('\n') in scout_path.read_text()
        meta = (home / 'state' / f'{scout_id}.meta').read_text()
        assert 'kind=ship\n' in meta and f'mode={mode}\n' in meta
        (evidence / f'promoted-{suffix}-inbox.msg').write_text(record)
        (evidence / f'promoted-{suffix}-relaunch-brief.md').write_text(scout_path.read_text())
        results.append({'path':'real promotion and fm-send durable inbox', 'mode':mode, 'result':'pass', 'terminal_grid':grid, 'message_matches_instructions':True, 'persisted_for_relaunch':True})
    # Non-delivery roles must not acquire PR-writing requirements.
    run([str(root / 'bin/fm-brief.sh'), 'live-secondmate', '--secondmate', '--no-projects'])
    secondmate = (home / 'data/live-secondmate/brief.md').read_text()
    assert '# PR description contract' not in secondmate
    (evidence / 'secondmate-brief.md').write_text(secondmate)
    results.append({'path':'secondmate charter boundary', 'result':'pass'})
finally:
    run(['tmux', 'kill-server'], check=False)
    (evidence / 'live-product-transcript.log').write_text('\n'.join(transcript))
    (evidence / 'live-product-results.json').write_text(json.dumps(results, indent=2)+'\n')
print(json.dumps(results, indent=2))
