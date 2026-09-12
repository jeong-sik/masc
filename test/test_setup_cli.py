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
    def test_recorded_workspace_survives_a_different_working_directory(self):
        assert BINARY is not None
        for spelling in ('.', 'workspace', 'workspace-link'):
            with self.subTest(spelling=spelling), tempfile.TemporaryDirectory(prefix='masc-default-cwd-') as tmp:
                root = Path(tmp)
                source = root / 'source'
                other = root / 'other'
                source.mkdir()
                (other / '.masc').mkdir(parents=True)
                if spelling == 'workspace-link':
                    (source / 'workspace').mkdir()
                    (source / spelling).symlink_to(source / 'workspace', target_is_directory=True)
                env = {'PATH': '/usr/bin:/bin', 'HOME': tmp,
                       'XDG_CONFIG_HOME': str(root / 'config')}
                initialized = subprocess.run(
                    [BINARY, 'init', '--base-path', spelling, '--record-default'],
                    cwd=source, env=env, capture_output=True, text=True, timeout=30)
                self.assertEqual(initialized.returncode, 0, initialized.stderr)
                expected = (source / spelling).resolve()
                record = root / 'config/masc/default-base-path'
                self.assertEqual(record.read_text(), str(expected) + '\n')
                resolved = subprocess.run(
                    [BINARY, 'setup-preflight'], cwd=other, env=env,
                    capture_output=True, text=True, timeout=30)
                self.assertEqual(resolved.returncode, 0, resolved.stderr)
                self.assertEqual(json.loads(resolved.stdout)['base_path'], str(expected))

    def test_recording_does_not_overwrite_a_preexisting_partial_file(self):
        assert BINARY is not None
        with tempfile.TemporaryDirectory(prefix='masc-default-partial-') as tmp:
            root = Path(tmp)
            config = root / 'config/masc'
            config.mkdir(parents=True)
            sentinel = root / 'operator-file'
            sentinel.write_text('preserve me\n')
            partial = config / 'default-base-path.partial'
            partial.symlink_to(sentinel)
            env = {'PATH': '/usr/bin:/bin', 'HOME': tmp,
                   'XDG_CONFIG_HOME': str(root / 'config')}
            workspace = root / 'workspace'
            initialized = subprocess.run(
                [BINARY, 'init', '--base-path', str(workspace), '--record-default'],
                env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(initialized.returncode, 0, initialized.stderr)
            self.assertEqual(sentinel.read_text(), 'preserve me\n')
            self.assertTrue(partial.is_symlink())
            record = config / 'default-base-path'
            self.assertFalse(record.is_symlink())
            self.assertEqual(record.read_text(), str(workspace.resolve()) + '\n')
            self.assertEqual(record.stat().st_mode & 0o777, 0o600)
            self.assertEqual(sorted(path.name for path in config.iterdir()),
                             ['default-base-path', 'default-base-path.partial'])

    def test_failed_record_publication_cleans_only_its_own_temporary_file(self):
        assert BINARY is not None
        with tempfile.TemporaryDirectory(prefix='masc-default-publish-') as tmp:
            root = Path(tmp)
            config = root / 'config/masc'
            record = config / 'default-base-path'
            record.mkdir(parents=True)
            sentinel = record / 'operator-file'
            sentinel.write_text('preserve me\n')
            env = {'PATH': '/usr/bin:/bin', 'HOME': tmp,
                   'XDG_CONFIG_HOME': str(root / 'config')}
            initialized = subprocess.run(
                [BINARY, 'init', '--base-path', str(root / 'workspace'), '--record-default'],
                env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(initialized.returncode, 0, initialized.stderr)
            self.assertIn('default workspace not recorded: could not write', initialized.stdout)
            self.assertEqual(sentinel.read_text(), 'preserve me\n')
            self.assertEqual([path.name for path in config.iterdir()], ['default-base-path'])

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

    def test_sandbox_selection_is_refused_before_any_work(self):
        """--sandbox-profile / --microvm-backend pairing, checked as usage.

        setup used to require Docker whatever profile the keeper declared, and
        offered no way to say otherwise, so a mac without Docker could not
        finish setup at all (measured on a fresh mac, 2026-09-10). cmdliner
        cannot express "this flag only means something under that value", so
        the rule is checked in the command and has to keep reporting as usage
        rather than silently ignoring the flag.
        """
        cases = [
            (['--sandbox-profile','nope'], '--sandbox-profile takes one of'),
            (['--microvm-backend','nerdctl_kata'], '--microvm-backend requires --sandbox-profile microvm'),
            (['--sandbox-profile','docker','--microvm-backend','nerdctl_kata'],
             '--microvm-backend requires --sandbox-profile microvm'),
            (['--sandbox-profile','microvm','--microvm-backend','bogus'],
             '--microvm-backend takes one of'),
        ]
        for extra, expected in cases:
            with self.subTest(extra=extra), tempfile.TemporaryDirectory(prefix='masc-setup-sandbox-') as tmp:
                base = Path(tmp) / 'ws'
                base.mkdir()
                result = subprocess.run(
                    [BINARY,'setup','--base-path',str(base),'--no-tui'] + extra,
                    env={'PATH':'/usr/bin:/bin','HOME':tmp},
                    capture_output=True, text=True, timeout=60)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)
                # Refused as usage: nothing was seeded on the way out.
                self.assertFalse((base/'.masc').exists(), 'a usage error must not seed a workspace')

    def scenario(self, foreign=False, missing_key=False, stale_token=False, linked_root=False, unsupported_sandbox=False, reject_resume=False):
        with tempfile.TemporaryDirectory(prefix='masc-setup-') as tmp:
            base = Path(tmp)
            commands = base / 'commands'
            commands.mkdir()
            docker = commands / 'docker'
            docker.write_text("#!/bin/sh\nif [ \"$1\" = info ]; then echo '{\"OSType\":\"linux\",\"SecurityOptions\":[]}'; fi\nexit 0\n")
            docker.chmod(0o755)
            env = {key: value for key, value in os.environ.items()
                   if key in ('PATH', 'HOME', 'LANG', 'TMPDIR')}
            env['HOME'] = tmp
            env['XDG_CONFIG_HOME'] = str(base / 'user-config')
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
                (config / name).write_bytes((ROOT / 'scripts/fixtures/release-evidence' / name).read_bytes().replace(b'ollama_cloud', b'setup_fixture'))
            # This model exists only in this workspace's overlay. Setup must
            # load the same catalog the wizard validated, not an embedded alias.
            runtime = config / 'runtime.toml'
            runtime.write_text(runtime.read_text().replace('deepseek-v4-flash','setup-fixture-owned-model'))
            overlay = config / 'agent-core-models-overlay.toml'
            with overlay.open('a') as stream:
                stream.write('''
[[models]]
id_prefix = "setup-fixture-owned-model"
provider_name = "setup_fixture"
base = "openai_chat"
max_context_tokens = 32768
supports_tools = true
supports_native_streaming = true
''')
            if missing_key:
                runtime = config / 'runtime.toml'
                runtime.write_text(runtime.read_text() + '\n[providers.setup_fixture.credentials]\ntype = "env"\nkey = "MASC_SETUP_TEST_KEY"\n')
            manifest = config / 'keepers/imp.toml'
            original = manifest.read_bytes()
            if stale_token:
                token = base / '.masc/auth/local-admin.token'
                token.parent.mkdir(parents=True, exist_ok=True)
                token.write_text('revoked-operator-token')
            posted = []
            accepted_auth = []
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
                    body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                    posted.append((self.path, body))
                    accepted_auth.append((self.path, self.headers.get('Authorization'), self.headers.get('x-masc-agent')))
                    if self.path == '/api/v1/runtime/setup/resume':
                        if reject_resume:
                            self.send({'error': 'fixture resume unavailable'}, status=503)
                        else:
                            self.send({'runtime_ready': True, 'exact_output_authority_available': False,
                                       'model_setup': {'status': 'available', 'reason': None, 'message': None}})
                    elif self.path == '/api/v1/keepers/imp/boot':
                        self.send({'ok': True, 'action': 'up', 'name': 'imp',
                                   'detail': {'name': 'imp'}})
                    else:
                        self.send({'error': 'unexpected setup request'}, status=404)
                def send(self, body, status=200):
                    data = json.dumps(body).encode()
                    self.send_response(status)
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
                    verification = run('runtime-verify','setup_fixture.setup-fixture-owned-model')
                    receipt = json.loads(verification.stdout)
                    self.assertEqual(receipt['schema'],'masc.runtime_verification.v1')
                    self.assertEqual(receipt['runtime_id'],'setup_fixture.setup-fixture-owned-model')
                    if missing_key:
                        self.assertEqual(verification.returncode,2,verification.stderr)
                        self.assertEqual(receipt['status'],'unavailable')
                        self.assertEqual(receipt['failure']['code'],'missing_credential')
                    else:
                        self.assertEqual(verification.returncode,0,verification.stdout+verification.stderr)
                        self.assertEqual(receipt['status'],'verified')
                        self.assertEqual(receipt['model'],'setup-fixture-owned-model')
                        self.assertEqual(receipt['observed_model'],'setup-fixture-owned-model')
                        self.assertEqual(receipt['checks'],{'response':True,'tool_called':True,'tool_roundtrip':True})
                    sandbox_args = ['--sandbox-profile','microvm','--microvm-backend','microsandbox'] if unsupported_sandbox else []
                    result = run('setup', '--no-tui', '--port', str(server.server_port), *sandbox_args)
                finally:
                    server.shutdown()
                    thread.join()
            self.assertEqual(manifest.read_bytes(), original)
            if foreign or missing_key or unsupported_sandbox:
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(posted, [])
                self.assertFalse((base / '.masc/auth/local-admin.token').exists())
                self.assertIn('MASC_SETUP_TEST_KEY' if missing_key else 'microsandbox cannot express' if unsupported_sandbox else 'Port belongs to workspace', result.stderr)
            elif reject_resume:
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(posted, [('/api/v1/runtime/setup/resume', {})])
                self.assertIn('Activating saved model settings', result.stderr)
            else:
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(posted, [('/api/v1/runtime/setup/resume', {}),
                                          ('/api/v1/keepers/imp/boot', {'name': 'imp'})])
                persisted = (base / '.masc/auth/local-admin.token').read_text().strip()
                self.assertTrue(all(auth == 'Bearer ' + persisted for _, auth, _ in accepted_auth))
                self.assertEqual(accepted_auth[0][2], 'local-admin')
                self.assertIn('Model response and harmless tool roundtrip verified.', result.stdout)
                self.assertEqual(len(model_requests),4)
                self.assertTrue(all(request['model']=='setup-fixture-owned-model' for request in model_requests))
                self.assertTrue(any(message['role']=='tool' for message in model_requests[-1]['messages']))
                self.assertNotIn((base / '.masc/auth/local-admin.token').read_text().strip(), result.stdout)

    def test_resume_refusal_prevents_keeper_boot(self):
        self.scenario(reject_resume=True)

    def test_failed_new_sandbox_preserves_existing_manifest(self):
        self.scenario(unsupported_sandbox=True)

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
