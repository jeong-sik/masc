#!/usr/bin/env python3
"""Run only a fake HTTP server and fake executable against tui_latency_probe.py.

No real MASC server or TUI is used. Output and executable fixtures remain in
--output-dir for inspection. Each case binds an ephemeral loopback port.
"""
import argparse
import hashlib
import http.server
import json
from pathlib import Path
import subprocess
import sys
import threading

CASES = ('missing_base', 'empty_base', 'blank_base', 'final_binary_removal', 'after_build_null')


def run_case(harness, root, scenario):
    case = root / scenario
    case.mkdir()
    base = case / 'base'
    base.mkdir()
    binary = case / 'fake_tui'
    marker = case / 'launched'
    out = case / 'evidence'
    program = '''import os,pathlib,signal,sys,time
pathlib.Path(MARKER).write_text('launched')
def stop(*_):
    pathlib.Path(os.environ['MASC_TUI_FRAME_TIMING']).write_text('  build[Overview] n=1 mean_ms=0.25\\n  build[Memory] n=1 mean_ms=0.5\\n')
    if REMOVE:
        pathlib.Path(__file__).unlink()
    sys.exit(0)
signal.signal(signal.SIGTERM,stop)
sys.stdout.write('MASC Overview\\x1b[?7h')
sys.stdout.flush()
while True: time.sleep(.01)
'''.replace('MARKER', repr(str(marker))).replace('REMOVE', repr(scenario == 'final_binary_removal'))
    binary.write_text('#!' + sys.executable + '\n' + program)
    binary.chmod(0o700)
    requests = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            health = {'build': {'runtime_instance_id': 'fake-runtime'},
                      'paths': {'effective_base_path': str(base)}, 'scheduler': {}, 'gc': {}}
            if scenario == 'missing_base':
                health['paths'] = {}
            if scenario == 'empty_base':
                health['paths']['effective_base_path'] = ''
            if scenario == 'blank_base':
                health['paths']['effective_base_path'] = '   '
            if scenario == 'after_build_null' and len(requests) > 1:
                health['build'] = None
            raw = json.dumps(health).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def log_message(self, *_args):
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    argv = [sys.executable, str(harness), '--binary', str(binary), '--base-path', str(base),
            '--output-dir', str(out), '--port', str(server.server_port), '--tabs', '2',
            '--tab-interval', '.02', '--settle', '.02', '--ready-timeout', '1',
            '--termination-grace', '1']
    try:
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=8)
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    (case / 'stdout.txt').write_text(proc.stdout)
    (case / 'stderr.txt').write_text(proc.stderr)
    result_path = out / 'result.json'
    result = json.loads(result_path.read_text()) if result_path.exists() else None
    record = {'scenario': scenario, 'argv': argv, 'returncode': proc.returncode,
              'launched': marker.exists(), 'http_requests': requests,
              'result_retained': result is not None,
              'timing_retained': (out / 'frame-timing.txt').exists(),
              'stderr': proc.stderr, 'result': result}
    if scenario in ('missing_base', 'empty_base', 'blank_base'):
        assert proc.returncode == 2 and not marker.exists() and not out.exists(), record
        assert 'effective base path' in proc.stderr, record
    else:
        assert proc.returncode == 1 and result is not None, record
        assert result['observation_complete'] is False and record['timing_retained'], record
        assert result['exit_code'] == 0 and result['forced_kill'] is False, record
        assert len(result['tab_sent_at_s']) == 2, record
        assert result['observed_surfaces'] == ['Overview', 'Memory'], record
        assert result['observation_options']['tabs'] == 2, record
        assert result['navigation_scope'].endswith('not acknowledged'), record
        if scenario == 'final_binary_removal':
            assert result['sha256_after'] is None and 'final binary hash:' in result['error'], record
        else:
            assert result['server_after']['build'] is None and result['same_runtime'] is False, record
            assert result['sha256_before'] == result['sha256_after'], record
    record['expected_failure_verified'] = True
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--harness', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--case', choices=CASES, action='append')
    args = parser.parse_args()
    harness = args.harness.resolve(strict=True)
    args.output_dir.mkdir(parents=True, exist_ok=False)
    root = args.output_dir.resolve()
    report = {'harness': str(harness), 'harness_sha256': hashlib.sha256(harness.read_bytes()).hexdigest(),
              'scope': 'fake HTTP server and fake executable only; not MASC performance',
              'cases': [run_case(harness, root, case) for case in args.case or CASES]}
    (root / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'output_dir': str(root), 'harness_sha256': report['harness_sha256'],
                      'cases': [{key: val for key, val in case.items() if key not in ('result', 'argv')}
                                for case in report['cases']]}, indent=2))


if __name__ == '__main__':
    main()
