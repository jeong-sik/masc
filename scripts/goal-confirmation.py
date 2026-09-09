"""Inspect the current Goal proof, then explicitly confirm its exact binding.

Uses the existing token-bound operator credential. Admin credential possession
is operator authority; this does not attest physical human presence.
"""
import argparse
import json
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.parse import urlencode

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--url', required=True)
p.add_argument('--token-file', type=Path, required=True)
p.add_argument('--goal-id', required=True)
p.add_argument('--confirm-evidence', type=Path, help='Previously inspected GET JSON; confirms that exact proof')
a = p.parse_args()
token = a.token_file.read_text().strip()
if not token:
    p.error('Token file is empty')
body = None
path = '/api/v1/goals/confirmation'
if a.confirm_evidence:
    evidence = json.loads(a.confirm_evidence.read_text())
    goal = evidence['goal']
    completion = evidence['verification']['completion']
    if goal['id'] != a.goal_id or completion['state'] not in ('proof_proven', 'human_confirmed'):
        p.error('Evidence must be the matching proven Goal')
    verdict = completion['verdict']
    body = json.dumps({'goal_id': a.goal_id, 'criterion_revision': goal['criterion_revision'],
        'request_id': verdict['request_id'], 'verification_run_id': verdict['verification_run_id']}).encode()
else:
    path += '?' + urlencode({'goal_id': a.goal_id})
request = Request(a.url.rstrip('/') + path, data=body,
    headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
with urlopen(request) as response:
    raw = response.read().decode()
if token in raw:
    raise ValueError('Credential echo withheld')
print(json.dumps(json.loads(raw), indent=2, ensure_ascii=False))
