from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
import threading, os, subprocess, json, re, ssl
root=Path.cwd()
setup=root/'.nm-test-pr-contract'
evidence=Path('/Users/dela/.no-mistakes/evidence/01M4FNKN7PFEGXMT8J21KMYYAQ')
received=[]
class Capture(BaseHTTPRequestHandler):
    def do_POST(self):
        received.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
        self.send_response(200); self.send_header('Content-Type','text/html'); self.end_headers(); self.wfile.write(b'<p>request captured; rendering not evaluated</p>')
    def log_message(self,*args): pass
server=HTTPServer(('127.0.0.1',0),Capture)
subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(setup/'capture.key'),'-out',str(setup/'capture.crt'),'-days','1','-subj','/CN=localhost','-addext','subjectAltName=DNS:localhost'],check=True,capture_output=True)
context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(str(setup/'capture.crt'),str(setup/'capture.key'))
server.socket=context.wrap_socket(server.socket,server_side=True)
thread=threading.Thread(target=server.serve_forever,daemon=True); thread.start()
body="## Summary\n\nA fixture's description uses plain characters.\n\n![After](fixture.png)\n\n<details>\n\n<summary>Validation details</summary>\n\n```text\nfixture evidence\n```\n\n</details>\n"
(setup/'body.md').write_text(body)
(setup/'gh-config').mkdir(exist_ok=True)
env=dict(os.environ,GH_HOST=f'localhost:{server.server_port}', GH_TOKEN='disposable-transport-only-token',GH_CONFIG_DIR=str(setup/'gh-config'),SSL_CERT_FILE=str(setup/'capture.crt'))
env.pop('GITHUB_TOKEN',None)
command=re.search(r'`(gh api markdown [^`]+)`',(evidence/'worker-pr-contract.md').read_text()).group(1)
try:
    runs=[]
    for label, cmd in [('previous literal-file argument', command.replace('-F text=@body.md','-f text=@body.md')),('emitted file-reading argument',command)]:
        result=subprocess.run(cmd.split(),env=env,cwd=setup,text=True,capture_output=True,timeout=20)
        runs.append({'label':label,'command':cmd,'exit_code':result.returncode,'stderr':result.stderr})
        if result.returncode: raise RuntimeError(result.stderr)
    assert received[0]['text']=='@body.md'
    assert received[1]['text']==body
    assert received[1]['mode']=='gfm'
    record={'scope':'Real gh CLI against disposable HTTP request capture; this does not validate GitHub Markdown rendering.','runs':runs,'previous_request':received[0],'emitted_request':received[1]}
    (evidence/'render-command-request.json').write_text(json.dumps(record,indent=2)+'\n')
    print('Real gh CLI: previous -f sent literal @body.md; emitted -F sent the complete proposed Markdown body and mode=gfm.')
finally:
    server.shutdown(); server.server_close(); thread.join()
