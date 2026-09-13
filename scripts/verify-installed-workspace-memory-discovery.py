"""Read-only installed publication, HTTP readback and Keeper preview check.

This does not call a model or prove actual Keeper dispatch, reading or adoption.
An observation failure leaves a failed receipt; it never restarts a process.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import urllib.error
import urllib.parse
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_regular(path):
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), 'rb') as stream:
        require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode), 'Expected regular evidence file')
        return stream.read()


def discovery_fragment(catalog, descriptor):
    rows = [row for row in catalog['prompts']
            if row['key'] == 'keeper.context.workspace_memory.available']
    require(len(rows) == 1, 'Expected one resolved discovery prompt')
    row = rows[0]
    template = row['effective']
    require(isinstance(template, str) and template.strip(), 'Empty discovery prompt')
    variables = {'proposal_id': descriptor['proposal_id'], 'context_sha256': descriptor['context_sha256']}
    pattern = re.compile(r'\{\{([^}]+)\}\}')
    require({match.group(1).strip() for match in pattern.finditer(template)} == set(variables),
            'Discovery prompt has missing or unsupported variable bindings')
    # This is the explicit placeholder grammar used by Prompt_registry.render_template.
    rendered = pattern.sub(lambda match: variables[match.group(1).strip()], template)
    return row, rendered


def validate_preview(value, keeper, descriptor, expected_fragment):
    require(value['name'] == keeper, 'Keeper preview identity mismatch')
    prompt = value['prompt']
    assembled = prompt['assembled_system_prompt']
    proposal_id = descriptor['proposal_id']
    require(assembled.count(expected_fragment) == 1,
            'Preview does not contain exactly one complete resolved discovery fragment')
    for marker in (proposal_id, descriptor['context_sha256'], 'keeper_workspace_memory_read',
                   'model_proposed', 'not_performed', 'not_checked_against_current_memory'):
        require(marker in assembled, 'Preview missing publication identity or uncertainty marker')
    require(proposal_id not in prompt['unified_user_message_preview'],
            'Publication discovery leaked into the persisted-message preview')
    require(proposal_id not in prompt['effective_system_prompt'],
            'Publication discovery leaked into the stable system prompt')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-url', required=True)
    parser.add_argument('--base-path', type=Path, required=True)
    parser.add_argument('--token-file', type=Path, required=True)
    parser.add_argument('--expected-commit', required=True)
    parser.add_argument('--expected-binary-sha256', required=True)
    parser.add_argument('--keeper', action='append', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    origin = urllib.parse.urlsplit(args.base_url)
    require(origin.scheme in ('http', 'https') and origin.hostname and not
            (origin.username or origin.password or origin.query or origin.fragment)
            and origin.path in ('', '/'), 'base-url must be an HTTP(S) origin')
    token = read_regular(args.token_file).decode().strip()
    require(token and not any(c.isspace() for c in token), 'Invalid bearer credential file')
    require(len(set(args.keeper)) == len(args.keeper), 'Keeper names must be distinct')
    base = args.base_path.resolve(strict=True)
    args.output.mkdir(parents=True, exist_ok=False, mode=0o700)
    receipt = {'status': 'running', 'started_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
               'scope': 'installed publication and HTTP Keeper preview only', 'runtime_mutation': False,
               'semantic_verification': 'not_performed', 'actual_keeper_dispatch': 'not_measured',
               'keeper_adoption': 'not_measured', 'checks': []}
    opener = urllib.request.build_opener(NoRedirect(), urllib.request.ProxyHandler({}))

    def save(name, raw):
        require(token.encode() not in raw, 'Credential echo withheld from evidence')
        with os.fdopen(os.open(args.output / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as f:
            f.write(raw)

    def get(path, name):
        request = urllib.request.Request(args.base_url.rstrip('/') + path,
                                         headers={'Authorization': 'Bearer ' + token})
        try:
            response = opener.open(request, timeout=30)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            raw = response.read()
            save(name + '.response.raw', raw)
            save(name + '.http.json', json.dumps({'status': response.status, 'path': path}).encode())
            require(response.status == 200, name + ' did not return HTTP 200')
            return json.loads(raw)

    try:
        health = get('/health?full=1', 'health-before')
        build = health['build']
        require(health['status'] == 'ok', 'Installed health is not ok')
        require(build['binary_commit'] == args.expected_commit, 'Installed source mismatch')
        require(build['executable_sha256'] == args.expected_binary_sha256, 'Installed binary mismatch')
        require(isinstance(build['runtime_instance_id'], str) and build['runtime_instance_id'].strip(),
                'Runtime instance identity is missing')
        require(Path(health['paths']['effective_base_path']).resolve() == base, 'Runtime base mismatch')
        runtime_root = base / '.masc'
        require(Path(health['paths']['effective_masc_root']).resolve() == runtime_root.resolve(),
                'Runtime memory root mismatch')
        receipt['build'] = build
        receipt['checks'].append('expected_runtime_identity')
        publication_path = runtime_root / 'workspace-memory' / 'publication.json'
        publication_bytes = read_regular(publication_path)
        save('publication.json', publication_bytes)
        descriptor = json.loads(publication_bytes)
        require(set(descriptor) == {'schema', 'proposal_id', 'context_sha256'} and
                descriptor['schema'] == 'workspace.memory.publication.v1', 'Publication schema mismatch')
        proposal_id = descriptor['proposal_id']
        require(isinstance(proposal_id, str) and len(proposal_id) == 64 and
                all(c in '0123456789abcdef' for c in proposal_id), 'Invalid publication id')
        proposal_path = runtime_root / 'workspace-memory' / 'proposals' / (proposal_id + '.json')
        proposal_bytes = read_regular(proposal_path)
        # Native Store.submit writes exactly the canonical bytes used by Store.id.
        require(hashlib.sha256(proposal_bytes).hexdigest() == proposal_id,
                'Native saved proposal bytes do not match publication id')
        save('proposal.json', proposal_bytes)
        proposal = json.loads(proposal_bytes)
        require(proposal['context_sha256'] == descriptor['context_sha256'] and
                proposal['status'] == 'model_proposed', 'Proposal binding or status mismatch')
        readback = get('/api/v1/dashboard/workspace-memory-proposals?id=' + proposal_id, 'proposal-http')
        require(readback['id'] == proposal_id and readback['proposal'] == proposal and
                readback['semantic_verification'] == 'not_performed', 'HTTP proposal readback mismatch')
        receipt['checks'].append('exact_native_proposal_and_http_readback')
        prompt_row, fragment = discovery_fragment(get('/api/v1/prompts', 'prompts-before'), descriptor)
        save('resolved-discovery-fragment.txt', fragment.encode())
        save('resolved-discovery-prompt.json', json.dumps(prompt_row, ensure_ascii=False).encode())
        for index, keeper in enumerate(args.keeper):
            value = get('/api/v1/keepers/' + urllib.parse.quote(keeper, safe='') + '/config',
                        'keeper-preview-' + str(index))
            validate_preview(value, keeper, descriptor, fragment)
        receipt['checks'].append('keeper_previews_share_exact_discovery_without_persisted_message_injection')
        after = get('/health?full=1', 'health-after')
        require(after['status'] == 'ok', 'Installed health degraded during observation')
        require(Path(after['paths']['effective_base_path']).resolve() == base and
                Path(after['paths']['effective_masc_root']).resolve() == runtime_root.resolve(),
                'Runtime base or memory root changed during observation')
        for key in ('binary_commit', 'executable_sha256', 'runtime_instance_id'):
            require(after['build'][key] == build[key], 'Runtime identity changed during observation')
        after_row, after_fragment = discovery_fragment(get('/api/v1/prompts', 'prompts-after'), descriptor)
        require(after_row == prompt_row and after_fragment == fragment,
                'Resolved discovery prompt changed during observation')
        require(read_regular(publication_path) == publication_bytes and
                read_regular(proposal_path) == proposal_bytes, 'Publication changed during observation')
        receipt.update(status='passed', proposal_id=proposal_id, keepers=args.keeper)
        receipt['checks'].append('same_instance_and_publication_at_observation_boundaries')
    except Exception as error:
        receipt.update(status='failed', error=str(error).replace(token, '[credential]'))
    finally:
        receipt['finished_at'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        save('receipt.json', (json.dumps(receipt, ensure_ascii=False, indent=2) + '\n').encode())
        hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in args.output.iterdir()}
        save('sha256.json', (json.dumps(hashes, indent=2) + '\n').encode())
    print(json.dumps({'status': receipt['status'], 'output': str(args.output), 'checks': receipt['checks']}))
    return 0 if receipt['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
