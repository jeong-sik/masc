#!/usr/bin/env python3
"""Verify retained semantic requests, raw responses and scores offline; makes no calls."""
import argparse
import base64
import collections
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate JSON key: ' + key)
        result[key] = value
    return result


def parse(raw):
    return json.loads(raw, object_pairs_hook=unique_object)


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def require(condition, detail):
    if not condition:
        raise ValueError(detail)


def choice_decision(answer, options):
    require(isinstance(answer, dict) and answer.get('type') == 'choice', 'expected choice')
    probabilities = answer.get('probabilities')
    require(isinstance(probabilities, dict) and set(probabilities) == set(options), 'choice options differ')
    def unit(value):
        return type(value) in (int, float) and math.isfinite(value) and 0 <= value <= 1
    require(unit(answer.get('confidence')) and all(unit(v) for v in probabilities.values()), 'invalid probability')
    total = 0.0
    for value in probabilities.values():
        total += value
    require(abs(total - 1.0) <= sys.float_info.epsilon * len(probabilities), 'probabilities do not sum to one')
    decision = answer.get('choice')
    require(isinstance(decision, str) and decision in probabilities, 'unknown choice')
    require(all(probabilities[decision] >= v for v in probabilities.values()), 'choice is not maximal')
    return decision


def expected_request(policy, case, cohort, arm):
    state = {'source_memory': case['source_memory'], 'proposed_memory': case['proposed_memory']}
    if arm == 'historical_instruction_only':
        state['new_observations'] = []
    elif arm == 'current_with_evidence':
        state['new_observations'] = case['new_observations'] if cohort == 'heldout-new' else [
            {'kind': 'conversation', 'batch_turn_ref': f"synthetic-{cohort}-{case['id']}#1",
             'local_position': i,
             'text': f"[local_position={i} role=user speaker=unknown] {obs['text']}"}
            for i, obs in enumerate(case['new_observations'])]
    elif arm != 'current_pair_only':
        raise ValueError('unknown arm')
    return {'model': policy['model'], 'state': state, 'questions': policy['arms'][arm]}


def verify(root, repo=None):
    policy_bytes = (root / 'policy.json').read_bytes()
    policy = parse(policy_bytes)
    summary = parse((root / 'summary.json').read_bytes())
    require(sha(policy_bytes) == summary['policy_sha256'], 'policy hash mismatch')
    require(policy['source_head'] == summary['source_head'], 'source head mismatch')
    require(policy['source_sha256'] == summary['source_sha256'], 'source digest mismatch')
    if repo is not None:
        source = subprocess.check_output(['git', '-C', repo, 'show', policy['source_head'] + ':' + policy['source_path']])
        require(sha(source) == policy['source_sha256'], 'git source content mismatch')
    total_calls = total_input = 0
    for cohort in ['development', 'heldout-new']:
        case_bytes = (root / (cohort + '-cases.json')).read_bytes()
        require(sha(case_bytes) == summary['case_sha256'][cohort], 'case hash mismatch')
        case_list = parse(case_bytes)
        cases = {case['id']: case for case in case_list}
        require(len(cases) == len(case_list) == 6, 'cohort must contain six unique cases')
        rows = [parse(line) for line in (root / (cohort + '-calls.jsonl')).read_bytes().splitlines()]
        expected_order = [(case['id'], arm, repeat) for repeat in range(3)
                          for case in case_list for arm in policy['arms']]
        require([(r['case'], r['arm'], r['repeat']) for r in rows] == expected_order, 'missing, duplicate or reordered call')
        arms = {}
        per_case = {}
        usage = collections.Counter()
        models = collections.Counter()
        for row in rows:
            case, arm = cases[row['case']], row['arm']
            raw_request = base64.b64decode(row['request_raw_base64'], validate=True)
            raw_response = base64.b64decode(row['response_raw_base64'], validate=True)
            require(sha(raw_request) == row['request_sha256'], 'request hash mismatch')
            require(sha(raw_response) == row['response_sha256'], 'response hash mismatch')
            request = expected_request(policy, case, cohort, arm)
            canonical = json.dumps(request, ensure_ascii=False, separators=(',', ':')).encode()
            require(raw_request == canonical, 'request differs from frozen policy/case projection')
            require(parse(raw_request) == request, 'request JSON differs')
            require(row['expected_mergeable'] == case['expected_mergeable'], 'label mismatch')
            require('error' not in row and row['http_status'] == 200, 'unexpected recorded error')
            response = parse(raw_response)
            require(response['model'] == policy['model'], 'resolved model differs')
            decision = choice_decision(response['answers']['s0_0'], request['questions']['s0_0']['criteria'])
            matched = (decision == 'mergeable') == case['expected_mergeable']
            require(decision == row['decision'] and matched == row['matches_expected'], 'stored score mismatch')
            result = arms.setdefault(arm, {'calls': 0, 'matches': 0, 'errors': 0, 'false_merge': 0, 'false_retention': 0})
            result['calls'] += 1
            result['matches'] += matched
            result['false_merge'] += decision == 'mergeable' and not case['expected_mergeable']
            result['false_retention'] += decision != 'mergeable' and case['expected_mergeable']
            per_case.setdefault(case['id'], {}).setdefault(arm, []).append(decision)
            usage.update(response['usage'])
            models.update([response['model']])
        recorded = summary['cohorts'][cohort]
        require(arms == recorded['arms'], 'aggregate scores mismatch')
        require(per_case == recorded['per_case'], 'per-case scores mismatch')
        require(dict(usage) == recorded['usage'] and dict(models) == recorded['models'], 'usage/model totals mismatch')
        require(recorded['estimated_input_cost_usd'] == usage['input_tokens'] * 0.042 / 1_000_000, 'cost estimate mismatch')
        total_calls += len(rows)
        total_input += usage['input_tokens']
        print(cohort, {arm: f"{r['matches']}/{r['calls']}" for arm, r in arms.items()})
    require(total_calls == summary['total_calls'] == 108, 'total calls mismatch')
    require(total_input == summary['total_input_tokens'], 'input total mismatch')
    require(summary['estimated_total_cost_usd'] == total_input * 0.042 / 1_000_000, 'total cost estimate mismatch')
    print('PASS: 108 raw request/response hashes, canonical requests, typed scores and totals verified offline.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', help='Optional local git repository for checking the frozen source blob')
    args = parser.parse_args()
    try:
        verify(Path(__file__).resolve().parent, args.repo)
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        print('FAIL:', error, file=sys.stderr)
        raise SystemExit(1)
