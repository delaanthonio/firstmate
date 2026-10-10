import html, os, pathlib, re, signal, subprocess, sys, time
root = pathlib.Path.cwd()
evidence = pathlib.Path('/Users/dela/.no-mistakes/evidence/01M4KH5FZRRFSMMY78W2PE62ZX')
chrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
palette = ['#111111','#cc5555','#55cc55','#cccc55','#5555cc','#cc55cc','#55cccc','#cccccc']
def terminal_html(source):
    fg, bg, bold = '#d4d4d4', '#171717', False
    pieces = re.split(r'(\x1b\[[0-9;]*m)', source)
    out = []
    for piece in pieces:
        if piece.startswith('\x1b['):
            codes = [int(n or '0') for n in piece[2:-1].split(';')]
            i=0
            while i<len(codes):
                n=codes[i]
                if n==0: fg,bg,bold='#d4d4d4','#171717',False
                elif n==1: bold=True
                elif n==22: bold=False
                elif n==39: fg='#d4d4d4'
                elif n==49: bg='#171717'
                elif 30<=n<=37: fg=palette[n-30]
                elif 40<=n<=47: bg=palette[n-40]
                elif n in (38,48) and i+4<len(codes) and codes[i+1]==2:
                    color='#%02x%02x%02x'%tuple(codes[i+2:i+5])
                    if n==38: fg=color
                    else: bg=color
                    i+=4
                i+=1
        else:
            out.append(f'<span style="color:{fg};background:{bg};font-weight:{700 if bold else 400}">{html.escape(piece)}</span>')
    return ''.join(out)
for label in sys.argv[1:]:
    source = evidence/(label+'.ansi')
    if source.exists() and not label.endswith('-export'):
        page=evidence/(label+'.html')
        page.write_text('<!doctype html><meta charset="utf-8"><title>Live Pi terminal capture</title><style>body{margin:0;background:#171717;color:#ccc;padding:22px}p{font:14px system-ui;color:#999;margin:0 0 18px}pre{font:12px/17px Menlo,monospace;margin:0;white-space:pre}</style><p>'+html.escape(label)+' · real Pi tmux viewport, rendered from captured terminal colors</p><pre>'+terminal_html(source.read_text())+'</pre>')
    else:
        page=evidence/(label+'.html')
    profile=root/'.no-mistakes/chrome-visual'/label
    profile.mkdir(parents=True,exist_ok=True)
    (evidence/(label+'.png')).unlink(missing_ok=True)
    size='1360,1800' if label.endswith('-export') else '1360,930'
    command=[chrome,'--headless=new','--disable-gpu','--no-sandbox','--disable-dev-shm-usage','--disable-background-networking','--user-data-dir='+str(profile),'--virtual-time-budget=2000','--window-size='+size,'--screenshot='+str(evidence/(label+'.png')),'file://'+str(page)]
    def drive(args, output, ready):
        with output.open('wb') as stdout, (evidence/(label+'-chrome.log')).open('ab') as stderr:
            process=subprocess.Popen(args,stdout=stdout,stderr=stderr,start_new_session=True)
            try:
                for _ in range(200):
                    if ready(): return
                    if process.poll() is not None: break
                    time.sleep(.1)
                raise RuntimeError('Chrome did not produce '+str(output))
            finally:
                if process.poll() is None:
                    os.killpg(process.pid,signal.SIGTERM)
                    try: process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid,signal.SIGKILL)
                        process.wait()
    drive(command,evidence/(label+'-screenshot.log'),lambda:(evidence/(label+'.png')).exists())
    rendered=evidence/(label+'-rendered.html')
    drive(command[:-2]+['--dump-dom','file://'+str(page)],rendered,lambda:rendered.exists() and b'</html>' in rendered.read_bytes())
    print(label+' screenshot and rendered DOM captured')
