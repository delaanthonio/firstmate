import html, json, pathlib, re, subprocess
root=pathlib.Path.cwd()
evidence=pathlib.Path('/Users/dela/.no-mistakes/evidence/01M4KH5FZRRFSMMY78W2PE62ZX')
script='''<script>setTimeout(() => {
  const messages=document.querySelector('#messages');
  const tree=document.querySelector('#tree-container');
  const hidden=[...document.querySelectorAll('#messages .hook-message-hidden')].map(n=>({text:n.innerText,display:getComputedStyle(n).display}));
  const report=document.createElement('pre');report.id='live-visibility-report';report.hidden=true;
  report.textContent=JSON.stringify({messages:messages?.innerText,tree:tree?.innerText,hidden,showHidden:document.body.classList.contains('show-hidden-messages')});
  document.body.appendChild(report);
},500);</script>'''
for label in ['pi-1.1.0-after-export','pi-0.87.1-after-export','pi-new-calm-calm-export']:
    source=evidence/(label+'.html')
    probe=evidence/(label+'-probe.html')
    probe.write_text(source.read_text()+script)
    # Use the same isolated, bounded Chrome driver as the visual capture.
    target=label+'-probe-export'
    (evidence/(target+'.html')).write_text(probe.read_text())
    subprocess.run(['python3','-u',str(root/'.no-mistakes/capture-visual.py'),target],check=True)
    dom=(evidence/(target+'-rendered.html')).read_text()
    match=re.search(r'<pre id="live-visibility-report"[^>]*>(.*?)</pre>',dom,re.S)
    assert match, 'Chrome did not report actual visibility'
    report=json.loads(html.unescape(match.group(1)))
    assert report['showHidden'] is False
    visible=report['messages']
    if label.startswith('pi-new-calm'):
        assert 'Show a deterministic tool example.' in visible
        assert 'The deterministic tool example is complete.' in visible
        assert '/tmp/probe.status' not in visible
        assert '[firstmate-synthetic-input]' not in visible
        assert '/tmp/probe.status' in report['tree']
        assert 'firstmate-synthetic-input' in report['tree']
        for item in report['hidden']: assert item['display']=='none',item
        for name in ['CURRENT_WATCHER_E2E','CURRENT_TURN_END_E2E','CURRENT_AWAY_E2E','CURRENT_FROM_FIRSTMATE_E2E','CURRENT_LAUNCH_BRIEF_E2E']:
            assert name in visible, name
    else:
        for text in ['fm_branch_outcomes','fm_branch_processed','recent','through','Outcome one: build completed.','Acknowledged through 1.','The supervision rendering probe is complete.']:
            assert text in visible, text
    (evidence/(label+'-visibility.json')).write_text(json.dumps(report,indent=2))
    print(label+': actual computed visibility and exported content verified')
