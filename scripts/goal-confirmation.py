"""Inspect the current Goal proof, then explicitly confirm its exact binding.

Uses the existing token-bound operator credential. Admin credential possession
is operator authority; this does not attest physical human presence.
"""
import argparse
import json
import sys
from pathlib import Path
from urllib.request import Request, build_opener, HTTPRedirectHandler
from urllib.parse import urlencode


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


def read_json(path, body=None):
    request = Request(base_url + path, data=body,
        headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    with opener.open(request) as response:
        raw = response.read().decode()
        headers = response.headers
    if token in raw:
        raise ValueError('Credential echo withheld')
    return json.loads(raw), headers


def read_bound(goal_id, expected):
    query = urlencode({'goal_id': goal_id, 'expected_base_path': expected['base_path'],
        'expected_masc_root': expected['masc_root']})
    result, headers = read_json('/api/v1/goals/confirmation?' + query)
    if headers.get('x-masc-workspace-read') != 'matched-v1':
        raise ValueError('Server did not attest the inspected workspace')
    return result


def nonblank(value):
    return isinstance(value, str) and bool(value.strip())


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
    goal, verdict, _ = proven_evidence(evidence, a.goal_id)
    expected = evidence.get('expected_workspace')
    inspection_operator_id = evidence.get('inspection_operator_id')
    if not isinstance(inspection_operator_id, str) or not inspection_operator_id.strip():
        p.error('Evidence must include its authenticated inspection operator')
    if not isinstance(expected, dict) or set(expected) != {'base_path', 'masc_root'} or not all(
        isinstance(expected[field], str) and expected[field] for field in ('base_path', 'masc_root')
    ):
        p.error('Evidence must include its inspected expected_workspace')
    body = json.dumps({'goal_id': a.goal_id, 'criterion_revision': goal['criterion_revision'],
        'request_id': verdict['request_id'], 'verification_run_id': verdict['verification_run_id'],
        'expected_workspace': expected, 'expected_operator_id': inspection_operator_id}).encode()
    original = (f'Goal {a.goal_id}, criterion {goal["criterion_revision"]}, request {verdict["request_id"]}, '
                f'run {verdict["verification_run_id"]}, base {expected["base_path"]}, masc root {expected["masc_root"]}')
    try:
        acknowledged, _ = read_json(path, body)
        args = (a.goal_id, verdict, verdict['request_id'],
            verdict['verification_run_id'], inspection_operator_id)
        acknowledged_confirmation = completed_binding(acknowledged, *args)
        result = read_bound(a.goal_id, expected)
        readback_confirmation = completed_binding(result, *args)
        if readback_confirmation != acknowledged_confirmation:
            raise ValueError('Confirmation response and readback disagree')
    except KeyboardInterrupt:
        print(f'Confirmation may have been sent; inspect {original} before retrying.', file=sys.stderr)
        raise SystemExit(130)
    except Exception as error:
        raise SystemExit(f'Confirmation result is not verified; inspect {original} before retrying: {error}') from error
else:
    health, _ = read_json('/health?full=1')
    paths = health['paths']
    expected = {'base_path': paths['effective_base_path'], 'masc_root': paths['effective_masc_root']}
    if not all(isinstance(value, str) and value for value in expected.values()):
        p.error('Server did not report its workspace')
    result = read_bound(a.goal_id, expected)
    proven_evidence(result, a.goal_id)
result['expected_workspace'] = expected
print(json.dumps(result, indent=2, ensure_ascii=False))
