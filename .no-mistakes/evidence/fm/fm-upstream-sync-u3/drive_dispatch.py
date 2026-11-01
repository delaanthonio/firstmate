from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shlex
import subprocess
import threading

root = Path.cwd()
home = root / '.test-phase/dispatch-home'
for d in ('data', 'state', 'config', 'projects', 'user'):
    (home / d).mkdir(parents=True, exist_ok=True)
evidence = Path('/Users/dela/.no-mistakes/evidence/01M6C0X5BHNQ0K1NAZ55FZ12GF')
brief = home / 'data/brief.md'
brief.write_text('# Task\n## Captain\'s intent\nFix the synthetic pager off-by-one.\n## Firstmate spec\nUse one page per call.\n')
rules = {'shared_quota': True, 'rules': [{'when': 'A bug fix with a stated root cause', 'use': {'harness': 'codex', 'effort': 'high'}}], 'default': {'harness': 'claude'}}
(home / 'config/crew-dispatch.json').write_text(json.dumps(rules))
requests = []
answer = {'model': 'disposable-systemone', 'answers': {'rule': {'type': 'choice', 'choice': 'rule_1', 'confidence': 0.99, 'probabilities': {'rule_1': 0.99, 'default': 0.01}}}, 'usage': {'input_tokens': 12, 'output_tokens': 8}}

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append({'path': self.path, 'body': body, 'authorization': self.headers.get('Authorization')})
        payload = json.dumps(answer).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
    def log_message(self, *args):
        pass

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
env = {k:v for k,v in os.environ.items() if k in ('PATH', 'NO_MISTAKES_GATE', 'TERM')}
env.update(HOME=str(home / 'user'), FM_HOME=str(home), TMPDIR=str(root / '.test-phase/tmp'), LC_ALL='C', FM_DISPATCH_PROVIDER='systemone', FM_DISPATCH_MODEL='fixture-classifier', FM_DISPATCH_BASE_URL=f'http://127.0.0.1:{server.server_port}')
log = (evidence / 'dispatch-cli-r2.log').open('w')

def run():
    command = ['bash', 'bin/fm-dispatch-resolve.sh', str(brief), '--project', 'synthetic-pager']
    log.write('$ FM_DISPATCH_PROVIDER=systemone FM_HOME=' + shlex.quote(str(home)) + ' ' + shlex.join(command) + '\n')
    r = subprocess.run(command, env=env, capture_output=True, text=True, timeout=35)
    log.write(r.stdout + r.stderr + 'exit=' + str(r.returncode) + '\n')
    log.flush()
    assert r.returncode == 0, r.stderr
    return r

try:
    r = run()
    assert 'status: clear' in r.stdout and "profile: --harness 'codex' --effort 'high'" in r.stdout
    assert len(requests) == 1 and requests[0]['path'] == '/v1/systemone'
    assert requests[0]['authorization'] is None
    assert 'synthetic pager' in json.dumps(requests[0]['body'])
    answer['answers']['rule']['confidence'] = 0.1
    answer['answers']['rule']['probabilities'] = {'rule_1': 0.1, 'default': 0.9}
    r = run()
    assert 'status: ambiguous' in r.stdout and 'profile:' not in r.stdout
    assert len(requests) == 2
    (home / 'config/dispatch-never-send').write_text('SYNTHETIC   PAGER\n')
    r = run()
    assert not r.stdout and 'nothing sent' in r.stderr
    assert len(requests) == 2, 'never-send guard leaked a request'
    log.write('Local endpoint received exactly two requests; never-send refusal made no third request.\n')
    log.write('Captured request bodies (synthetic data only):\n' + json.dumps(requests, indent=2) + '\n')
finally:
    server.shutdown()
    server.server_close()
    thread.join()
    log.close()
