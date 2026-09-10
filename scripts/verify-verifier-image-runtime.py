"""Production Keeper task_done and completion reviewer with synthetic HTTP providers.

No model quality claim: records actual image delivery through configured runtime
selection, without reviewer hooks or manually written verification/task ledgers.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.request import Request, build_opener, HTTPRedirectHandler, ProxyHandler


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary-dir', type=Path, required=True)
    parser.add_argument('--expected-commit', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--port', type=int, default=18945)
    parser.add_argument('--image-file', type=Path, default=Path(__file__).resolve().parents[1] / 'test/fixtures/verifier-images/page.png')
    parser.add_argument('--expected-outcome', choices=['image_delivery', 'aggregate_rejection'], default='image_delivery')
    a = parser.parse_args()
    manifest = json.loads((a.binary_dir / 'manifest.json').read_text())
    assert manifest['commit'] == a.expected_commit
    for name, digest in manifest['sha256'].items():
        assert hashlib.sha256((a.binary_dir / name).read_bytes()).hexdigest() == digest, name
    binary = (a.binary_dir / 'main_eio.exe').resolve()
    binary.chmod(binary.stat().st_mode | 0o100)
    a.output.mkdir(parents=True, exist_ok=False)
    out = a.output.resolve()
    base = out / 'base'
    config = base / '.masc/config'
    config.mkdir(parents=True)
    keeper = 'image-producer'
    artifact_root = base / '.masc/playground/docker' / keeper
    artifact_root.mkdir(parents=True)
    png = a.image_file.read_bytes()
    refs = ['artifact:page1.png', 'artifact:page2.png', 'artifact:page3.png']
    for reference in refs:
        (artifact_root / reference.removeprefix('artifact:')).write_bytes(png)
    token = secrets.token_hex(32)
    requests = {'producer': [], 'verifier': []}
    fixture_errors = []
    delivered_images = []
    image_capture_complete = threading.Event()
    verifier_finished = threading.Event()

    class Provider(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            raw_request = self.rfile.read(int(self.headers['Content-Length']))
            if token.encode() in raw_request:
                fixture_errors.append('credential echo withheld')
                self.send_error(400)
                return
            body = json.loads(raw_request)
            lane = 'verifier' if body['model'] == 'image-verifier' else 'producer'
            index = len(requests[lane])
            requests[lane].append(body)
            save(out / f'{lane}-request-{index:03}.json', body)
            names = [tool['function']['name'] for tool in body.get('tools', [])]
            name = None
            arguments = None
            if lane == 'producer':
                if index == 0:
                    name, arguments = 'keeper_task_claim', {'task_id': 'task-001'}
                elif index == 1:
                    name, arguments = 'keeper_task_done', {'task_id': 'task-001', 'result': 'Submitted three complete synthetic rendered PNG pages for independent byte-delivery inspection.', 'evidence_refs': refs}
            elif index == 0:
                for message in body['messages']:
                    content = message.get('content')
                    if isinstance(content, list):
                        delivered_images.extend(part['image_url']['url'] for part in content if part.get('type') == 'image_url')
                expected_uri = 'data:image/png;base64,' + base64.b64encode(png).decode()
                matched = delivered_images == [expected_uri] * 3
                if not matched:
                    fixture_errors.append(f'Expected three exact images, observed {len(delivered_images)}')
                image_capture_complete.set()
                name = 'report_review_verdict'
                arguments = {'verdict': 'APPROVE' if matched else 'REJECT', 'reason': 'Synthetic HTTP fixture received three exact PNG data URIs; byte transport only, no visual quality judgement.' if matched else 'Synthetic image delivery mismatch.'}
            if name is not None and name not in names:
                fixture_errors.append(f'{lane} missing actual tool schema {name}')
                name = None
            if name is None:
                message = {'role': 'assistant', 'content': 'Synthetic fixture finished.'}
                finish = 'stop'
            else:
                message = {'role': 'assistant', 'content': None, 'tool_calls': [{'id': f'{lane}-{index}', 'type': 'function', 'function': {'name': name, 'arguments': json.dumps(arguments)}}]}
                finish = 'tool_calls'
            usage = {'prompt_tokens': 10, 'completion_tokens': 10, 'total_tokens': 20}
            if body.get('stream'):
                if 'tool_calls' in message:
                    message['tool_calls'][0]['index'] = 0
                chunks = [{'id': f'{lane}-fixture', 'object': 'chat.completion.chunk', 'model': body['model'], 'choices': [{'index': 0, 'delta': message, 'finish_reason': None}]}, {'id': f'{lane}-fixture', 'object': 'chat.completion.chunk', 'choices': [{'index': 0, 'delta': {}, 'finish_reason': finish}], 'usage': usage}]
                raw = (''.join('data: ' + json.dumps(chunk) + '\n\n' for chunk in chunks) + 'data: [DONE]\n\n').encode()
                content_type = 'text/event-stream'
            else:
                raw = json.dumps({'id': f'{lane}-fixture', 'model': body['model'], 'choices': [{'index': 0, 'message': message, 'finish_reason': finish}], 'usage': usage}).encode()
                content_type = 'application/json'
            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            if lane == 'verifier' and finish == 'stop':
                verifier_finished.set()

    provider = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=provider.serve_forever, daemon=True).start()
    fixtures = Path(__file__).parent / 'fixtures/release-evidence'
    runtime = (fixtures / 'runtime.toml').read_text()
    runtime += '\n[runtime.exact_output_lanes.verifier_exact]\nslots = ["image_fixture.vision"]\n'
    runtime += f'\n[providers.image_fixture]\nprotocol = "openai-compatible-http"\nendpoint = "http://127.0.0.1:{provider.server_port}/v1"\n'
    overlay = (fixtures / 'agent-core-models-overlay.toml').read_text()
    overlay += f'\n[[providers]]\nid = "image_fixture"\nkind = "openai_compat"\nbase_url = "http://127.0.0.1:{provider.server_port}/v1"\nrequest_path = "/chat/completions"\napi_key_env = ""\ncapabilities_base = "openai_chat"\n'
    for slot, model, vision in [('producer', 'image-producer', False), ('vision', 'image-verifier', True)]:
        runtime += f'\n[models.{slot}]\napi-name = "{model}"\nmax-context = 131072\ntools-support = true\nstreaming = true\n[image_fixture.{slot}]\nmax-request-body-bytes = 2097152\n'
        overlay += f'\n[[models]]\nid_prefix = "{model}"\nprovider_name = "image_fixture"\nbase = "openai_chat"\nmax_context_tokens = 131072\nmax_output_tokens = 4096\nsupports_tools = true\nsupports_tool_choice = true\nsupports_response_format_json = true\nsupports_native_streaming = true\nsupports_image_input = {str(vision).lower()}\n[[targets]]\nid = "image_fixture.{slot}"\nprovider_ref = "image_fixture"\nmodel_id = "{model}"\n'
    (config / 'runtime.toml').write_text(runtime)
    (config / 'agent-core-models-overlay.toml').write_text(overlay)
    env = {k: v for k, v in os.environ.items() if k in ['PATH', 'HOME', 'TMPDIR', 'LANG', 'LC_ALL', 'USER', 'SHELL']}
    env.update(MASC_ADMIN_TOKEN=token, MASC_BASE_PATH=str(base), MASC_GRPC_ENABLED='0', MASC_WS_ENABLED='0', MASC_KEEPER_AUTONOMOUS_ENABLED='false')
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', a.port))
    log = (out / 'server.log').open('wb')
    server = subprocess.Popen([str(binary), '--base-path', str(base), '--port', str(a.port)], cwd=base, env=env, stdout=log, stderr=subprocess.STDOUT)
    opener = build_opener(ProxyHandler({}), NoRedirect)
    counter, session = 0, None
    admission_started = False
    operation_id = None
    safe_to_stop = False
    receipt = {'scope': 'actual Keeper task_done and production verifier runtime; synthetic providers, no visual semantic acceptance', 'status': 'started', 'harness_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), 'expected_commit': a.expected_commit, 'expected_outcome': a.expected_outcome, 'base_path': str(base), 'port': a.port, 'server_pid': server.pid, 'manifest': manifest, 'image_bytes': len(png), 'image_sha256': hashlib.sha256(png).hexdigest(), 'artifact_total_bytes': len(png) * 3}
    save(out / 'receipt.json', receipt)
    def http(path, body=None, *, authenticated=True, expected_status=200):
        nonlocal counter, session
        counter += 1
        headers = {'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream', 'x-agent-name': 'image-proof-operator'}
        if authenticated:
            headers['Authorization'] = 'Bearer ' + token
        if session:
            headers['Mcp-Session-Id'] = session
        request = Request(f'http://127.0.0.1:{a.port}' + path, data=None if body is None else json.dumps(body).encode(), headers=headers)
        try:
            response = opener.open(request)
        except HTTPError as error:
            response = error
        with response:
            raw = response.read().decode()
            status = response.status
            session = response.headers.get('Mcp-Session-Id', session)
        if token in raw:
            raise ValueError('Credential echo withheld')
        save(out / f'http-{counter:03}.json', {'path': path, 'request': body, 'authenticated': authenticated, 'status': status, 'raw': raw})
        assert status == expected_status, (path, status, raw)
        lines = [line[6:] for line in raw.splitlines() if line.startswith('data: ')]
        return json.loads(next(line for line in lines if '"id"' in line) if lines else raw)

    def mcp(name, arguments):
        result = http('/mcp', {'jsonrpc': '2.0', 'id': counter + 1, 'method': 'tools/call', 'params': {'name': name, 'arguments': arguments}})['result']
        assert not result.get('isError'), result
        if result.get('structuredContent') is not None:
            return result['structuredContent']
        text = result['content'][0]['text']
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            return text

    def observe(path):
        while True:
            try:
                return http(path)
            except (URLError, ConnectionError) as error:
                save(out / f'observation-error-{counter:03}.json', {'path': path, 'error': str(error), 'server_pid': server.pid, 'action': 'continue_read_on_same_server'})
                if server.poll() is not None:
                    raise RuntimeError('Server exited during observation') from error
                time.sleep(0.5)

    def read_task():
        backlog = json.loads((base / '.masc/tasks/backlog.json').read_text())
        matches = [task for task in backlog['tasks'] if task['id'] == 'task-001']
        if len(matches) != 1:
            raise ValueError('Primary backlog must contain exactly task-001')
        task = matches[0]
        if task['status'] not in ['todo', 'claimed', 'in_progress', 'awaiting_verification', 'done', 'cancelled']:
            raise ValueError('Unknown task status')
        save(out / 'task-primary-readback.json', task)
        return task

    def read_committed_verdict():
        records = [json.loads(path.read_text()) for path in (base / '.masc/verifications').glob('*.json')]
        matches = [record for record in records if record['task_id'] == 'task-001' and record['worker'] == keeper]
        if len(matches) != 1:
            raise ValueError('Expected one actual submitted verification request')
        request = matches[0]
        events = []
        for path in (base / '.masc/events').glob('*/*.jsonl'):
            events.extend(json.loads(line) for line in path.read_text().splitlines())
        verdicts = [event for event in events if event.get('type') == 'task_completion_verdict'
                    and event['task_id'] == 'task-001' and event['verification_id'] == request['id']]
        if not verdicts:
            return None
        if len(verdicts) != 1:
            raise ValueError('Expected one committed verdict for the exact verification request')
        verdict = verdicts[0]
        assert verdict['producer'] == keeper
        assert verdict['evaluator_runtime'] == 'image_fixture.vision'
        assert request['output']['evidence_refs'][:3] == refs
        save(out / 'verification-request.json', request)
        save(out / 'committed-verdict.json', verdict)
        receipt['verification_id'] = request['id']
        return verdict

    try:
        while True:
            health = observe('/health?full=1')
            if health['startup']['state_ready']:
                break
            time.sleep(0.2)
        assert health['build']['binary_commit'] == a.expected_commit
        assert Path(health['paths']['effective_base_path']).resolve() == base
        save(out / 'health.json', health)
        http('/mcp', {'jsonrpc': '2.0', 'id': 0, 'method': 'initialize', 'params': {'protocolVersion': '2025-03-26', 'capabilities': {}, 'clientInfo': {'name': 'verifier-image-fixture', 'version': '1'}}})
        save(out / 'keeper-up.json', mcp('masc_keeper_up', {'name': keeper, 'instructions': 'Execute only the explicitly requested synthetic task submission. Do not infer visual quality.', 'runtime_id': 'image_fixture.producer', 'activation_mode': 'manual', 'sandbox_profile': 'docker', 'network_mode': 'none'}))
        save(out / 'task-created.json', mcp('masc_add_task', {'title': 'Three synthetic rendering attachments', 'priority': 1, 'description': 'Transport three exact PNG artifact images to the independent verifier. Synthetic fixture, no visual quality requirement.'}))
        admission_started = True
        sent = mcp('masc_keeper_msg', {'name': keeper, 'message': 'Claim task-001 and submit all three PNG artifact references for independent byte-delivery verification.'})
        save(out / 'message-ack.json', sent)
        operation_id = sent['operation_id']
        receipt['operation_id'] = operation_id
        save(out / 'receipt.json', receipt)
        while True:
            operation = observe(f'/api/v1/keepers/{keeper}/chat/operations/{operation_id}')
            save(out / 'operation-latest.json', operation)
            status = operation['state']
            if status not in ['Queued', 'Running', 'Succeeded', 'Failed', 'Cancelled']:
                raise ValueError(f'Unknown operation state: {status}')
            if status in ['Succeeded', 'Failed', 'Cancelled']:
                break
            time.sleep(0.5)
        assert status == 'Succeeded', operation
        assert not fixture_errors, fixture_errors
        if a.expected_outcome == 'aggregate_rejection':
            combined = json.dumps(requests['producer'])
            assert f'artifact total size {len(png) * 3} bytes exceeds limit 51200 bytes' in combined
            assert not requests['verifier']
        else:
            while not image_capture_complete.is_set():
                assert server.poll() is None
                time.sleep(0.5)
            assert not fixture_errors, fixture_errors
            expected_uri = 'data:image/png;base64,' + base64.b64encode(png).decode()
            assert delivered_images == [expected_uri] * 3
            save(out / 'verifier-image-receipt.json', {'runtime': 'image_fixture.vision', 'model': 'image-verifier', 'supports_image_input': True, 'received_count': 3, 'sha256': [hashlib.sha256(base64.b64decode(uri.split(',', 1)[1])).hexdigest() for uri in delivered_images]})
            # Wait for primary Task state and its exact committed verdict.
            while True:
                try:
                    task = read_task()
                    verdict = read_committed_verdict()
                except (OSError, json.JSONDecodeError) as error:
                    save(out / f'task-observation-error-{counter:03}.json', {'error': str(error), 'server_pid': server.pid, 'action': 'continue_read_on_same_server'})
                    if server.poll() is not None:
                        raise
                    time.sleep(0.5)
                    continue
                if verdict is not None and verifier_finished.is_set():
                    assert verdict['verdict'] == 'approved', verdict
                    assert task['status'] == 'done', task
                    break
                time.sleep(0.5)
        save(out / 'tasks-readback.json', mcp('masc_tasks', {'include_done': True}))
        read_task()
        safe_to_stop = True
        receipt.update(status='verified', producer_requests=len(requests['producer']), verifier_requests=len(requests['verifier']), delivered_images=len(delivered_images))
        save(out / 'receipt.json', receipt)
    except Exception as error:
        receipt.update(status='failed', error=str(error))
        save(out / 'receipt.json', receipt)
        raise
    finally:
        # An uncertain admission or failed observation is not permission to
        # destroy this server. Keep its provider alive and observe the same
        # operation; never repeat keeper_msg, claim, or done.
        while admission_started and not safe_to_stop and server.poll() is None:
            receipt.update(status='observation_required', server_pid=server.pid,
                           action='preserve_server_and_provider_observe_same_operation')
            save(out / 'receipt.json', receipt)
            try:
                if operation_id is None:
                    operations = http(f'/api/v1/keepers/{keeper}/chat/operations')['operations']
                    if len(operations) != 1:
                        raise ValueError('Uncertain admission: expected exactly one isolated operation')
                    operation_id = operations[0]['operation_id']
                    receipt['operation_id'] = operation_id
                operation = http(f'/api/v1/keepers/{keeper}/chat/operations/{operation_id}')
                state = operation['state']
                if state not in ['Queued', 'Running', 'Succeeded', 'Failed', 'Cancelled']:
                    raise ValueError(f'Unknown operation state: {state}')
                task = read_task()
                verdict = read_committed_verdict() if requests['verifier'] else None
                if (state in ['Succeeded', 'Failed', 'Cancelled']
                    and task['status'] != 'awaiting_verification'
                    and (not requests['verifier'] or (verifier_finished.is_set() and verdict is not None))):
                    safe_to_stop = True
                    save(out / 'terminal-recovery-observation.json',
                         {'operation': operation, 'task': task, 'verdict': verdict})
                    receipt.update(status='failed_after_terminal_observation')
                    save(out / 'receipt.json', receipt)
            except Exception as observation_error:
                save(out / f'cleanup-observation-error-{counter:03}.json',
                     {'error': str(observation_error), 'server_pid': server.pid,
                      'action': 'preserve_same_server_and_provider'})
            if not safe_to_stop:
                time.sleep(0.5)
        if server.poll() is None and (safe_to_stop or not admission_started):
            server.terminate()
            server.wait()
        provider.shutdown()
        log.close()


if __name__ == '__main__':
    main()
