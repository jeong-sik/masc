#!/usr/bin/env python3
"""Exercise the installed setup command against a workspace-bound HTTP peer.

Model inference and guest execution are measured separately with the real
onboarding acceptance; this checks ownership and preserves the imp manifest.
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = None


@unittest.skipUnless(BINARY, 'pass --binary for native setup checks')
class Setup(unittest.TestCase):
    def test_old_state_is_reported_before_any_setup_changes(self):
        old_goal = {'id':'old-goal','title':'Old goal','phase':'executing','priority':3,
                    'created_at':'2020-01-01T00:00:00Z','updated_at':'2020-01-01T00:00:00Z'}
        states = [
            ('config/keepers/imp.toml', '[keeper]\n'),
            ('config/keepers/imp.toml', '[keeper]\ninstructions = ""\n'),
            ('config/keepers/imp.toml', '[keeper]\ninstructions = "OPERATOR_TODO"\n'),
            ('config/keepers/bad name.toml', '[keeper]\ninstructions = "Act on assigned tasks."\n'),
            ('config/keepers/imp.toml', '[keeper]\nautoboot_enabled = true\n'),
            ('goals.json', json.dumps({'version':1,'updated_at':'2020-01-01T00:00:00Z','goals':[old_goal]})),
            ('goal_verifications.json', json.dumps({'version':1,'updated_at':'2020-01-01T00:00:00Z',
                'records':[{'goal_id':'old-goal','updated_at':'2020-01-01T00:00:00Z','completion':{'state':'proven'}}]})),
            ('goal-verification-runs.jsonl', json.dumps({'event':'register','id':'old-run','started_at':1,
                'registration':{'goal_id':'old-goal','review_kind':'proof','authority_actor':'old'}})+'\n'),
            ('goals.json.last-good', json.dumps({'version':1,'updated_at':'2020-01-01T00:00:00Z','goals':[old_goal]})),
        ]
        for relative, content in states:
            with self.subTest(relative=relative), tempfile.TemporaryDirectory(prefix='masc-setup-preflight-') as tmp:
                base=Path(tmp);path=base/'.masc'/relative;path.parent.mkdir(parents=True);path.write_text(content)
                def snapshot():
                    return {str(p.relative_to(base)):(p.read_bytes(),p.stat().st_ino,p.stat().st_mode,p.stat().st_mtime_ns)
                            for p in base.rglob('*') if p.is_file()}
                before=snapshot()
                result=subprocess.run([BINARY,'setup','--base-path',str(base),'--no-tui'],
                    env={'PATH':'/usr/bin:/bin','HOME':tmp},capture_output=True,text=True,timeout=30)
                self.assertNotEqual(result.returncode,0)
                self.assertIn(str(path),result.stderr)
                self.assertIn('choose_new_workspace',result.stderr)
                self.assertIn('return_without_changes',result.stderr)
                self.assertIn('No workspace files were changed',result.stderr)
                self.assertEqual(snapshot(),before)
                self.assertFalse((base/'.masc/auth').exists())
                self.assertFalse((base/'.masc/config/runtime.toml').exists())

    def scenario(self, foreign=False, missing_key=False, stale_token=False, linked_root=False):
        with tempfile.TemporaryDirectory(prefix='masc-setup-') as tmp:
            base = Path(tmp)
            commands = base / 'commands'
            commands.mkdir()
            docker = commands / 'docker'
            docker.write_text('#!/bin/sh\nexit 0\n')
            docker.chmod(0o755)
            env = {key: value for key, value in os.environ.items()
                   if key in ('PATH', 'HOME', 'LANG', 'TMPDIR')}
            env['PATH'] = str(commands) + os.pathsep + env['PATH']
            def run(*args):
                return subprocess.run([BINARY, *args, '--base-path', str(base)],
                                      env=env, text=True, capture_output=True, timeout=30)
            initialized = run('init')
            self.assertEqual(initialized.returncode, 0, initialized.stderr)
            if linked_root:
                volume = base / 'deployment-volume'
                (base / '.masc').rename(volume)
                (base / '.masc').symlink_to(volume, target_is_directory=True)
            config = base / '.masc/config'
            for name in ('runtime.toml', 'agent-core-models-overlay.toml'):
                (config / name).write_bytes((ROOT / 'scripts/fixtures/release-evidence' / name).read_bytes())
            # This model exists only in this workspace's overlay. Setup must
            # load the same catalog the wizard validated, not an embedded alias.
            runtime = config / 'runtime.toml'
            runtime.write_text(runtime.read_text().replace('deepseek-v4-flash','setup-fixture-owned-model'))
            overlay = config / 'agent-core-models-overlay.toml'
            with overlay.open('a') as stream:
                stream.write('''
[[models]]
id_prefix = "setup-fixture-owned-model"
provider_name = "ollama_cloud"
base = "openai_chat"
max_context_tokens = 32768
supports_tools = true
supports_native_streaming = true
''')
            if missing_key:
                runtime = config / 'runtime.toml'
                runtime.write_text(runtime.read_text() + '\n[providers.ollama_cloud.credentials]\ntype = "env"\nkey = "MASC_SETUP_TEST_KEY"\n')
            manifest = config / 'keepers/imp.toml'
            original = manifest.read_bytes()
            if stale_token:
                token = base / '.masc/auth/local-admin.token'
                token.parent.mkdir(parents=True, exist_ok=True)
                token.write_text('revoked-operator-token')
            posted = []
            model_requests = []
            class Handler(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    self.send({'paths': {'effective_base_path': str(base.parent if foreign else base)},
                               'startup': {'state_ready': True}})
                def do_POST(self):
                    if self.path == '/v1/chat/completions':
                        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                        model_requests.append(request)
                        results = [message for message in request['messages'] if message['role'] == 'tool']
                        if results:
                            # Consume the actual native challenge tool result;
                            # the fixture never receives the nonce beforehand.
                            challenge = json.loads(results[-1]['content'])['challenge']
                            message = {'role':'assistant','content':json.dumps({'challenge':challenge})}
                            finish = 'stop'
                        else:
                            name = request['tools'][0]['function']['name']
                            message = {'role':'assistant','content':None,'tool_calls':[{
                                'id':'readiness-fixture-call','type':'function',
                                'function':{'name':name,'arguments':'{}'}}]}
                            finish = 'tool_calls'
                        if request.get('stream'):
                            delta = dict(message)
                            if 'tool_calls' in delta:
                                delta['tool_calls'] = [dict(call,index=index) for index,call in enumerate(delta['tool_calls'])]
                            chunks = [dict(id='fixture',object='chat.completion.chunk',created=0,model=request['model'],
                                           choices=[dict(index=0,delta=delta,finish_reason=None)]),
                                      dict(id='fixture',object='chat.completion.chunk',created=0,model=request['model'],
                                           choices=[dict(index=0,delta={},finish_reason=finish)])]
                            data = (''.join('data: '+json.dumps(chunk)+'\n\n' for chunk in chunks)+'data: [DONE]\n\n').encode()
                            self.send_response(200)
                            self.send_header('Content-Type','text/event-stream')
                            self.send_header('Content-Length',str(len(data)))
                            self.end_headers()
                            self.wfile.write(data)
                        else:
                            self.send(dict(id='fixture',object='chat.completion',created=0,model=request['model'],
                                           choices=[dict(index=0,message=message,finish_reason=finish)],
                                           usage=dict(prompt_tokens=1,completion_tokens=1,total_tokens=2)))
                        return
                    token = base / '.masc/auth/local-admin.token'
                    expected = token.read_text().strip() if token.exists() else ''
                    if not expected or expected == 'revoked-operator-token' or self.headers.get('Authorization') != 'Bearer ' + expected:
                        self.send_response(401)
                        self.end_headers()
                        return
                    posted.append((self.path, json.loads(self.rfile.read(int(self.headers['Content-Length'])))))
                    self.send({'ok': True, 'action': 'up', 'name': 'imp',
                               'detail': {'name': 'imp'}})
                def send(self, body):
                    data = json.dumps(body).encode()
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                def log_message(self, *args):
                    pass
            with http.server.HTTPServer(('127.0.0.1', 0), Handler) as server:
                for name in ('runtime.toml','agent-core-models-overlay.toml'):
                    path = config / name
                    path.write_text(path.read_text().replace('http://127.0.0.1:9/v1',
                                                            'http://127.0.0.1:'+str(server.server_port)+'/v1'))
                thread = threading.Thread(target=server.serve_forever)
                thread.start()
                try:
                    result = run('setup', '--no-tui', '--port', str(server.server_port))
                finally:
                    server.shutdown()
                    thread.join()
            self.assertEqual(manifest.read_bytes(), original)
            if foreign or missing_key:
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(posted, [])
                self.assertFalse((base / '.masc/auth/local-admin.token').exists())
                self.assertIn('MASC_SETUP_TEST_KEY' if missing_key else 'Port belongs to workspace', result.stderr)
            else:
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(posted, [('/api/v1/keepers/imp/boot', {'name': 'imp'})])
                self.assertIn('Model response and harmless tool roundtrip verified.', result.stdout)
                self.assertEqual(len(model_requests),2)
                self.assertTrue(all(request['model']=='setup-fixture-owned-model' for request in model_requests))
                self.assertTrue(any(message['role']=='tool' for message in model_requests[-1]['messages']))
                self.assertNotIn((base / '.masc/auth/local-admin.token').read_text().strip(), result.stdout)

    def test_supported_linked_deployment_root(self):
        self.scenario(linked_root=True)

    def test_preserves_default_imp_and_starts_by_name(self):
        self.scenario()

    def test_refuses_another_workspace_before_minting_or_starting(self):
        self.scenario(foreign=True)

    def test_recovers_a_revoked_operator_token(self):
        self.scenario(stale_token=True)

    def test_missing_model_key_has_actionable_error(self):
        self.scenario(missing_key=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True)
    args, remaining = parser.parse_known_args()
    BINARY = str(Path(args.binary).resolve())
    Setup.__unittest_skip__ = False
    unittest.main(argv=[__file__, *remaining])
