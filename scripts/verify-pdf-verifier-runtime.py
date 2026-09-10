"""Actual Kimi completion review of an immutable copied PDF and page render bundle.

The producer submits existing bytes; the verifier response is forwarded unchanged
from the configured Kimi API. No synthetic verdict or manual journal mutation.
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
import tomllib
import shutil
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
    parser.add_argument('--output', type=Path, required=True, help='Fresh output directory visible to the configured Docker engine; default Colima shares HOME, not /private/tmp.')
    parser.add_argument('--port', type=int, default=18946)
    parser.add_argument('--source-bundle', type=Path, required=True)
    parser.add_argument('--live-config-dir', type=Path, required=True)
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
    keeper = 'pdf-proof-producer'
    artifact_root = base / '.masc/playground/docker' / keeper
    artifact_root.mkdir(parents=True)
    source_receipt = json.loads((a.source_bundle / 'source-receipt.json').read_text())
    criteria = json.loads((a.source_bundle / 'criteria.json').read_text())
    assert isinstance(criteria, list) and criteria and all(isinstance(x, str) and x.strip() for x in criteria)
    for record in source_receipt['files']:
        source = a.source_bundle / record['relative']
        raw = source.read_bytes()
        assert len(raw) == record['bytes'] and hashlib.sha256(raw).hexdigest() == record['sha256']
        dest = artifact_root / record['relative']
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(raw)
    shutil.copyfile(a.source_bundle / 'source-receipt.json', artifact_root / 'source-receipt.json')
    image_refs = ['artifact:renders/page1.png', 'artifact:renders/page2.png', 'artifact:renders/page3.png']
    refs = image_refs + ['artifact:memory_proposal_guide.pdf', 'artifact:verify_summary.txt', 'artifact:source-receipt.json']
    expected_images = ['data:image/png;base64,' + base64.b64encode((artifact_root / ref.removeprefix('artifact:')).read_bytes()).decode() for ref in image_refs]
    source_runtime = tomllib.loads((a.live_config_dir / 'runtime.toml').read_text())
    source_overlay = tomllib.loads((a.live_config_dir / 'agent-core-models-overlay.toml').read_text())
    model_config = source_runtime['models']['kimi-for-coding']
    assert model_config['capabilities']['supports-image-input'] is True
    upstream_provider = next(p for p in source_overlay['providers'] if p['id'] == 'kimi_coding')
    upstream_model = model_config['api-name']
    upstream_url = upstream_provider['base_url'].rstrip('/') + upstream_provider['request_path']
    assert upstream_url == 'https://api.kimi.com/coding/v1/chat/completions'
    upstream_key = os.environ[upstream_provider['api_key_env']]
    assert upstream_key
    upstream_opener = build_opener(ProxyHandler({}), NoRedirect)
    token = secrets.token_hex(32)
    requests = {'producer': [], 'verifier': []}
    fixture_errors = []
    delivered_images = []
    image_capture_complete = threading.Event()

    class Provider(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            raw_request = self.rfile.read(int(self.headers['Content-Length']))
            if token.encode() in raw_request or upstream_key.encode() in raw_request:
                fixture_errors.append('credential echo withheld')
                self.send_error(400)
                return
            body = json.loads(raw_request)
            lane = 'producer' if body['model'] == 'image-producer' else 'verifier'
            index = len(requests[lane])
            requests[lane].append(body)
            save(out / f'{lane}-request-{index:03}.json', body)
            if lane == 'verifier':
                assert body['model'] == upstream_model
                images = []
                for message in body['messages']:
                    content = message.get('content')
                    if isinstance(content, list):
                        images.extend(part['image_url']['url'] for part in content if part.get('type') == 'image_url')
                if index == 0:
                    delivered_images.extend(images)
                    if images != expected_images:
                        fixture_errors.append('Actual verifier image bytes differ from source bundle')
                    image_capture_complete.set()
                (out / f'verifier-wire-{index:03}.json').write_bytes(raw_request)
                upstream_request = Request(upstream_url, data=raw_request,
                    headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + upstream_key,
                             'Accept': 'text/event-stream, application/json', 'Accept-Encoding': 'identity'})
                if self.headers.get('User-Agent'):
                    upstream_request.add_header('User-Agent', self.headers['User-Agent'])
                try:
                    upstream_response = upstream_opener.open(upstream_request)
                except HTTPError as error:
                    upstream_response = error
                with upstream_response:
                    response_raw = upstream_response.read()
                    response_status = upstream_response.status
                    response_type = upstream_response.headers.get('Content-Type', 'application/json')
                if upstream_key.encode() in response_raw or token.encode() in response_raw:
                    fixture_errors.append('Credential echo withheld from actual verifier response')
                    self.send_error(502, 'Credential echo withheld')
                    return
                save(out / f'verifier-response-{index:03}.json',
                    {'upstream': upstream_url, 'request_sha256': hashlib.sha256(raw_request).hexdigest(),
                     'status': response_status, 'content_type': response_type, 'raw': response_raw.decode()})
                self.send_response(response_status)
                self.send_header('Content-Type', response_type)
                self.send_header('Content-Length', str(len(response_raw)))
                self.end_headers()
                self.wfile.write(response_raw)
                return
            names = [tool['function']['name'] for tool in body.get('tools', [])]
            name = None
            arguments = None
            if lane == 'producer':
                if index == 0:
                    name, arguments = 'keeper_task_claim', {'task_id': 'task-001'}
                elif index == 1:
                    name, arguments = 'keeper_task_done', {'task_id': 'task-001', 'result': 'Submitted copied PDF, summary, source hashes and three complete page renderings for independent review against the original criteria. No semantic verdict is supplied.', 'evidence_refs': refs}
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
            save(out / f'{lane}-response-{index:03}.json',
                 {'status': 200, 'content_type': content_type, 'raw': raw.decode()})
            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

    provider = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=provider.serve_forever, daemon=True).start()
    fixtures = Path(__file__).parent / 'fixtures/release-evidence'
    runtime = (fixtures / 'runtime.toml').read_text()
    runtime += '\n[runtime.exact_output_lanes.verifier_exact]\nslots = ["kimi_coding.kimi-for-coding"]\n'
    runtime += f'\n[providers.image_fixture]\nprotocol = "openai-compatible-http"\nendpoint = "http://127.0.0.1:{provider.server_port}/v1"\n'
    runtime += f'\n[providers.kimi_coding]\nprotocol = "openai-compatible-http"\nendpoint = "http://127.0.0.1:{provider.server_port}/v1"\n'
    runtime += '\n[models.producer]\napi-name = "image-producer"\nmax-context = 131072\ntools-support = true\nstreaming = true\n[image_fixture.producer]\nmax-request-body-bytes = 2097152\n'
    runtime += '\n[models.kimi-for-coding]\n'
    for key, value in model_config.items():
        if key != 'capabilities':
            runtime += key + ' = ' + json.dumps(value) + '\n'
    runtime += '\n[models.kimi-for-coding.capabilities]\n'
    for key, value in model_config['capabilities'].items():
        runtime += key + ' = ' + json.dumps(value) + '\n'
    runtime += '\n[kimi_coding.kimi-for-coding]\n'
    overlay = (fixtures / 'agent-core-models-overlay.toml').read_text()
    for provider_id, cap_base in [('image_fixture', 'openai_chat'), ('kimi_coding', upstream_provider['capabilities_base'])]:
        overlay += f'\n[[providers]]\nid = "{provider_id}"\nkind = "openai_compat"\nbase_url = "http://127.0.0.1:{provider.server_port}/v1"\nrequest_path = "/chat/completions"\napi_key_env = ""\ncapabilities_base = "{cap_base}"\n'
    overlay += '\n[[models]]\nid_prefix = "image-producer"\nprovider_name = "image_fixture"\nbase = "openai_chat"\nmax_context_tokens = 131072\nmax_output_tokens = 4096\nsupports_tools = true\nsupports_tool_choice = true\nsupports_native_streaming = true\n[[targets]]\nid = "image_fixture.producer"\nprovider_ref = "image_fixture"\nmodel_id = "image-producer"\n'
    selected_model = next(m for m in source_overlay['models'] if m['id_prefix'] == upstream_model and m.get('provider_name') == 'kimi_coding')
    overlay += '\n[[models]]\n'
    for key, value in selected_model.items():
        overlay += key + ' = ' + json.dumps(value) + '\n'
    overlay += f'\n[[targets]]\nid = "kimi_coding.kimi-for-coding"\nprovider_ref = "kimi_coding"\nmodel_id = "{upstream_model}"\n'
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
    receipt = {'scope': 'actual Kimi PDF semantic review; synthetic producer submission only, unmodified real verifier responses', 'status': 'started',
               'harness_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), 'expected_commit': a.expected_commit,
               'base_path': str(base), 'port': a.port, 'server_pid': server.pid, 'manifest': manifest,
               'source_receipt': source_receipt, 'criteria': criteria, 'upstream': upstream_url,
               'verifier_runtime': 'kimi_coding.kimi-for-coding', 'verifier_model': upstream_model}
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
        assert verdict['evaluator_runtime'] == 'kimi_coding.kimi-for-coding'
        actual_artifacts = [ref for ref in request['output']['evidence_refs'] if ref.startswith('artifact:')]
        assert sorted(actual_artifacts) == sorted(refs), 'Committed artifact references differ from submitted bundle'
        save(out / 'verification-request.json', request)
        save(out / 'committed-verdict.json', verdict)
        receipt['verification_id'] = request['id']
        return verdict

    def read_verifier_run():
        page = http('/api/v1/dashboard/verification-runs')
        runs = [run for run in page['runs'] if run['verification_id'] == receipt['verification_id']]
        if len(runs) != 1:
            raise ValueError('Expected exact verifier run in the authoritative registry')
        run = runs[0]
        if run['status'] not in ['running', 'approved', 'rejected', 'infrastructure_unavailable', 'not_reviewed', 'commit_failed', 'raised', 'review_cancelled', 'operator_routed']:
            raise ValueError('Unknown verifier run status')
        save(out / 'verifier-run-readback.json', run)
        return run

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
        save(out / 'keeper-up.json', mcp('masc_keeper_up', {'name': keeper, 'instructions': 'Only submit the copied PDF artifact bundle for independent verification. Do not infer or supply a visual verdict.', 'runtime_id': 'image_fixture.producer', 'activation_mode': 'manual', 'sandbox_profile': 'docker', 'network_mode': 'none'}))
        save(out / 'task-created.json', mcp('masc_add_task', {'title': 'Independent review of current three-page memory proposal PDF', 'priority': 1, 'description': 'Inspect the copied PDF, its current renderings and measured summary against the original completion criteria. Do not assume acceptance from the submitter.', 'contract': {'strict': True, 'completion_contract': criteria, 'required_evidence': refs}}))
        admission_started = True
        sent = mcp('masc_keeper_msg', {'name': keeper, 'message': 'Claim task-001 and submit the existing copied PDF, summary, source hashes and page renderings for independent verification.'})
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
        while not image_capture_complete.is_set():
            assert server.poll() is None
            time.sleep(0.5)
        assert not fixture_errors, fixture_errors
        assert delivered_images == expected_images
        save(out / 'verifier-image-receipt.json',
             {'runtime': 'kimi_coding.kimi-for-coding', 'model': upstream_model, 'received_count': len(delivered_images),
              'sha256': [hashlib.sha256(base64.b64decode(uri.split(',', 1)[1])).hexdigest() for uri in delivered_images]})
        while True:
            try:
                task = read_task()
                verdict = read_committed_verdict()
                run = read_verifier_run() if verdict is not None else None
            except (OSError, json.JSONDecodeError, URLError, ConnectionError) as error:
                save(out / f'proof-observation-error-{time.time_ns()}.json', {'error': str(error), 'server_pid': server.pid, 'action': 'continue_same_handle'})
                if server.poll() is not None:
                    raise
                time.sleep(0.5)
                continue
            if verdict is not None and run is not None and run['status'] != 'running':
                assert verdict['verdict'] in ['approved', 'rejected']
                assert task['status'] == ('done' if verdict['verdict'] == 'approved' else 'in_progress')
                assert run['status'] == verdict['verdict']
                receipt['semantic_verdict'] = verdict['verdict']
                receipt['verifier_reason'] = run['reason']
                break
            time.sleep(0.5)
        save(out / 'tasks-readback.json', mcp('masc_tasks', {'include_done': True}))
        read_task()
        safe_to_stop = True
        receipt.update(status='observed', producer_requests=len(requests['producer']), verifier_requests=len(requests['verifier']), delivered_images=len(delivered_images))
        save(out / 'receipt.json', receipt)
    except Exception as error:
        receipt.update(status='failed', error=f'{type(error).__name__}: {error}')
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
                    and (not requests['verifier'] or (verdict is not None and read_verifier_run()['status'] != 'running'))):
                    safe_to_stop = True
                    save(out / 'terminal-recovery-observation.json',
                         {'operation': operation, 'task': task, 'verdict': verdict})
                    receipt.update(status='failed_after_terminal_observation')
                    save(out / 'receipt.json', receipt)
            except Exception as observation_error:
                save(out / f'cleanup-observation-error-{counter:03}.json',
                     {'error': f'{type(observation_error).__name__}: {observation_error}', 'server_pid': server.pid,
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
