"""Verify an explicitly supplied proposal against a running MASC HTTP store.

This writes the supplied proposal twice to check content-addressed idempotence.
It does not invoke a model, promote memory, or claim Keeper reuse.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import urllib.error
import urllib.parse
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-url', required=True)
    parser.add_argument('--token-file', type=Path, required=True)
    parser.add_argument('--proposal', type=Path, required=True)
    parser.add_argument('--expected-commit', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    origin = urllib.parse.urlsplit(args.base_url)
    if (origin.scheme not in ('http', 'https') or not origin.hostname
            or origin.username or origin.password or origin.query or origin.fragment
            or origin.path not in ('', '/')):
        parser.error('base-url must be an HTTP(S) origin without credentials')
    token = args.token_file.read_text().strip()
    if not token or any(c.isspace() for c in token):
        parser.error('Token file must contain one nonblank bearer credential')
    proposal = json.loads(args.proposal.read_text())
    args.output.mkdir(parents=True, exist_ok=False, mode=0o700)
    opener = urllib.request.build_opener(NoRedirect(), urllib.request.ProxyHandler({}))
    receipt = {'started_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
               'status': 'running', 'checks': [], 'write_attempted': False,
               'semantic_verification': 'not_performed', 'keeper_reuse': 'not_measured'}

    def save(name, value):
        path = args.output / name
        temporary = path.with_suffix(path.suffix + '.tmp')
        with temporary.open('w') as output:
            output.write(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
            output.flush()
            os.fsync(output.fileno())
        temporary.replace(path)

    def request(path, name, body=None):
        headers = {'Authorization': 'Bearer ' + token}
        data = None if body is None else canonical(body).encode()
        if data is not None:
            headers['Content-Type'] = 'application/json'
            receipt['write_attempted'] = True
            receipt['write_intent'] = {'request': name, 'path': path,
                'body_sha256': hashlib.sha256(data).hexdigest(), 'outcome': 'not_observed'}
            save('receipt.json', receipt)
        req = urllib.request.Request(args.base_url.rstrip('/') + path, data=data, headers=headers)
        try:
            response = opener.open(req)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            raw = response.read()
            if token.encode() in raw:
                save(name + '.http.json', {'status': response.status, 'body': 'withheld_credential_echo'})
                raise ValueError('Response echoed credential bytes; body withheld')
            (args.output / (name + '.response.raw')).write_bytes(raw)
            save(name + '.http.json', {'status': response.status, 'path': path})
            if not 200 <= response.status < 300:
                raise ValueError(f'{name} returned HTTP {response.status}')
            value = json.loads(raw)
            save(name + '.json', value)
            if body is not None:
                receipt['write_intent']['outcome'] = 'response_recorded'
                save('receipt.json', receipt)
            return value

    try:
        health = request('/health?full=1', 'health')
        receipt['build'] = health['build']
        receipt['paths'] = {key: health['paths'][key]
                            for key in ('effective_base_path', 'effective_masc_root')}
        if health['build']['binary_commit'] != args.expected_commit:
            raise ValueError('observed binary commit differs from expected source')
        receipt['checks'].append('expected_binary_commit')
        receipt['proposal_bytes_sha256'] = hashlib.sha256(args.proposal.read_bytes()).hexdigest()
        path = '/api/v1/dashboard/workspace-memory-proposals'
        saved = request(path, 'post-response', proposal)
        proposal_id = saved['id']
        if not isinstance(proposal_id, str) or len(proposal_id) != 64 or any(c not in '0123456789abcdef' for c in proposal_id):
            raise ValueError('invalid proposal id')
        readback = request(path + '?id=' + proposal_id, 'readback')
        if readback['id'] != proposal_id or canonical(readback['proposal']) != canonical(proposal):
            raise ValueError('independent readback differs from submitted proposal')
        receipt['checks'].append('exact_independent_readback')
        repeated = request(path, 'repeated-post-response', proposal)
        if repeated['id'] != proposal_id:
            raise ValueError('repeated publication changed id')
        inventory = request(path, 'inventory')
        matches = [row for row in inventory['proposals'] if row['id'] == proposal_id]
        if len(matches) != 1 or canonical(matches[0]['proposal']) != canonical(proposal):
            raise ValueError('inventory does not contain exactly one matching proposal')
        receipt['checks'].append('idempotent_publication_and_inventory')
        receipt.update(status='passed', proposal_id=proposal_id)
    except Exception as error:
        detail = str(error).replace(token, '[credential]')
        receipt.update(status='failed', error=detail)
        raise SystemExit(detail) from None
    finally:
        receipt['finished_at'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        save('receipt.json', receipt)


if __name__ == '__main__':
    main()
