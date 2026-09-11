#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import unittest
import runpy
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('refresh', ROOT/'scripts/refresh-model-release-evidence.py')
refresh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(refresh)


class RefreshEvidence(unittest.TestCase):
    def setUp(self):
        self.catalog = json.loads((ROOT/'config/model-releases.json').read_text())

    def test_checked_evidence_is_not_changed_by_a_new_fetch(self):
        before = json.dumps(self.catalog)
        report = refresh.observe(self.catalog, observed_at='2026-09-11T00:00:00Z',
                                 fetch=lambda _: {'status': 'observed', 'sha256': 'changed-body-hash', 'bytes': 20})
        self.assertEqual(json.dumps(self.catalog), before)
        self.assertFalse(report['release_evidence_updated'])
        self.assertTrue(report['sources'])

    def test_account_created_timestamp_does_not_create_release(self):
        requested = []
        def discover(choice, **kwargs):
            requested.append((choice, kwargs))
            return [{'id': 'fixture-new-model', 'created': 1788998400, 'release_date': '2026-09-10',
                     'api_key': 'DO_NOT_PROJECT'}], 'untrusted raw error description'
        request = {'schema': 'masc.model_discovery_request.v1', 'connections': [{
            'id': 'local-fixture', 'publisher': 'fixture', 'choice': 'openai_compatible',
            'endpoint': 'http://127.0.0.1:8000/v1', 'api_key_env': 'FIXTURE_KEY', 'command': ''}]}
        report = refresh.observe(self.catalog, observed_at='2026-09-10T00:00:00Z',
                                 fetch=lambda _: {'status': 'unavailable'}, discovery=request, discover=discover)
        self.assertEqual(requested[0][0], 'openai_compatible')
        self.assertEqual(report['account_discovery'][0]['models'], [{'model_id': 'fixture-new-model', 'release': {'status': 'unknown'}}])
        serialized = json.dumps(report)
        for forbidden in ('DO_NOT_PROJECT', '1788998400', 'FIXTURE_KEY', '127.0.0.1', 'untrusted raw'):
            self.assertNotIn(forbidden, serialized)

    def test_real_installer_discovery_abi_drops_provider_creation_date(self):
        helper = runpy.run_path(str(ROOT/'scripts/install-runtime-setup.py'))
        calls = []
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                calls.append(self.path)
                data = json.dumps({'data': [{'id': 'local-served-model', 'created': 1788998400}]}).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            def log_message(self, *args):
                pass
        server = HTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            request = {'schema': 'masc.model_discovery_request.v1', 'connections': [{
                'id': 'fixture', 'publisher': 'local', 'choice': 'openai_compatible',
                'endpoint': f'http://127.0.0.1:{server.server_port}/v1', 'api_key_env': '', 'command': ''}]}
            report = refresh.observe(self.catalog, observed_at='2026-09-10T00:00:00Z',
                                     fetch=lambda _: {'status': 'unavailable'}, discovery=request,
                                     discover=helper['discover_models'])
            self.assertEqual(calls, ['/v1/models'])
            self.assertEqual(report['account_discovery'][0]['models'],
                             [{'model_id': 'local-served-model', 'release': {'status': 'unknown'}}])
        finally:
            server.shutdown()
            thread.join()
            server.server_close()

    def test_duplicate_json_fields_rejected(self):
        with self.assertRaises(ValueError):
            refresh.strict_json('{"status":"unknown","status":"official_release"}')

    def test_unknown_release_stays_unknown(self):
        self.assertTrue(any(row['release'] == {'status': 'unknown'} for row in self.catalog['models']))
        bad = json.loads(json.dumps(self.catalog))
        bad['models'][-1]['release']['created'] = 12345
        with self.assertRaises(ValueError):
            refresh.validate_catalog(bad)

    def test_bad_source_and_duplicate_identity_rejected(self):
        bad = json.loads(json.dumps(self.catalog))
        bad['models'][0]['release']['source_url'] = 'https://user:secret@example.org/release'
        with self.assertRaises(ValueError):
            refresh.validate_catalog(bad)
        bad = json.loads(json.dumps(self.catalog))
        bad['models'].append(bad['models'][0])
        with self.assertRaises(ValueError):
            refresh.validate_catalog(bad)


if __name__ == '__main__':
    unittest.main()
