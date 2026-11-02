"""Inspect the current Goal proof, then explicitly confirm its exact binding.

Uses the existing token-bound operator credential. Admin credential possession
is operator authority; this does not attest physical human presence.
"""
import argparse
import json
import re
import sys
import uuid
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, build_opener, HTTPRedirectHandler
from urllib.parse import urlencode
from goal_confirmation_deadline import request_deadline


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--url', required=True)
p.add_argument('--token-file', type=Path, required=True)
p.add_argument('--goal-id', required=True)
p.add_argument('--confirm-evidence', type=Path, help='Previously inspected GET JSON; confirms that exact proof')
a = p.parse_args()
token = a.token_file.read_text().strip()
if not token:
    p.error('Token file is empty')

opener = build_opener(NoRedirect)
base_url = a.url.rstrip('/')


def contains_credential(value):
    if isinstance(value, str):
        # Evidence may itself contain JSON-encoded text, including repeatedly
        # escaped unicode characters. Do not write a recoverable token to disk.
        previous = None
        while value != previous:
            if token in value:
                return True
            previous = value
            value = re.sub(r'\\+u([0-9a-fA-F]{4})', lambda match: chr(int(match.group(1), 16)), value)
        return False
    if isinstance(value, dict):
        return any(contains_credential(key) or contains_credential(item) for key, item in value.items())
    if isinstance(value, list):
        return any(contains_credential(item) for item in value)
    return False


def terminal_safe(value):
    return ''.join(char if char.isprintable() else char.encode('unicode_escape').decode('ascii')
                   for char in value)


def read_json(path, body=None, validate_headers=None):
    request = Request(base_url + path, data=body,
        headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    with request_deadline():
        try:
            with opener.open(request) as response:
                headers = response.headers
                if validate_headers is not None:
                    validate_headers(headers)
                raw = response.read().decode()
        except HTTPError as error:
            try:
                raw = error.read().decode()
                payload = json.loads(raw)
            except (UnicodeDecodeError, json.JSONDecodeError, OSError):
                raise ValueError(f'Server returned HTTP {error.code}; error detail unavailable') from None
            detail = payload.get('error') if isinstance(payload, dict) else None
            if contains_credential(raw) or contains_credential(payload):
                raise ValueError('Credential echo withheld') from None
            if not isinstance(detail, str) or not detail.strip():
                raise ValueError(f'Server returned HTTP {error.code}; error detail unavailable') from None
            raise ValueError(f'Server returned HTTP {error.code}: {terminal_safe(detail)}') from None
    if contains_credential(raw):
        raise ValueError('Credential echo withheld')
    payload = json.loads(raw)
    if contains_credential(payload):
        raise ValueError('Credential echo withheld')
    return payload, headers


def validate_bound_headers(headers):
    if headers.get_all('x-masc-workspace-read', []) != ['matched-v1']:
        raise ValueError('Server did not attest the inspected workspace')
    instances = headers.get_all('x-masc-runtime-instance-id', [])
    if len(instances) != 1 or not valid_instance(instances[0]):
        raise ValueError('Server did not attest a unique runtime instance')
    if contains_credential(instances[0]):
        raise ValueError('Credential echo withheld')
    return instances[0]


def read_bound(goal_id, expected, expected_instance=None):
    query = urlencode({'goal_id': goal_id, 'expected_base_path': expected['base_path'],
        'expected_masc_root': expected['masc_root']})
    def validate(headers):
        instance = validate_bound_headers(headers)
        if expected_instance is not None and instance != expected_instance:
            raise ValueError('Confirmation readback came from a different server instance')
        return instance
    result, headers = read_json('/api/v1/goals/confirmation?' + query, validate_headers=validate)
    return result, validate(headers)


def nonblank(value):
    return isinstance(value, str) and bool(value.strip())


def valid_instance(value):
    if not isinstance(value, str):
        return False
    try:
        return str(uuid.UUID(value)) == value
    except ValueError:
        return False


def proven_evidence(result, goal_id):
    goal = result['goal']
    verification = result['verification']
    completion = verification['completion']
    verdict = completion['verdict']
    criterion = verdict['criterion']
    authority = verdict['authority']
    if (not nonblank(result.get('inspection_operator_id')) or goal['id'] != goal_id
        or verification['goal_id'] != goal_id or completion['state'] not in ('proof_proven', 'human_confirmed')
        or not nonblank(criterion.get('revision')) or criterion['revision'] != goal['criterion_revision']
        or not isinstance(criterion.get('title'), str) or criterion['title'] != goal['title']
        or criterion.get('metric') != goal['metric'] or criterion.get('target_value') != goal['target_value']
        or not (criterion['metric'] is None or isinstance(criterion['metric'], str))
        or not (criterion['target_value'] is None or isinstance(criterion['target_value'], str))
        or verdict.get('outcome') != 'proven' or verdict.get('reason', 'missing') is not None
        or not nonblank(verdict.get('request_id')) or not nonblank(verdict.get('verification_run_id'))
        or not nonblank(verdict.get('evidence')) or not nonblank(verdict.get('recorded_at'))
        or not isinstance(authority, dict) or authority.get('kind') not in ('system_llm_agent', 'human_operator')
        or not nonblank(authority.get('actor'))
        or (completion['state'] == 'human_confirmed'
            and (not nonblank(completion.get('operator_id')) or not nonblank(completion.get('confirmed_at'))))):
        raise ValueError('Evidence is not a current proven Goal')
    return goal, verdict, completion


def completed_binding(result, goal_id, inspected_verdict, request_id, run_id, operator_id):
    goal, verdict, completion = proven_evidence(result, goal_id)
    if (result['inspection_operator_id'] != operator_id or goal['phase'] != 'completed'
        or verdict != inspected_verdict or completion['state'] != 'human_confirmed'
        or verdict['request_id'] != request_id or verdict['verification_run_id'] != run_id):
        raise ValueError('Confirmation response does not prove the requested completion')
    return completion


path = '/api/v1/goals/confirmation'
if a.confirm_evidence:
    evidence = json.loads(a.confirm_evidence.read_text())
    if contains_credential(evidence):
        p.error('Credential echo withheld')
    goal, verdict, _ = proven_evidence(evidence, a.goal_id)
    expected = evidence.get('expected_workspace')
    inspection_operator_id = evidence.get('inspection_operator_id')
    inspected_instance = evidence.get('expected_runtime_instance_id')
    if not isinstance(inspection_operator_id, str) or not inspection_operator_id.strip():
        p.error('Evidence must include its authenticated inspection operator')
    if not valid_instance(inspected_instance):
        p.error('Evidence must include the inspected server instance; inspect the proof again')
    if not isinstance(expected, dict) or set(expected) != {'base_path', 'masc_root'} or not all(
        isinstance(expected[field], str) and expected[field] for field in ('base_path', 'masc_root')
    ):
        p.error('Evidence must include its inspected expected_workspace')
    body = json.dumps({'goal_id': a.goal_id, 'criterion_revision': goal['criterion_revision'],
        'request_id': verdict['request_id'], 'verification_run_id': verdict['verification_run_id'],
        'expected_workspace': expected, 'expected_operator_id': inspection_operator_id,
        'expected_runtime_instance_id': inspected_instance}).encode()
    original = terminal_safe(f'Goal {a.goal_id}, criterion {goal["criterion_revision"]}, request {verdict["request_id"]}, '
        f'run {verdict["verification_run_id"]}, base {expected["base_path"]}, masc root {expected["masc_root"]}')
    try:
        acknowledged, _ = read_json(path, body)
        args = (a.goal_id, verdict, verdict['request_id'],
            verdict['verification_run_id'], inspection_operator_id)
        acknowledged_confirmation = completed_binding(acknowledged, *args)
        result, _ = read_bound(a.goal_id, expected, expected_instance=inspected_instance)
        readback_confirmation = completed_binding(result, *args)
        if readback_confirmation != acknowledged_confirmation:
            raise ValueError('Confirmation response and readback disagree')
    except KeyboardInterrupt:
        print(f'Confirmation may have been sent; inspect {original} before retrying.', file=sys.stderr)
        raise SystemExit(130)
    except Exception as error:
        raise SystemExit(f'Confirmation result is not verified; inspect {original} before retrying: {error}') from error
else:
    try:
        health, _ = read_json('/health?full=1')
        paths = health['paths']
        expected = {'base_path': paths['effective_base_path'], 'masc_root': paths['effective_masc_root']}
        if not all(isinstance(value, str) and value for value in expected.values()):
            p.error('Server did not report its workspace')
        result, inspected_instance = read_bound(a.goal_id, expected)
        proven_evidence(result, a.goal_id)
    except TimeoutError as error:
        raise SystemExit(f'Inspection timed out; no confirmation was sent: {error}') from error
result['expected_workspace'] = expected
result['expected_runtime_instance_id'] = inspected_instance
if contains_credential(result):
    raise SystemExit('Credential echo withheld')
print(json.dumps(result, indent=2, ensure_ascii=False))
