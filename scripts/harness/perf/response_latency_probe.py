#!/usr/bin/env python3
"""Read-only, persistent-connection latency samples from an existing MASC.

No builds, server boots, or synthetic Keeper traffic. Raw observations retain
HTTP failures; successful percentiles alone never count as goal completion.
"""

import argparse
from collections import Counter
from datetime import datetime, timezone
import gzip
import http.client
import json
import math
import os
from pathlib import Path
import time
from urllib.parse import urlsplit


def percentile(values, fraction):
    return sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-url', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--samples', type=int, default=30)
    parser.add_argument('--timeout', type=float, default=10)
    parser.add_argument('--target-ms', type=float, default=0.1)
    parser.add_argument('--interval', type=float, default=0,
                        help='seconds between sample rounds; recorded in evidence')
    parser.add_argument('--token-env', default='MCP_TOKEN')
    args = parser.parse_args()
    url = urlsplit(args.base_url)
    if url.scheme not in ('http', 'https') or not url.hostname or url.username:
        parser.error('base-url must be an HTTP(S) origin without credentials')
    if url.path not in ('', '/') or url.query or url.fragment:
        parser.error('base-url must be an origin without path, query or fragment')
    if args.samples < 1 or args.timeout <= 0 or args.target_ms <= 0 or args.interval < 0:
        parser.error('samples, timeout and target-ms must be positive')
    connection_type = (http.client.HTTPSConnection if url.scheme == 'https'
                       else http.client.HTTPConnection)
    connection = connection_type(url.hostname, url.port, timeout=args.timeout)
    token = os.environ.get(args.token_env)
    headers = {'Accept-Encoding': 'gzip'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    rows = []

    def request(label, path, *, method='GET', payload=None, extra=None):
        started = time.perf_counter_ns()
        row = {'label': label, 'path': path, 'method': method}
        try:
            body = None if payload is None else json.dumps(payload)
            request_headers = headers | (extra or {})
            if body is not None:
                request_headers['Content-Type'] = 'application/json'
            connection.request(method, path, body, request_headers)
            response = connection.getresponse()
            headers_at = time.perf_counter_ns()
            wire = response.read()
            finished = time.perf_counter_ns()
            row.update(status=response.status, wire_bytes=len(wire),
                       headers_ms=(headers_at - started) / 1e6,
                       total_ms=(finished - started) / 1e6,
                       content_encoding=response.getheader('Content-Encoding'),
                       server_timing=response.getheader('Server-Timing'))
            decoded = gzip.decompress(wire) if row['content_encoding'] == 'gzip' else wire
            if 'text/event-stream' in (response.getheader('Content-Type') or ''):
                events = []
                for block in decoded.decode().replace('\r\n', '\n').split('\n\n'):
                    data = '\n'.join(line[5:].lstrip(' ') for line in block.splitlines()
                                     if line.startswith('data:'))
                    if data:
                        events.append(json.loads(data))
                parsed = next((event for event in events
                               if isinstance(event, dict) and payload is not None
                               and event.get('id') == payload.get('id')), None)
            else:
                parsed = json.loads(decoded) if decoded else None
            row['valid'] = (200 <= response.status < 300
                            and isinstance(parsed, dict) and 'error' not in parsed)
            if isinstance(parsed, dict):
                diagnostics = parsed.get('projection_diagnostics', {})
                row['cache_state'] = (diagnostics.get('cache_state')
                                      if isinstance(diagnostics, dict) else None)
                status = parsed.get('status')
                row['payload_status'] = status if isinstance(status, str) else None
                if row['payload_status'] == 'initializing' or row['cache_state'] == 'initializing':
                    row['valid'] = False
                row['stale'] = (row['cache_state'] in ('stale', 'expired', 'error')
                                 or row['payload_status'] in ('stale', 'error', 'degraded'))
            if payload is not None and 'id' in payload:
                row['valid'] = (row['valid'] and parsed.get('id') == payload['id']
                                and 'result' in parsed)
            return row, parsed, response
        except (OSError, http.client.HTTPException, ValueError) as error:
            row.update(valid=False, error=type(error).__name__,
                       total_ms=(time.perf_counter_ns() - started) / 1e6)
            connection.close()
            return row, None, None

    initial, health_before, _ = request('health_identity', '/health?full=1')
    session = None
    protocol = '2025-11-25'
    init, _, response = request('mcp_initialize', '/mcp', method='POST', payload={
        'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {
            'protocolVersion': protocol, 'capabilities': {},
            'clientInfo': {'name': 'masc-latency-probe', 'version': '1'}}},
        extra={'Accept': 'application/json, text/event-stream'})
    if init['valid'] and response:
        session = response.getheader('Mcp-Session-Id')
    mcp_headers = {'Accept': 'application/json, text/event-stream',
                   'Mcp-Protocol-Version': protocol}
    if session:
        mcp_headers['Mcp-Session-Id'] = session
        request('mcp_initialized', '/mcp', method='POST', payload={
            'jsonrpc': '2.0', 'method': 'notifications/initialized'}, extra=mcp_headers)
    paths = ['/health', '/api/v1/dashboard/shell?light=true',
             '/api/v1/dashboard/execution', '/api/v1/dashboard/tools',
             '/api/v1/dashboard/telemetry/summary']
    try:
        for ordinal in range(args.samples):
            if ordinal and args.interval:
                time.sleep(args.interval)
            for path in paths:
                row, _, _ = request(path, path)
                rows.append(row | {'ordinal': ordinal})
            if session:
                row, _, _ = request('mcp_ping', '/mcp', method='POST', payload={
                    'jsonrpc': '2.0', 'id': ordinal + 2, 'method': 'ping'},
                    extra=mcp_headers)
                rows.append(row | {'ordinal': ordinal})
        final, health_after, _ = request('health_identity', '/health?full=1')
    finally:
        if session:
            request('mcp_cleanup', '/mcp', method='DELETE', extra=mcp_headers)
        connection.close()
    summary = {}
    for label in dict.fromkeys(row['label'] for row in rows):
        group = [row for row in rows if row['label'] == label]
        valid = [row['total_ms'] for row in group if row['valid']]
        summary[label] = {
            'samples': len(group), 'valid': len(valid),
            'stale_samples': sum(row.get('stale', False) for row in group),
            'statuses': dict(Counter(str(row.get('status')) for row in group)),
            'p50_ms': percentile(valid, .50) if valid else None,
            'p95_ms': percentile(valid, .95) if valid else None,
            'p99_ms': percentile(valid, .99) if valid else None,
            'max_ms': max(valid) if valid else None,
            'all_samples_within_target': (len(valid) == len(group)
                                          and not any(row.get('stale', False) for row in group)
                                          and max(valid) <= args.target_ms)}
    def identity(health):
        if not health:
            return None
        build = health.get('build', {})
        fields = {key: build.get(key) for key in
                  ('binary_commit', 'executable_sha256', 'runtime_instance_id')}
        return fields if all(fields.values()) else None
    result = {
        'observed_at': datetime.now(timezone.utc).isoformat(),
        'base_url': args.base_url, 'target_ms': args.target_ms,
        'authenticated': bool(token), 'interval_s': args.interval,
        'scope': 'sequential HTTP roundtrip including transfer; no injected load',
        'identity_before': identity(health_before),
        'identity_after': identity(health_after),
        'same_runtime': (initial['valid'] and final['valid']
                         and identity(health_before) is not None
                         and identity(health_before) == identity(health_after)),
        'scheduler_before': (health_before or {}).get('scheduler'),
        'scheduler_after': (health_after or {}).get('scheduler'),
        'mcp_initialize': init, 'summary': summary, 'samples': rows}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'same_runtime': result['same_runtime'],
                      'mcp_available': bool(session), 'summary': summary}, indent=2))


if __name__ == '__main__':
    main()
