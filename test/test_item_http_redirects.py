"""Run actual acceptance helpers against synthetic loopback redirect servers."""
import argparse
import ast
import hashlib
import http.server
import json
from pathlib import Path
import threading
import urllib.error
import urllib.request

args = argparse.ArgumentParser()
args.add_argument('source', type=Path)
args.add_argument('--mcp', action='store_true')
args = args.parse_args()
source = ast.parse(args.source.read_text())
selected = [n for n in source.body if
    (isinstance(n, (ast.FunctionDef, ast.ClassDef)) and n.name in
     ('require', 'request', 'rpc', 'RejectRedirects')) or
    (isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'http' for t in n.targets))]

def require(condition, detail):
    if not condition:
        raise RuntimeError(detail)

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass
    def handle_request(self):
        self.server.received.append((self.command, self.path, bool(self.headers.get('Authorization'))))
        length = int(self.headers.get('Content-Length', '0'))
        self.rfile.read(length)
        if self.path in ('/probe', '/mcp') and self.server.redirect is not None:
            code, location = self.server.redirect
            self.send_response(code)
            self.send_header('Location', location)
            self.end_headers()
            return
        response = json.dumps({'jsonrpc': '2.0', 'id': 1, 'result': {'local': True}}).encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(response)))
        self.end_headers()
        self.wfile.write(response)
    do_GET = handle_request
    do_POST = handle_request

servers = [http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler) for _ in range(2)]
threads = []
for s in servers:
    s.received = []
    s.redirect = None
    t = threading.Thread(target=s.serve_forever, daemon=True)
    t.start()
    threads.append(t)
origin = f'http://127.0.0.1:{servers[0].server_port}'
foreign = f'http://127.0.0.1:{servers[1].server_port}'

def helpers(server_generation=1):
    ns = {'urllib': urllib, 'json': json, 'hashlib': hashlib,
          'origin': origin, 'token': 'synthetic-admin-redirect-control',
          'keeper_token': 'synthetic-worker-redirect-control',
          'records': [], 'rpc_sequence': 0, 'rpc_session': {},
          'server_generation': 1}
    exec(compile(ast.Module(body=selected, type_ignores=[]), str(args.source), 'exec'), ns)
    ns['server_generation'] = server_generation
    return ns

results = []
try:
    for same_origin in (True, False):
        destination = origin if same_origin else foreign
        for code in (301, 302, 303, 307, 308):
            for method in (('GET', 'POST') if args.mcp else ('GET',)):
                for s in servers:
                    s.received.clear()
                servers[0].redirect = (code, destination + '/redirect-target')
                ns = helpers()
                rejected = False
                if method == 'GET':
                    status, _, _ = ns['request']('/probe')
                    require(status == code, {'expected_status': code, 'actual_status': status, 'destination_requests': [r for server in servers for r in server.received if r[1] == '/redirect-target']})
                    try:
                        ns['require'](status == 200, 'redirect must fail acceptance')
                    except RuntimeError:
                        rejected = True
                    require(ns['records'][0]['status'] == code, 'redirect provenance was concealed')
                    require(ns['records'][0]['server_generation'] == 1, 'server generation provenance was concealed')
                else:
                    try:
                        ns['rpc']('tools/call', {})
                    except urllib.error.HTTPError as e:
                        require(e.code == code, 'wrong refusal status')
                        e.close()
                        rejected = True
                    require(not ns['records'], 'redirect recorded as successful RPC')
                forwarded = [r for s in servers for r in s.received if r[1] == '/redirect-target']
                require(rejected and not forwarded, f'accepted/forwarded {method} redirect')
                results.append({'method': method, 'redirect_status': code,
                                'same_origin': same_origin, 'rejected': True,
                                'destination_requests': 0})
    servers[0].redirect = None
    ns = helpers()
    require(ns['request']('/probe')[0] == 200, 'normal GET was rejected')
    require(ns['records'][-1]['server_generation'] == 1, 'normal GET missing server generation provenance')
    if args.mcp:
        require(ns['rpc']('tools/call', {}) == {'local': True}, 'normal RPC was rejected')
        require(ns['records'][-1]['server_generation'] == 1, 'normal RPC missing server generation provenance')
    ns_restarted = helpers(server_generation=2)
    require(ns_restarted['request']('/probe')[0] == 200, 'restarted GET was rejected')
    require(ns_restarted['records'][-1]['server_generation'] == 2, 'fixture server generation was concealed in GET')
    if args.mcp:
        require(ns_restarted['rpc']('tools/call', {}) == {'local': True}, 'restarted RPC was rejected')
        require(ns_restarted['records'][-1]['server_generation'] == 2, 'fixture server generation was concealed in RPC')
    print(json.dumps({'scope': 'actual extracted helpers, synthetic loopback TCP; no native run',
                      'source_sha256': hashlib.sha256(args.source.read_bytes()).hexdigest(),
                      'controls': results, 'direct_requests_pass': True}, indent=2))
finally:
    for s in servers:
        s.shutdown()
        s.server_close()
    for t in threads:
        t.join()
