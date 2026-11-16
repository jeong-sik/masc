"""Offline Muse host reproduction; writes all generated state below --out."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
import uuid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--muse', required=True, help='Installed Muse binary, without its auto-update launcher')
    parser.add_argument('--out', required=True)
    args = parser.parse_args()
    root = Path(args.out).resolve()
    root.mkdir(parents=True, exist_ok=False)
    outer = root / 'outer-project'
    outer.mkdir(mode=0o700)
    git_env = {'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null'}
    if 'PATH' in os.environ:
        git_env['PATH'] = os.environ['PATH']
    def git_init(path):
        subprocess.run(['git', 'init', '--quiet', '--template=', '--', str(path)], env=git_env, check=True)
    git_init(outer)
    (outer / '.mcp.json').write_text(json.dumps({'mcpServers': {'unrelated': {
        'type': 'http', 'url': 'http://127.0.0.1:1/mcp',
        'headers': {'Authorization': 'Bearer ${UNRELATED_SECRET}'}}}}))
    (outer / 'AGENTS.md').write_text('Unrelated ancestor instructions must not enter the private project.\n')
    parent = outer / 'keeper-private-project'
    parent.mkdir(mode=0o700)
    workspace = parent / 'workspace'
    workspace.mkdir(mode=0o700)
    env = {'PATH': os.environ.get('PATH', ''), 'TBH_CREDENTIAL_BACKEND': 'file'}
    for key, part in [('HOME', 'home'), ('XDG_CONFIG_HOME', 'config'), ('XDG_DATA_HOME', 'data'),
                      ('XDG_CACHE_HOME', 'cache'), ('XDG_STATE_HOME', 'state'),
                      ('XDG_RUNTIME_DIR', 'run'), ('TMPDIR', 'tmp')]:
        path = root / part
        path.mkdir(mode=0o700)
        env[key] = str(path)
    config = root / 'config/muse'
    config.mkdir(mode=0o700)
    (config / 'settings.json').write_text(json.dumps({'schema_version': 1,
        'permissions': {'schema_version': 1, 'default_profile': ':ask-me'}}))
    requests = []
    class Mcp(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass
        def do_POST(self):
            message = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            requests.append(message['method'])
            if 'id' not in message:
                self.send_response(202)
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            method = message['method']
            if method == 'initialize':
                result = {'protocolVersion': message['params']['protocolVersion'],
                          'capabilities': {'tools': {}}, 'serverInfo': {'name': 'masc-probe', 'version': '1'}}
            elif method == 'tools/list':
                result = {'tools': [{'name': 'probe', 'description': 'Read an offline diagnostic marker',
                                    'inputSchema': {'type': 'object', 'properties': {}}}]}
            else:
                raise AssertionError('Unexpected MCP call: ' + method)
            body = json.dumps({'jsonrpc': '2.0', 'id': message['id'], 'result': result}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Mcp)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    mcp_config = {'mcpServers': {'masc': {'transport': 'streamableHttp',
        'url': f'http://127.0.0.1:{server.server_port}/mcp', 'headers': {}, 'mode': 'required'}}}
    reports = []
    def run(case, resume=None):
        first_mcp_request = len(requests)
        incoming = queue.Queue()
        with (root / (case + '.stderr.log')).open('w') as stderr:
            proc = subprocess.Popen([args.muse, 'serve', '--provider', 'echo', '--disable-write',
                '--disable-shell', '--trust-workspace'], cwd=workspace, env=env,
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, text=True)
            def collect():
                for line in proc.stdout:
                    incoming.put(json.loads(line))
                incoming.put(None)
            threading.Thread(target=collect, daemon=True).start()
            events = []
            def send(method, params, request_id):
                proc.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': request_id, 'method': method, 'params': params}) + '\n')
                proc.stdin.flush()
            def until(predicate):
                while True:
                    message = incoming.get(timeout=30)
                    if message is None:
                        raise RuntimeError('Muse closed stdout')
                    events.append(message)
                    if predicate(message):
                        return message
            report = {'case': case}
            try:
                send('initialize', {'clientInfo': {'name': 'masc_probe', 'version': '1'},
                    'capabilities': {'requestedCapabilities': ['sessionMcp'], 'userInputDialogs': False}}, 1)
                init = until(lambda m: m.get('id') == 1)
                report['version'] = init['result']['serverInfo']['version']
                proc.stdin.write('{"jsonrpc":"2.0","method":"initialized"}\n')
                proc.stdin.flush()
                method = 'session/resume' if resume else 'session/start'
                params = {'commandId': str(uuid.uuid7()), 'config': mcp_config}
                params.update({'sessionId': resume, 'excludeItems': True} if resume else {
                    'workspaceRoot': str(workspace), 'approvalMode': 'denyUnmatched'})
                send(method, params, 2)
                opened = until(lambda m: m.get('id') == 2)
                report['session_ok'] = 'result' in opened
                if 'error' in opened:
                    report['error'] = opened['error']
                else:
                    session_id = opened['result']['session']['sessionId']
                    report['session_id'] = session_id
                    report['turns'] = []
                    for request_id in [3, 4]:
                        send('turn/start', {'sessionId': session_id, 'commandId': str(uuid.uuid7()),
                            'input': [{'type': 'text', 'text': 'Offline continuity probe.'}]}, request_id)
                        ack = until(lambda m: m.get('id') == request_id)
                        if 'error' in ack:
                            raise RuntimeError(str(ack['error']))
                        turn_id = ack['result']['turnId']
                        terminal = until(lambda m: m.get('method') == 'turn/completed'
                            and m.get('params', {}).get('sessionId') == session_id
                            and m['params'].get('turnId') == turn_id)
                        report['turns'].append({'turn_id': turn_id,
                            'terminal': terminal['params']['terminal']})
                    report['mcp_requests'] = requests[first_mcp_request:]
            finally:
                proc.stdin.close()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.terminate()
                    proc.wait(timeout=5)
                (root / (case + '.wire.json')).write_text(json.dumps(events, indent=2))
            reports.append(report)
            (root / 'results.json').write_text(json.dumps(reports, indent=2))
            print(json.dumps(report), flush=True)
            return report
    try:
        before = run('before')
        assert before['error']['data']['reason'] == 'session_mcp_base_unavailable', before
        (parent / '.git').mkdir(mode=0o700)
        git_init(parent)
        after = run('after')
        def check_completed(report):
            assert report['session_ok'] and [t['terminal'] for t in report['turns']] == ['completed'] * 2, report
            assert all(method in report['mcp_requests'] for method in [
                'initialize', 'notifications/initialized', 'tools/list']), report
        check_completed(after)
        resumed = run('resumed', resume=after['session_id'])
        assert resumed['session_id'] == after['session_id'], resumed
        check_completed(resumed)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
