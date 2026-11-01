#!/usr/bin/env python3
"""Exercise an observed Ego connection through the installed MASC MCP tools.

The browser saves into an owned HTTP fixture. Its server-side ledger is the
independent result oracle. This is operator-driven tool-path evidence, not an
autonomous Keeper benchmark or a claim of complete native SDK parity.
"""
import argparse
import base64
from datetime import datetime, timezone
import hashlib
import http.server
import json
from pathlib import Path
import threading
import time
import urllib.request


FIXTURE = '''<!doctype html><meta charset="utf-8"><title>MASC Ego acceptance</title>
<h1>MASC Ego acceptance</h1>
<label>Name<input id="name"></label>
<label>Priority<select id="priority"><option value="normal">Normal</option>
<option value="high">High</option></select></label>
<div id="rich" role="textbox" aria-label="Rich editor" contenteditable="true"
 style="padding:20px;border:1px solid;width:600px"></div>
<button id="save">Save record</button><output id="status">Unsaved</output>
<div id="shadow"></div><iframe title="Cross-origin frame" src="FRAME_URL"></iframe>
<div style="height:1500px"></div><button id="offscreen">Offscreen action</button>
<script>
window.observed={pastes:[],shadowClicks:[],frameClicks:[],frameValues:[],offscreenClicks:[]};
rich.addEventListener('paste',e=>observed.pastes.push({trusted:e.isTrusted,
 html:e.clipboardData.getData('text/html')}));
save.onclick=async e=>{const record={name:document.querySelector('#name').value,
 priority:priority.value,rich:rich.innerHTML,trusted:e.isTrusted,pastes:observed.pastes};
 const r=await fetch('/saved',{method:'POST',body:JSON.stringify(record)});
 document.querySelector('#status').textContent=await r.text();};
const shadow=document.querySelector('#shadow').attachShadow({mode:'open'});
shadow.innerHTML='<button>Shadow action</button>';
shadow.querySelector('button').onclick=e=>observed.shadowClicks.push(e.isTrusted);
offscreen.onclick=e=>observed.offscreenClicks.push(e.isTrusted);
addEventListener('message',e=>{if(e.source===document.querySelector('iframe').contentWindow
 &&e.data?.fixture==='frame'){observed.frameClicks.push(e.data.trusted);
 observed.frameValues.push(e.data.value)}});
</script>'''
FRAME = '''<!doctype html><meta charset="utf-8"><title>Owned frame</title>
<label>Frame editor<input></label><button>Frame action</button>
<script>document.querySelector('button').onclick=e=>parent.postMessage(
{fixture:'frame',trusted:e.isTrusted,value:document.querySelector('input').value},'*');</script>'''


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def require(condition, observation):
    if not condition:
        raise RuntimeError(str(observation))


def decode_rpc(raw):
    text = raw.decode()
    if text.lstrip().startswith('{'):
        return json.loads(text)
    for line in text.splitlines():
        if line.startswith('data: '):
            value = json.loads(line[6:])
            if 'result' in value or 'error' in value:
                return value
    raise RuntimeError('MCP response has no JSON-RPC result')


class Client:
    def __init__(self, endpoint, agent, token_file, output):
        self.endpoint, self.output = endpoint, output
        self.headers = {'Authorization': 'Bearer ' + token_file.read_text().strip(),
                        'X-MASC-Agent': agent, 'Accept': 'application/json, text/event-stream',
                        'Content-Type': 'application/json'}
        self.session = None
        self.sequence = 0
        self.calls = []
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        self.rpc('initialize', {'protocolVersion': '2024-11-05', 'capabilities': {},
                 'clientInfo': {'name': 'masc-ego-acceptance', 'version': '1'}})
        self.rpc('notifications/initialized', {}, notification=True)

    def rpc(self, method, params, notification=False):
        self.sequence += 1
        payload = {'jsonrpc': '2.0', 'method': method, 'params': params}
        if not notification:
            payload['id'] = self.sequence
        headers = dict(self.headers)
        if self.session:
            headers['Mcp-Session-Id'] = self.session
        request = urllib.request.Request(self.endpoint, headers=headers,
                  data=json.dumps(payload).encode(), method='POST')
        with self.opener.open(request, timeout=120) as response:
            self.session = response.headers.get('Mcp-Session-Id', self.session)
            raw = response.read()
        return decode_rpc(raw) if raw else None

    def call(self, name, arguments, expect_error=False):
        started, timestamp = time.monotonic(), utc_now()
        attempt = {'at': timestamp, 'tool': name, 'arguments': arguments, 'state': 'attempted'}
        self.calls.append(attempt)
        (self.output / 'tool-calls.json').write_text(json.dumps(self.calls, indent=2) + '\n')
        try:
            response = self.rpc('tools/call', {'name': name, 'arguments': arguments})
            attempt.update(state='returned', response=response)
        except Exception as error:
            attempt.update(state='response_unconfirmed', transport_error={
                'type': type(error).__name__, 'message': str(error)})
            raise
        finally:
            attempt['seconds'] = time.monotonic() - started
            (self.output / 'tool-calls.json').write_text(json.dumps(self.calls, indent=2) + '\n')
        if 'error' in response:
            raise RuntimeError('MCP rejected tool call: ' + json.dumps(response['error']))
        result = response['result']
        if bool(result.get('isError')) != expect_error:
            raise RuntimeError('Unexpected tool outcome: ' + json.dumps(result)[:4000])
        return result


def structured(result):
    if 'structuredContent' in result:
        return result['structuredContent']
    for item in result.get('content', []):
        if item.get('type') == 'text':
            try:
                return json.loads(item['text'])
            except json.JSONDecodeError:
                pass
    raise RuntimeError('Tool returned no structured result')


def values_named(value, name):
    if isinstance(value, dict):
        for key, child in value.items():
            if key == name:
                yield child
            yield from values_named(child, name)
    elif isinstance(value, list):
        for child in value:
            yield from values_named(child, name)


class Fixture(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        body = self.server.body.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != '/saved':
            self.send_error(404)
            return
        raw = self.rfile.read(int(self.headers['Content-Length']))
        record = json.loads(raw)
        with self.server.gate:
            self.server.records.append(record)
            (self.server.output / 'server-ledger.json').write_text(
                json.dumps(self.server.records, indent=2) + '\n')
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'Saved record')


def serve(body, output):
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    server.daemon_threads = True
    server.body, server.output, server.records = body, output, []
    server.gate = threading.Lock()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--endpoint', required=True, help='MASC HTTP MCP URL')
    parser.add_argument('--agent', required=True, help='Own configured client identity')
    parser.add_argument('--token-file', type=Path, required=True)
    parser.add_argument('--client-id', required=True, help='Observed Ego connection, never guessed')
    parser.add_argument('--out', type=Path, required=True, help='New, unused evidence directory')
    args = parser.parse_args()
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=False)
    frame, frame_thread = serve(FRAME, output)
    frame_url = f'http://127.0.0.1:{frame.server_port}/'
    server, server_thread = serve(FIXTURE.replace('FRAME_URL', frame_url), output)
    url = f'http://localhost:{server.server_port}/'
    route = {'lane': 'live', 'clientId': args.client_id}
    proof = {'started_at': utc_now(), 'completed': False, 'fixture_url': url,
             'scope': 'Installed MASC MCP/host/Addon/Ego tool path with owned fixture; '
                      'operator-driven, not autonomous Keeper or full SDK parity.',
             'driver_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    client = None
    close_attempted = False
    try:
        client = Client(args.endpoint, args.agent, args.token_file, output)
        opened = structured(client.call('masc_browser_act', {**route, 'action': 'open_tab', 'url': url}))
        ids = set(values_named(opened, 'tabId'))
        if len(ids) != 1:
            raise RuntimeError('Open receipt does not identify one owned test tab')
        tab = ids.pop()
        proof['tab_id'] = tab
        target = {**route, 'tabId': tab}
        client.call('masc_browser_read', {**target, 'mode': 'snapshot', 'snapshotScope': 'full_page'})
        steps = [
            {'method': 'fill', 'selector': 'loc=role:textbox[name="Name"]', 'text': 'Ego 한글 😀'},
            {'method': 'selectOption', 'selector': 'loc=role:combobox[name="Priority"]',
             'selectionJson': json.dumps({'value': 'high'})},
            {'method': 'focus', 'selector': 'loc=role:textbox[name="Rich editor"]'},
            {'method': 'keyboard.paste', 'text': 'Native browser record', 'html': '<b>Native browser record</b>'},
            {'method': 'click', 'selector': 'loc=role:button[name="Save record"]'},
            {'method': 'waitForFunction', 'source': 'document.querySelector("#status").textContent === "Saved record"'},
        ]
        client.call('masc_browser_interact', {**target, 'action': 'workflow', 'expectedUrl': url, 'steps': steps})
        with server.gate:
            records = list(server.records)
        require(len(records) == 1, 'Server must receive exactly one save')
        saved = records[0]
        require(saved['name'] == 'Ego 한글 😀' and saved['priority'] == 'high', saved)
        require(saved['trusted'] and len(saved['pastes']) == 1 and saved['pastes'][0]['trusted'], saved)
        require('<b>Native browser record</b>' in saved['rich'], saved)
        proof['saved_record'] = saved
        pointer_steps = [
            {'method': 'click', 'selector': 'loc=role:button[name="Shadow action"]'},
            {'method': 'fill', 'selector': 'loc=role:textbox[name="Frame editor"]', 'text': 'Native frame'},
            {'method': 'click', 'selector': 'loc=role:button[name="Frame action"]'},
            {'method': 'waitForFunction', 'source': 'observed.frameClicks.length === 1'},
            {'method': 'click', 'selector': 'loc=role:button[name="Offscreen action"]'},
            {'method': 'evaluate', 'source': 'observed'},
        ]
        pointer = structured(client.call('masc_browser_interact', {**target, 'action': 'workflow',
                                       'expectedUrl': url, 'steps': pointer_steps}))
        evaluations = [x for x in values_named(pointer, 'receipt')
                       if isinstance(x, dict) and 'frameClicks' in x]
        require(len(evaluations) == 1, 'No native browser state receipt')
        observed = evaluations[0]
        require(observed['frameClicks'] == observed['shadowClicks'] == observed['offscreenClicks'] == [True], observed)
        require(observed['frameValues'] == ['Native frame'], observed)
        proof['pointer_state'] = observed
        # Wrong initial URL must reject this workflow before its click. The
        # server ledger independently proves that it did not submit twice.
        refused = client.call('masc_browser_interact', {**target, 'action': 'workflow',
                    'expectedUrl': url + 'wrong', 'steps': [steps[4]]}, expect_error=True)
        proof['wrong_url_refusal'] = structured(refused)
        failures = list(values_named(refused, 'io.github.jeong-sik/masc.lane.failure'))
        require(any(x.get('effect') == 'proven_pre_effect' and x.get('class') == 'workflow_rejection'
                    for x in failures), 'Wrong-URL result is not a typed pre-effect refusal')
        require('not_started' in values_named(refused, 'effectPhase'), 'Wrong-URL result lacks effect phase')
        with server.gate:
            require(len(server.records) == 1, 'Rejected workflow sent another save')
        screenshot = client.call('masc_browser_read', {**target, 'mode': 'screenshot',
                                 'screenshotOptions': {'fullPage': True}})
        images = []
        for index, item in enumerate(screenshot.get('content', [])):
            if item.get('type') == 'image':
                require(item.get('mimeType') == 'image/png', 'Expected native PNG')
                data = base64.b64decode(item['data'], validate=True)
                require(len(data) >= 24 and data[:8] == b'\x89PNG\r\n\x1a\n', 'Invalid PNG')
                filename = f'masc-browser-{index}.png'
                (output / filename).write_bytes(data)
                images.append({'file': filename, 'sha256': hashlib.sha256(data).hexdigest(),
                               'bytes': len(data), 'width': int.from_bytes(data[16:20], 'big'),
                               'height': int.from_bytes(data[20:24], 'big')})
        require(images, 'No image returned by native screenshot')
        proof['screenshots'] = images
        client.call('masc_browser_read', {**target, 'mode': 'snapshot', 'snapshotScope': 'full_page'})
        close_attempted = True
        client.call('masc_browser_act', {**target, 'action': 'close_tab'})
        with server.gate:
            final_count = len(server.records)
        require(final_count == 1, 'Final server ledger must still contain exactly one save')
        proof.update(completed=True, closed_test_tab=True, tab_state='closed', save_count=final_count)
    except Exception as error:
        proof['failure'] = {'type': type(error).__name__, 'message': str(error)}
        proof['tab_state'] = ('unconfirmed' if close_attempted else
                              'left_open' if 'tab_id' in proof else 'not_observed')
    finally:
        for fixture, thread in [(server, server_thread), (frame, frame_thread)]:
            fixture.shutdown()
            fixture.server_close()
            thread.join()
        proof['finished_at'] = utc_now()
        proof['tool_calls'] = len(client.calls) if client else 0
        (output / 'proof.json').write_text(json.dumps(proof, indent=2, ensure_ascii=False) + '\n')
    print(json.dumps(proof, ensure_ascii=False, indent=2))
    return 0 if proof['completed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
