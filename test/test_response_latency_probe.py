"""Exercise the real latency probe CLI against a fake persistent HTTP server."""

import gzip
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest


PROBE = Path(__file__).resolve().parents[1] / 'scripts/harness/perf/response_latency_probe.py'
TOOLS = '/api/v1/dashboard/tools'
SHELL = '/api/v1/dashboard/shell?light=true'
EXECUTION = '/api/v1/dashboard/execution'
TELEMETRY = '/api/v1/dashboard/telemetry/summary'


class ResponseLatencyProbeTest(unittest.TestCase):
    def run_probe(self, tools_payloads, *, compressed=False, extra_args=(), identity_changes=False, concurrent_gate=False, mcp_session=False):
        counts = {}
        session_headers = []
        gate = threading.Barrier(2) if concurrent_gate else None
        responses = {
            TOOLS: tools_payloads,
            SHELL: [{'status': 'initializing'}, {'status': 'ready'}],
            EXECUTION: [{'status': 'stale'}, {'status': 'ready'}],
            TELEMETRY: [{'status': 'ready', 'description': 'warming',
                         'tool_inventory': {'status': 'warming', 'tools': []}}],
        }

        class Handler(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def log_message(self, *_args):
                pass

            def reply(self, value, *, use_gzip=False, headers=()):
                body = json.dumps(value).encode()
                if use_gzip:
                    body = gzip.compress(body)
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                for name, value in headers:
                    self.send_header(name, value)
                if use_gzip:
                    self.send_header('Content-Encoding', 'gzip')
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                if self.path.startswith('/health'):
                    identity_count = counts.get('identity', 0)
                    counts['identity'] = identity_count + 1
                    self.reply({'status': 'ok', 'build': {
                        'binary_commit': 'fake-commit',
                        'executable_sha256': 'fake-binary-sha256',
                        'runtime_instance_id': (f'fake-runtime-{identity_count}'
                                                if identity_changes else 'fake-runtime'),
                    }})
                    return
                if gate is not None:
                    try:
                        gate.wait(timeout=2)
                    except threading.BrokenBarrierError:
                        self.reply({'error': 'requests did not overlap'})
                        return
                sequence = responses[self.path]
                ordinal = counts.get(self.path, 0)
                counts[self.path] = ordinal + 1
                self.reply(sequence[min(ordinal, len(sequence) - 1)],
                           use_gzip=compressed and self.path == TOOLS
                           and self.headers.get('Accept-Encoding') == 'gzip')

            def do_POST(self):
                request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                method = request['method']
                counts[method] = counts.get(method, 0) + 1
                headers = ()
                if mcp_session:
                    if method == 'initialize':
                        headers = (('Mcp-Session-Id', 'fixture-session'),)
                    else:
                        session_headers.append(self.headers.get('Mcp-Session-Id'))
                    if method == 'ping' and gate is not None:
                        try:
                            gate.wait(timeout=2)
                        except threading.BrokenBarrierError:
                            self.reply({'error': 'GET and MCP ping did not overlap'})
                            return
                self.reply({'jsonrpc': '2.0', 'id': request.get('id'), 'result': {}},
                           headers=headers)

            def do_DELETE(self):
                counts['cleanup'] = counts.get('cleanup', 0) + 1
                session_headers.append(self.headers.get('Mcp-Session-Id'))
                self.reply({})

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'result.json'
            server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                env = os.environ.copy()
                env.pop('RESPONSE_PROBE_TEST_TOKEN', None)
                result = subprocess.run(
                    [sys.executable, str(PROBE), '--base-url',
                     f'http://127.0.0.1:{server.server_port}',
                     '--output', str(output), '--samples', '2', '--timeout', '3',
                     '--target-ms', '10000', '--token-env', 'RESPONSE_PROBE_TEST_TOKEN', *extra_args],
                    env=env, capture_output=True, text=True, timeout=15,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(output.exists(), result.stdout)
                evidence = json.loads(output.read_text())
                printed = json.loads(result.stdout)
                self.assertEqual(printed['summary'], evidence['summary'])
                self.assertEqual(evidence['same_runtime'], not identity_changes)
                self.assertTrue(evidence['mcp_initialize']['valid'])
                self.assertFalse(evidence['authenticated'])
                if mcp_session:
                    self.assertEqual(counts.get('initialize'), 1)
                    self.assertEqual(counts.get('notifications/initialized'), 1)
                    self.assertEqual(counts.get('ping'), 2)
                    self.assertEqual(counts.get('cleanup'), 1)
                    self.assertEqual(session_headers, ['fixture-session'] * 4)
                    self.assertTrue(printed['mcp_available'])
                return evidence
            finally:
                server.shutdown()
                server.server_close()
                worker.join(timeout=2)

    def test_concurrent_requests_overlap_and_keep_invalid_samples(self):
        evidence = self.run_probe([{'status': 'warming'}, {'status': 'ready'}],
            compressed=True, concurrent_gate=True,
            extra_args=('--concurrent', '--path', TOOLS, '--path', TELEMETRY))
        self.assertTrue(evidence['concurrent'])
        self.assertEqual(evidence['summary'][TOOLS]['valid'], 1)
        self.assertFalse(evidence['summary'][TOOLS]['all_samples_within_target'])
        self.assertEqual(evidence['summary'][TELEMETRY]['valid'], 2)
        for ordinal in range(2):
            rows = [row for row in evidence['samples'] if row['ordinal'] == ordinal]
            self.assertEqual(len(rows), 2)
            self.assertLess(max(row['start_offset_ms'] for row in rows),
                            min(row['wire_end_offset_ms'] for row in rows))
        self.assertTrue(all(row['content_encoding'] == 'gzip'
                            for row in evidence['samples'] if row['label'] == TOOLS))

    def test_concurrent_mcp_session_ping_overlaps_get_and_cleans_up(self):
        evidence = self.run_probe([{'loaded': True}], compressed=True,
            concurrent_gate=True, mcp_session=True,
            extra_args=('--concurrent', '--path', TOOLS, '--require-json', '/loaded=true'))
        self.assertEqual(set(evidence['summary']), {TOOLS, 'mcp_ping'})
        self.assertEqual(evidence['summary']['mcp_ping']['valid'], 2)
        self.assertEqual(evidence['summary'][TOOLS]['valid'], 2)
        for ordinal in range(2):
            rows = [row for row in evidence['samples'] if row['ordinal'] == ordinal]
            self.assertEqual({row['label'] for row in rows}, {TOOLS, 'mcp_ping'})
            self.assertTrue(all(row['valid'] for row in rows))
            self.assertLess(max(row['start_offset_ms'] for row in rows),
                            min(row['wire_end_offset_ms'] for row in rows))

    def test_selected_get_json_requirement_excludes_unloaded_without_affecting_identity_or_mcp(self):
        evidence = self.run_probe([{'loaded': False}, {'loaded': True}],
                                  extra_args=('--path', TOOLS, '--require-json', '/loaded=true'))
        self.assertEqual(evidence['sample_paths'], [TOOLS])
        self.assertEqual(list(evidence['summary']), [TOOLS])
        samples = evidence['samples']
        self.assertEqual([row['valid'] for row in samples], [False, True])
        self.assertEqual(samples[0]['semantic_errors'],
                         [{'pointer': '/loaded', 'reason': 'expected value mismatch'}])
        self.assertEqual(evidence['summary'][TOOLS]['p95_ms'], samples[1]['total_ms'])
        self.assertFalse(evidence['summary'][TOOLS]['all_samples_within_target'])
        self.assertTrue(evidence['same_runtime'])
        self.assertTrue(evidence['mcp_initialize']['valid'])

    def test_requirement_mismatch_missing_pointer_and_json_boolean_type(self):
        cases = [({'loaded': 1}, '/loaded=true', 'expected value mismatch'),
                 ({'loaded': True}, '/missing=true', 'missing JSON pointer'),
                 ({'mode': 'warming'}, '/mode="ready"', 'expected value mismatch'),
                 ({'a/b': [{'~value': False}]}, '/a~1b/0/~0value=true', 'expected value mismatch')]
        for payload, requirement, reason in cases:
            with self.subTest(requirement=requirement, payload=payload):
                evidence = self.run_probe([payload], extra_args=('--path', TOOLS, '--require-json', requirement))
                self.assertEqual(evidence['summary'][TOOLS]['valid'], 0)
                self.assertIsNone(evidence['summary'][TOOLS]['p95_ms'])
                self.assertEqual(evidence['samples'][0]['semantic_errors'][0]['reason'], reason)

    def test_read_decode_and_client_timings_preserve_wire_total(self):
        evidence = self.run_probe([{'loaded': True}], compressed=True,
                                  extra_args=('--path', TOOLS, '--require-json', '/loaded=true'))
        for sample in evidence['samples']:
            self.assertEqual(sample['content_encoding'], 'gzip')
            self.assertGreaterEqual(sample['decode_ms'], 0)
            self.assertAlmostEqual(sample['total_ms'], sample['headers_ms'] + sample['body_read_ms'])
            self.assertAlmostEqual(sample['client_total_ms'], sample['total_ms'] + sample['decode_ms'])

    def test_identity_encoding_can_be_requested(self):
        evidence = self.run_probe([{'loaded': True}], compressed=True,
                                  extra_args=('--path', TOOLS, '--accept-encoding', 'identity'))
        self.assertEqual(evidence['accept_encoding'], 'identity')
        for sample in evidence['samples']:
            self.assertIsNone(sample['content_encoding'])

    def test_runtime_change_is_not_a_same_runtime_measurement(self):
        evidence = self.run_probe([{'loaded': True}], identity_changes=True,
                                  extra_args=('--path', TOOLS, '--require-json', '/loaded=true'))
        self.assertFalse(evidence['same_runtime'])
        self.assertNotEqual(evidence['identity_before'], evidence['identity_after'])

    def test_explicit_warming_then_ready_excludes_only_warming_sample(self):
        cases = [
            ({'status': 'warming'}, True, 'payload_status'),
            ({'status': 'ready', 'projection_diagnostics': {'cache_state': 'warming'}},
             False, 'cache_state'),
        ]
        for warming, compressed, field in cases:
            with self.subTest(field=field):
                evidence = self.run_probe([warming, {'status': 'ready', 'tools': []}],
                                          compressed=compressed)
                samples = [row for row in evidence['samples'] if row['label'] == TOOLS]
                self.assertEqual([row['status'] for row in samples], [200, 200])
                self.assertEqual([row['valid'] for row in samples], [False, True])
                self.assertEqual(samples[0][field], 'warming')
                summary = evidence['summary'][TOOLS]
                self.assertEqual(summary['samples'], 2)
                self.assertEqual(summary['valid'], 1)
                self.assertEqual(summary['statuses'], {'200': 2})
                self.assertFalse(summary['all_samples_within_target'])
                for percentile in ('p50_ms', 'p95_ms', 'p99_ms', 'max_ms'):
                    self.assertEqual(summary[percentile], samples[1]['total_ms'])
                self.assertLess(summary['max_ms'], evidence['target_ms'])
                self.assertEqual(evidence['summary'][SHELL]['valid'], 1)
                self.assertEqual(evidence['summary'][EXECUTION]['valid'], 2)
                self.assertEqual(evidence['summary'][EXECUTION]['stale_samples'], 1)
                self.assertFalse(evidence['summary'][EXECUTION]['all_samples_within_target'])
                # Readiness is explicit; descriptive/nested text is not guessed.
                self.assertEqual(evidence['summary'][TELEMETRY]['valid'], 2)
                self.assertTrue(evidence['summary'][TELEMETRY]['all_samples_within_target'])

    def test_all_warming_has_no_success_percentiles_or_target_pass(self):
        evidence = self.run_probe([{'status': 'warming',
                                   'projection_diagnostics': {'cache_state': 'warming'}}])
        summary = evidence['summary'][TOOLS]
        self.assertEqual(summary['samples'], 2)
        self.assertEqual(summary['valid'], 0)
        self.assertEqual(summary['statuses'], {'200': 2})
        self.assertFalse(summary['all_samples_within_target'])
        for percentile in ('p50_ms', 'p95_ms', 'p99_ms', 'max_ms'):
            self.assertIsNone(summary[percentile])


if __name__ == '__main__':
    unittest.main()
