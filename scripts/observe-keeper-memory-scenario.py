#!/usr/bin/env python3
"""Sequential live scenario recorder; never treats observation delay as failure."""
import argparse
import json
import pathlib
import time
import urllib.request
import urllib.error

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--base-url', required=True)
    p.add_argument('--token-file', type=pathlib.Path, required=True)
    p.add_argument('--scenario', type=pathlib.Path, required=True)
    p.add_argument('--evidence-dir', type=pathlib.Path, required=True)
    a = p.parse_args()
    spec = json.loads(a.scenario.read_text())
    out = a.evidence_dir
    out.mkdir(parents=True, exist_ok=True)
    headers = {'Authorization': 'Bearer ' + a.token_file.read_text().strip(),
               'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream'}
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    def save(path, value):
        temp = path.with_suffix(path.suffix + '.tmp')
        temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
        temp.replace(path)
    def request(path, data=None):
        req = urllib.request.Request(a.base_url.rstrip('/') + path, headers=headers,
            data=None if data is None else json.dumps(data).encode())
        with opener.open(req, timeout=30) as response:
            sid = response.headers.get('Mcp-Session-Id')
            if sid:
                headers['Mcp-Session-Id'] = sid
            raw = response.read().decode()
        for line in raw.splitlines():
            if line.startswith('data:'):
                return json.loads(line[5:])
        return json.loads(raw) if raw else {}
    def rpc(data):
        return request('/mcp', data)
    rpc({'jsonrpc':'2.0','id':1,'method':'initialize','params':{
        'protocolVersion':'2025-03-26','capabilities':{},
        'clientInfo':{'name':'memory-scenario-recorder','version':'1'}}})
    rpc({'jsonrpc':'2.0','method':'notifications/initialized'})
    prompts = [spec['initial_input']] + spec['remaining_inputs']
    for index, prompt in enumerate(prompts, 1):
        receipt = out / f'turn-{index:02d}-admission.json'
        uncertain = out / f'turn-{index:02d}-admission-started.json'
        if receipt.exists():
            result = json.loads(receipt.read_text())
        else:
            if uncertain.exists():
                raise RuntimeError(f'turn {index}: admission outcome unknown; reconcile before resubmitting')
            save(uncertain, {'input':prompt, 'started_at':time.time()})
            result = rpc({'jsonrpc':'2.0','id':index+1,'method':'tools/call','params':{
                'name':'masc_keeper_msg','arguments':{'name':spec['keeper'],'message':prompt}}})
            save(receipt, result)
        payload = result['result']
        if payload.get('isError'):
            raise RuntimeError(f'turn {index}: admission rejected; see receipt')
        operation_id = payload['structuredContent']['operation_id']
        route = '/api/v1/keepers/' + urllib.parse.quote(spec['keeper'], safe='') + '/chat/'
        previous = None
        while True:
            try:
                operation = request(route + 'operations/' + operation_id)
            except (urllib.error.URLError, TimeoutError) as error:
                save(out / f'turn-{index:02d}-observation-error.json',
                     {'operation_id':operation_id,'error_type':type(error).__name__,'observed_at':time.time()})
                time.sleep(3)
                continue
            save(out / f'turn-{index:02d}-operation.json', operation)
            state = operation['state']
            if state != previous:
                print(index, operation_id, state, flush=True)
                previous = state
            if state == 'Succeeded':
                break
            if state in ('Failed', 'Cancelled'):
                raise RuntimeError(f'turn {index}: terminal {state}; no replacement submitted')
            time.sleep(3)
        events, since = [], None
        while True:
            path = route + 'events?operation_id=' + operation_id + '&limit=2000'
            if since is not None:
                path += '&since_seq=' + str(since)
            page = request(path)
            events.extend(page['events'])
            if not page['has_more']:
                break
            next_since = page['next_since_seq']
            if next_since == since:
                raise RuntimeError('event cursor made no progress')
            since = next_since
        save(out / f'turn-{index:02d}-events.json', events)
        text = ''.join(row['event'].get('delta','') for row in events
                       if row['event'].get('type') == 'text_delta')
        (out / f'turn-{index:02d}-response.txt').write_text(text)
        print('recorded response', index, len(text), 'characters', flush=True)
    print('All operations recorded. Recall and creative quality require independent assessment.', flush=True)

if __name__ == '__main__':
    main()
