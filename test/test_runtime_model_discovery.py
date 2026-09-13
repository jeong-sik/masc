"""Exercise native model discovery against HTTP fixtures, without model inference."""
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest

BINARY = None
if len(sys.argv) > 2 and sys.argv[1] == '--binary':
    BINARY = str(Path(sys.argv.pop(2)).resolve())
    sys.argv.pop(1)


@unittest.skipUnless(BINARY, 'requires the CI-built native executable')
class NativeDiscovery(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.addCleanup(self.home.cleanup)
        self.calls = []
        self.posts = []
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                owner.calls.append((self.path, {key.lower(): value for key, value in self.headers.items()}))
                code, headers, body = owner.respond(self.path)
                payload = body if isinstance(body, bytes) else json.dumps(body).encode()
                self.send_response(code)
                for key, value in headers.items():
                    self.send_header(key, value)
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *args):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                owner.posts.append((self.path, {key.lower(): value for key, value in self.headers.items()}, body))
                code, payload = owner.respond_post(self.path, body)
                payload = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
                self.send_response(code)
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.endpoint = 'http://127.0.0.1:' + str(self.server.server_port)
        self.respond = lambda path: (200, {}, {'data': []})
        self.respond_post = lambda path, body: (200, {})

    def invoke(self, **fields):
        spec = Path(self.home.name, 'connection.json')
        spec.write_text(json.dumps(dict(choice='openai_compatible', endpoint=self.endpoint, **fields)))
        env = dict(os.environ, HOME=self.home.name, XDG_CONFIG_HOME=self.home.name + '/config')
        for key in list(env):
            if key.startswith('MASC_') or key.startswith('AGENT_CORE_') or key in ('OPENAI_API_KEY', 'OLLAMA_CLOUD_API_KEY', 'OLLAMA_API_KEY'):
                env.pop(key)
        return subprocess.run([BINARY, 'runtime-discover-models', '--spec', str(spec)],
                              capture_output=True, text=True, env=env, timeout=30)

    def test_malformed_credential_references_make_no_request(self):
        for fields in [dict(credential_file=12), dict(credential_file=''),
                       dict(credential_file=' /private/key'), dict(credential_file=None),
                       dict(api_key_env=12), dict(api_key_env=''), dict(api_key_env=None),
                       dict(credential_file='/private/key', api_key_env='A_KEY')]:
            with self.subTest(fields=fields):
                result = self.invoke(**fields)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls, [])

    def test_duplicate_credential_reference_is_refused(self):
        spec = Path(self.home.name, 'duplicate.json')
        spec.write_text('{"choice":"openai_compatible","endpoint":' + json.dumps(self.endpoint)
                        + ',"api_key_env":"FIRST","api_key_env":"SECOND"}')
        result = subprocess.run([BINARY, 'runtime-discover-models', '--spec', str(spec)],
                                capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls, [])

    def test_missing_explicit_or_registry_credential_makes_no_request(self):
        for fields in [dict(api_key_env='MASC_DISCOVERY_MISSING_KEY'), dict(provider_id='openai-responses')]:
            with self.subTest(fields=fields):
                result = self.invoke(**fields)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("credential is unavailable", result.stderr)
                self.assertEqual(self.calls, [])

    def test_anonymous_explicit_credential_keeps_environment_alias_precedence(self):
        assert BINARY is not None
        spec = Path(self.home.name, 'aliased-credential.json')
        spec.write_text(json.dumps(dict(choice='openai_compatible', endpoint=self.endpoint,
                                        api_key_env='OLLAMA_CLOUD_API_KEY')))
        for primary in ('primary-fixture-key', ''):
            with self.subTest(primary=bool(primary)):
                self.calls.clear()
                env = os.environ.copy()
                env.update(OLLAMA_CLOUD_API_KEY=primary, OLLAMA_API_KEY='fallback-fixture-key')
                result = subprocess.run(
                    [BINARY, 'runtime-discover-models', '--spec', str(spec)],
                    capture_output=True, text=True, env=env, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(self.calls), 1)
                self.assertEqual(self.calls[0][1]['authorization'],
                                 'Bearer ' + (primary or 'fallback-fixture-key'))

    def test_unknown_named_provider_is_not_anonymous(self):
        result = self.invoke(provider_id='unregistered-discovery-fixture')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("credential is unavailable", result.stderr)
        self.assertEqual(self.calls, [])

    def test_anonymous_local_server_remains_supported(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls), 1)
        self.assertNotIn('authorization', self.calls[0][1])

    def test_file_credential_is_sent_only_as_header_and_dates_are_not_release_dates(self):
        key = Path(self.home.name, 'key')
        key.write_text('secret-probe-key\n')
        key.chmod(0o600)
        self.respond = lambda path: (200, {}, {'data': [dict(
            id='recent-model', context_length=131072, supported_parameters=['tools'], created=12345)]})
        result = self.invoke(credential_file=str(key))
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertFalse(data['account_availability_verified'])
        self.assertEqual(data['models'][0]['context'], 131072)
        self.assertEqual(data['models'][0]['provider_listed_at'], 12345)
        self.assertIsNone(data['models'][0]['release_date'])
        self.assertTrue(data['models'][0]['tools'])
        self.assertEqual(self.calls[0][0], '/models')
        self.assertEqual(self.calls[0][1].get('authorization'), 'Bearer secret-probe-key')
        self.assertNotIn('secret-probe-key', result.stdout + result.stderr)

    def serving_context(self, choice, model='selected-model', load=False):
        key = Path(self.home.name, 'serving-key')
        key.write_text('private-serving-key')
        key.chmod(0o600)
        spec = Path(self.home.name, 'serving.json')
        spec.write_text(json.dumps(dict(choice=choice, endpoint=self.endpoint,
                                        credential_file=str(key))))
        return subprocess.run([BINARY, 'runtime-serving-context', '--spec', str(spec), '--model', model]
                              + (['--load'] if load else []), capture_output=True, text=True, timeout=30)

    def test_serving_context_distinguishes_anonymous_from_unknown_named_provider(self):
        assert BINARY is not None
        self.respond = lambda path: (200, {}, dict(data=[dict(id='selected-model')])
                                     if path == '/models' else
                                     dict(default_generation_settings=dict(n_ctx=32768)))
        for provider in (None, 'unregistered-serving-fixture'):
            with self.subTest(provider=provider):
                self.calls.clear()
                fields = dict(choice='llama_cpp', endpoint=self.endpoint)
                if provider is not None:
                    fields['provider_id'] = provider
                spec = Path(self.home.name, 'anonymous-serving.json')
                spec.write_text(json.dumps(fields))
                result = subprocess.run(
                    [BINARY, 'runtime-serving-context', '--spec', str(spec),
                     '--model', 'selected-model'], capture_output=True, text=True, timeout=30)
                if provider is None:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(json.loads(result.stdout)['context'], 32768)
                    self.assertEqual([path for path, _ in self.calls], ['/models', '/props'])
                    self.assertTrue(all('authorization' not in headers for _, headers in self.calls))
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("credential is unavailable", result.stderr)
                    self.assertEqual(self.calls, [])

    def test_ollama_selected_model_uses_running_window_and_private_credential(self):
        self.respond_post = lambda path, body: (200, dict(
            capabilities=['completion', 'tools'], parameters='', model_info={'qwen.context_length': 999999})
            if path == '/api/show' else dict(done=True))
        self.respond = lambda path: (200, {}, dict(models=[dict(name='selected-model', context_length=16384)]))
        result = self.serving_context('ollama', load=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data['context'], 16384)
        self.assertEqual(data['context_source'], 'running_model')
        self.assertEqual([path for path, _, _ in self.posts], ['/api/show', '/api/generate'])
        for _, headers, body in self.posts:
            self.assertEqual(headers['authorization'], 'Bearer private-serving-key')
            self.assertEqual(body['model'], 'selected-model')
        self.assertEqual(self.calls[0][1]['authorization'], 'Bearer private-serving-key')
        self.assertNotIn('private-serving-key', result.stdout + result.stderr)

    def test_ollama_architecture_limit_is_not_a_serving_window(self):
        self.respond_post = lambda path, body: (200, dict(parameters='', model_info={'qwen.context_length': 999999}))
        self.respond = lambda path: (200, {}, dict(models=[]))
        result = self.serving_context('ollama')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(json.loads(result.stdout)['context'])
        self.assertEqual([path for path, _, _ in self.posts], ['/api/show'])

    def test_ollama_invalid_running_metadata_does_not_fall_back_to_configured_window(self):
        self.respond_post = lambda path, body: (200, dict(parameters='num_ctx 8192'))
        responses = [dict(models=[dict(name='selected-model', context_length=value)])
                     for value in (None, 0, -1, '16384', True)]
        responses += [dict(models=[dict(name='selected-model', context_length=8192),
                                   dict(name='selected-model', context_length=16384)]),
                      dict(models=[dict(name='selected-model', context_length=8192)] * 2),
                      dict(models=[dict(name='selected-model', model='different', context_length=8192)]),
                      b'{"models":[{"name":"selected-model","context_length":8192,"context_length":16384}]}',
                      b'{"models":[],"models":[{"name":"selected-model","context_length":16384}]}']
        for response in responses:
            with self.subTest(response=response):
                self.respond = lambda path: (200, {}, response)
                result = self.serving_context('ollama')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')

    def test_ollama_only_absent_running_metadata_uses_explicit_configuration(self):
        self.respond_post = lambda path, body: (200, dict(parameters='num_ctx 8192'))
        for rows in ([], [dict(name='selected-model')]):
            self.respond = lambda path: (200, {}, dict(models=rows))
            result = self.serving_context('ollama')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)['context'], 8192)
            self.assertEqual(json.loads(result.stdout)['context_source'], 'configured_model')

    def test_llama_invalid_or_duplicate_props_are_not_missing_metadata(self):
        props = [dict(default_generation_settings=dict(n_ctx=value))
                 for value in (None, 0, -1, '32768', True)]
        props += [dict(default_generation_settings=None),
                  b'{"default_generation_settings":{"n_ctx":8192,"n_ctx":32768}}',
                  b'{"default_generation_settings":{},"default_generation_settings":{"n_ctx":32768}}']
        for response in props:
            with self.subTest(response=response):
                self.respond = lambda path: (200, {}, dict(data=[dict(id='selected-model')])
                                             if path == '/models' else response)
                result = self.serving_context('llama_cpp')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
        self.respond = lambda path: (200, {}, dict(data=[dict(id='selected-model')])
                                     if path == '/models' else dict(default_generation_settings={}))
        result = self.serving_context('llama_cpp')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(json.loads(result.stdout)['context'])

    def test_llama_router_context_is_not_assigned_to_a_different_model(self):
        self.respond = lambda path: (200, {}, dict(data=[dict(id='one'), dict(id='two')]))
        result = self.serving_context('llama_cpp', model='one')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(json.loads(result.stdout)['context'])
        self.assertEqual([path for path, _ in self.calls], ['/models'])

    def test_llama_single_served_model_reads_its_actual_n_ctx(self):
        self.respond = lambda path: (200, {}, dict(data=[dict(id='selected-model')]) if path == '/models'
                                     else dict(default_generation_settings=dict(n_ctx=32768)))
        result = self.serving_context('llama_cpp')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['context'], 32768)
        self.assertEqual([path for path, _ in self.calls], ['/models', '/props'])

    def test_messages_auth_and_all_pages_use_native_api(self):
        key = Path(self.home.name, 'key')
        key.write_text('messages-probe-key')
        key.chmod(0o600)
        self.respond = lambda path: (200, {}, {'data': [{'id': 'second' if 'after_id' in path else 'first'}],
            'has_more': 'after_id' not in path, 'last_id': 'first'})
        spec = Path(self.home.name, 'messages.json')
        spec.write_text(json.dumps(dict(choice='messages', provider_kind='anthropic',
                                        endpoint=self.endpoint, credential_file=str(key))))
        result = subprocess.run([BINARY, 'runtime-discover-models', '--spec', str(spec)],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([row['id'] for row in json.loads(result.stdout)['models']], ['first', 'second'])
        self.assertEqual([path for path, _ in self.calls], ['/v1/models', '/v1/models?after_id=first'])
        for _, headers in self.calls:
            self.assertEqual(headers.get('x-api-key'), 'messages-probe-key')
            self.assertIn('anthropic-version', headers)
            self.assertNotIn('authorization', headers)

    def test_http_error_does_not_echo_provider_body(self):
        self.respond = lambda path: (401, {}, {'error': 'SECRET_PROVIDER_BODY'})
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('HTTP 401', result.stderr)
        self.assertNotIn('SECRET_PROVIDER_BODY', result.stdout + result.stderr)

    def test_redirect_is_not_followed(self):
        self.respond = lambda path: (302, {'Location': self.endpoint + '/redirected'}, {})
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.calls), 1)

    def test_private_file_required_before_request(self):
        key = Path(self.home.name, 'key')
        key.write_text('secret')
        key.chmod(0o644)
        result = self.invoke(credential_file=str(key))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls, [])


if __name__ == '__main__':
    unittest.main()
