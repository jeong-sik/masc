#!/usr/bin/env python3
"""Read a finished isolated evaluation and check its retained provenance."""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
import tomllib
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_result(row, runtime_id, case):
    receipt = row['receipt']
    if row['status'] == 'ok':
        require(receipt['status'] == 'succeeded' and receipt['selected_slot'] == runtime_id,
                'successful result classification or slot mismatch')
        require(same_json(receipt['output']['result'], row['answer']), 'successful answer mismatch')
        validate_answer(row['answer'], expected_schema(case))
        responses = [attempt for attempt in receipt['output']['attempts']
                     if attempt['kind'] == 'response']
        require(bool(responses) and all(attempt['slot'] == runtime_id
                and same_json(attempt['output'], row['answer']) for attempt in responses),
                'successful response observations disagree with result')
    else:
        require(row['status'] in {'invalid_response', 'transport_unavailable'}, 'unknown result status')
        code = {'invalid_response': 'candle_appraisal_rejected',
                'transport_unavailable': 'candle_appraisal_unavailable'}[row['status']]
        require(receipt['selected_slot'] == runtime_id, 'failed selected slot disagrees with dispatch')
        require(receipt['status'] == 'failed' and receipt['code'] == code,
                'failed result classification mismatch')
        require(isinstance(row['answer'], str) and receipt['detail'] == row['answer']
                and same_json(receipt['output']['result'], {'error': row['answer']}),
                'failed answer mismatch')


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def same_json(left, right):
    def canonical(value):
        return json.dumps(value, sort_keys=True, ensure_ascii=False,
                          separators=(',', ':'), allow_nan=False)
    return canonical(left) == canonical(right)


def expected_schema(case):
    # Frozen evaluation contract from Candle_appraisal.schema, including the
    # ordered required Keeper names and integer weight bound.
    def object_schema(properties):
        return {'type': 'object', 'properties': properties,
                'required': list(properties), 'additionalProperties': False}
    if case['stage'] == 'grade':
        return object_schema({'grade': {'type': 'string',
            'enum': ['trivial', 'small', 'medium', 'large', 'epic']}})
    if case['stage'] == 'relation':
        return object_schema({'relation': {'type': 'string', 'enum': ['related', 'unrelated']}})
    require(case['stage'] == 'weights', 'unknown frozen appraisal stage')
    data = case['input']
    return object_schema({'weights': object_schema({name: {'type': 'integer',
        'minimum': 0, 'maximum': data['weight_max']} for name in data['keepers']})})


def validate_answer(value, schema):
    kind = schema['type']
    if kind == 'object':
        require(type(value) is dict and set(value) == set(schema['properties']),
                'successful answer violates stage schema')
        for key, child in schema['properties'].items():
            validate_answer(value[key], child)
    elif kind == 'string':
        require(type(value) is str and value in schema['enum'],
                'successful answer violates stage schema')
    else:
        require(kind == 'integer' and type(value) is int
                and schema['minimum'] <= value <= schema['maximum'],
                'successful answer violates stage schema')


def validate_runtime(raw, plan):
    config = tomllib.loads(raw.decode())
    lane = config['runtime']['exact_output_lanes']['candle_appraiser']
    runtime_id = plan['runtime_id']
    require(lane['slots'] == [runtime_id] and lane['cli_slots'] == [],
            'prepared runtime slots disagree with plan')
    provider_id, _ = runtime_id.split('.', 1)
    provider = config['providers'][provider_id]
    require(lane['max_output_tokens'] == plan['evaluation_overrides']['max-output-tokens'],
            'prepared output limit disagrees with plan')
    require(provider['exact-body-timeout-s'] == plan['evaluation_overrides']['exact-body-timeout-s'],
            'prepared timeout disagrees with plan')
    require(provider['credentials'] == {'type': 'env', 'key': plan['credential_env']},
            'prepared credential reference disagrees with plan')


def expected_input(case):
    data = case['input']
    if case['stage'] != 'weights':
        return data
    return {
        'goal': data['goal'],
        'tasks': [{'title': task['title'], 'assignee': task['keeper']} for task in data['tasks']],
        'keepers': data['keepers'],
        'weight_max': data['weight_max'],
    }


def audit(workspace, evidence, resources, *, runtime_config=None):
    plan = json.loads((workspace/'plan.json').read_text())
    exit_code = json.loads((evidence/'exit.json').read_text())['exit_code']
    require(type(exit_code) is int and exit_code == 0, 'retained evaluation exit is not zero')
    metadata = json.loads((evidence/'metadata.json').read_text())
    require(same_json(metadata['plan'], plan), "audit check failed: same_json(metadata['plan'], plan)")
    require(metadata['build']['commit_source'] == 'embedded', "audit check failed: metadata['build']['commit_source'] == 'embedded'")
    require(metadata['build']['commit'] == plan['source_commit'], "audit check failed: metadata['build']['commit'] == plan['source_commit']")
    require(metadata['build']['binary_commit'] == plan['source_commit'], "audit check failed: metadata['build']['binary_commit'] == plan['source_commit']")
    verification = json.loads((resources/'artifact-verification.json').read_text())
    require(verification['source_commit'] == plan['source_commit'], 'CI artifact source commit mismatch')
    executable = Path(metadata['build']['executable_path']).name
    require(executable == 'candle_appraiser_eval_cli.exe', 'unexpected evaluation executable')
    artifacts = [entry for entry in verification['files'] if entry['file'] == executable]
    require(len(artifacts) == 1, 'CI artifact must identify exactly one evaluation executable')
    require(metadata['build']['executable_sha256'] == artifacts[0]['sha256'],
            'evaluation executable hash disagrees with CI artifact verification')
    corpus = (workspace/'cases.json').read_bytes()
    require(sha(corpus) == plan['cases_sha256'], "audit check failed: sha(corpus) == plan['cases_sha256']")
    if runtime_config is not None:
        require(sha(runtime_config.read_bytes()) == plan['runtime_config_sha256'],
                'prepared runtime configuration hash disagrees with plan')
        validate_runtime(runtime_config.read_bytes(), plan)
    prompt_bodies = {}
    for name, digest in plan['prompt_sha256'].items():
        prompt_raw = (resources/'prompts'/name).read_bytes()
        require(sha(prompt_raw) == digest, 'audit check failed: sha(prompt_raw) == digest')
        prompt_text = prompt_raw.decode()
        require(prompt_text.startswith('---\n'), "audit check failed: prompt_text.startswith('---\\n')")
        # The frozen files use one frontmatter block; preserve body newlines.
        prompt_bodies[name] = prompt_text.split('\n---\n', 1)[1]
    raw_cases = json.loads(corpus)
    require(isinstance(raw_cases, list) and len(raw_cases) == plan['case_count'],
            'raw corpus count disagrees with declared case count')
    cases = {case['id']: case for case in raw_cases}
    require(len(cases) == len(raw_cases), 'raw corpus contains duplicate case IDs')
    raw = (evidence/'results.jsonl').read_bytes()
    require(raw.endswith(b'\n'), 'partial result line')
    rows = [json.loads(line) for line in raw.splitlines()]
    require(len(rows) == plan['planned_calls'], 'evaluation is not complete')
    seen = set()
    run_ids = set()
    prompt_hashes = defaultdict(set)
    input_hashes = defaultdict(set)
    status_counts = Counter()
    selected_slots = Counter()
    decisions = defaultdict(list)
    for row in rows:
        case = cases[row['case_id']]
        require(row['stage'] == case['stage'], "audit check failed: row['stage'] == case['stage']")
        require(type(row['trial']) is int and 1 <= row['trial'] <= plan['trials'], "audit check failed: type(row['trial']) is int and 1 <= row['trial'] <= plan['trials']")
        pair = (row['case_id'], row['trial'])
        require(pair not in seen, 'audit check failed: pair not in seen')
        seen.add(pair)
        receipt = row['receipt']
        require(receipt['run_id'] not in run_ids, "audit check failed: receipt['run_id'] not in run_ids")
        run_ids.add(receipt['run_id'])
        require(receipt['lane'] == 'candle_appraiser', "audit check failed: receipt['lane'] == 'candle_appraiser'")
        require(receipt['subject_id'] is None, "audit check failed: receipt['subject_id'] is None")
        require(receipt['input']['kind'] == 'exact', "audit check failed: receipt['input']['kind'] == 'exact'")
        require(receipt['payload_availability'] == {'input': {'state': 'available'}, 'output': {'state': 'available'}}, "audit check failed: receipt['payload_availability'] == {'input': {'state': 'available'}, 'output': {'state': 'available'}}")
        payload = receipt['input']['payload']
        require(payload['goal_id'] == case['id'], "audit check failed: payload['goal_id'] == case['id']")
        require(payload['request_id'] == f"eval-{case['id']}-{row['trial']}", 'audit check failed: payload[\'request_id\'] == f"eval-{case[\'id\']}-{row[\'trial\']}"')
        require(payload['verification_run_id'] == 'synthetic-eval-verification', "audit check failed: payload['verification_run_id'] == 'synthetic-eval-verification'")
        require(payload['stage'] == case['stage'], "audit check failed: payload['stage'] == case['stage']")
        require(same_json(payload['actual_input'], expected_input(case)), "audit check failed: same_json(payload['actual_input'], expected_input(case))")
        require(same_json(payload['output_schema'], expected_schema(case)),
                'receipt output schema disagrees with frozen stage and case')
        prompt = payload['prompt']
        require(prompt['source'] == 'file', "audit check failed: prompt['source'] == 'file'")
        require(prompt['key'] == 'candle_appraiser_'+case['stage'], "audit check failed: prompt['key'] == 'candle_appraiser_'+case['stage']")
        require(prompt['effective_template'] == prompt_bodies[prompt['key']+'.md'], "audit check failed: prompt['effective_template'] == prompt_bodies[prompt['key']+'.md']")
        encoded_input = json.dumps(payload['actual_input'], ensure_ascii=False, separators=(',', ':'))
        require(prompt['rendered'] == prompt['effective_template'].replace('{{appraisal_input}}', encoded_input), "audit check failed: prompt['rendered'] == prompt['effective_template'].replace('{{appraisal_input}}', encoded_input)")
        prompt_hashes[case['id']].add(sha(prompt['rendered'].encode()))
        input_hashes[case['id']].add(sha(encoded_input.encode()))
        require(receipt['output']['semantic_verification'] == 'not_performed', "audit check failed: receipt['output']['semantic_verification'] == 'not_performed'")
        validate_result(row, plan['runtime_id'], case)
        dispatch = [attempt for attempt in receipt['output']['attempts'] if attempt['kind'] == 'dispatch']
        require(len(dispatch) == 1, 'audit check failed: len(dispatch) == 1')
        require(dispatch[0]['slot'] == plan['runtime_id'], "audit check failed: dispatch[0]['slot'] == plan['runtime_id']")
        status_counts[row['status']] += 1
        selected_slots[receipt['selected_slot']] += 1
        decisions[case['id']].append({'trial': row['trial'], 'run_id': receipt['run_id'],
            'status': row['status'], 'answer': row.get('answer')})
    require(len(seen) == len(cases) * plan['trials'], "audit check failed: len(seen) == len(cases) * plan['trials']")
    require(all(len(values) == 1 for values in prompt_hashes.values()), 'audit check failed: all(len(values) == 1 for values in prompt_hashes.values())')
    require(all(len(values) == 1 for values in input_hashes.values()), 'audit check failed: all(len(values) == 1 for values in input_hashes.values())')
    require(len({row['receipt']['actor'] for row in rows}) == 1, "audit check failed: len({row['receipt']['actor'] for row in rows}) == 1")
    # Independently re-read the persisted registry and hash-addressed payloads.
    # The hydrated result must describe the same registered/completed run.
    receipts = {row['receipt']['run_id']: row['receipt'] for row in rows}
    events_raw = (evidence/'exact-lane-runs-v6.jsonl').read_bytes()
    events = [json.loads(line) for line in events_raw.splitlines()]
    registered, completed = set(), set()
    registration_order = []
    for event in events:
        run_id = event['id']
        require(run_id in receipts, 'registry run ID is absent from reported receipts')
        receipt = receipts[run_id]
        if event['event'] == 'register':
            require(run_id not in registered, 'audit check failed: run_id not in registered')
            registered.add(run_id)
            registration_order.append(run_id)
            registration = event['registration']
            require(registration['lane'] == receipt['lane'], "audit check failed: registration['lane'] == receipt['lane']")
            require(registration['actor'] == receipt['actor'], "audit check failed: registration['actor'] == receipt['actor']")
            require(event['started_at'] == receipt['started_at'], "audit check failed: event['started_at'] == receipt['started_at']")
            side, reference, expected = 'input', registration['input'], receipt['input']['payload']
        else:
            require(event['event'] == 'complete', "audit check failed: event['event'] == 'complete'")
            require(run_id in registered and run_id not in completed, 'audit check failed: run_id in registered and run_id not in completed')
            completed.add(run_id)
            completion = event['completion']
            require(completion['outcome'] == receipt['status'], "audit check failed: completion['outcome'] == receipt['status']")
            if receipt['status'] == 'failed':
                require(completion['code'] == receipt['code'] and completion['detail'] == receipt['detail'],
                        'registry failure code or detail disagrees with receipt')
            require(completion['selected_slot'] == receipt['selected_slot'], "audit check failed: completion['selected_slot'] == receipt['selected_slot']")
            require(completion['elapsed_s'] == receipt['elapsed_s'], "audit check failed: completion['elapsed_s'] == receipt['elapsed_s']")
            side, reference, expected = 'output', completion['output'], receipt['output']
        require(reference['kind'] == 'file', "audit check failed: reference['kind'] == 'file'")
        path = evidence/'exact-lane-run-payloads'/run_id/f"{side}-{reference['sha256']}.json"
        payload_bytes = path.read_bytes()
        require(len(payload_bytes) == reference['bytes'], "audit check failed: len(payload_bytes) == reference['bytes']")
        require(sha(payload_bytes) == reference['sha256'], "audit check failed: sha(payload_bytes) == reference['sha256']")
        require(same_json(json.loads(payload_bytes), expected), 'audit check failed: same_json(json.loads(payload_bytes), expected)')
    require(registered == completed == run_ids, 'audit check failed: registered == completed == run_ids')
    require(registration_order == [row['receipt']['run_id'] for row in rows],
            'reported trial order disagrees with registry registration order')
    result = {
        'scope': 'Provenance and structural checks, not semantic acceptance',
        'runtime_config_verification': 'prepared_bytes_verified' if runtime_config is not None else 'declared_hash_only',
        'source_commit': plan['source_commit'], 'runtime_id': plan['runtime_id'],
        'executable_sha256': metadata['build']['executable_sha256'],
        'results_sha256': sha(raw), 'complete_pairs': len(seen), 'unique_run_ids': len(run_ids),
        'status_counts': dict(status_counts), 'selected_slots': dict(selected_slots),
        'actor': rows[0]['receipt']['actor'],
        'actual_inputs_match_frozen_corpus': True,
        'receipt_templates_match_frozen_prompt_files': True,
        'one_identical_rendered_prompt_per_case': True,
        'one_dispatch_per_run_to_declared_slot': True,
        'receipt_results_match_reported_decisions': True,
        'registry_sha256': sha(events_raw),
        'registered_before_completed_with_matching_durable_payloads': True,
        'trial_order': [[row['case_id'], row['trial']] for row in rows],
        'cases': {key: {'input_sha256': next(iter(input_hashes[key])),
            'rendered_prompt_sha256': next(iter(prompt_hashes[key])),
            'decisions': sorted(decisions[key], key=lambda row: row['trial'])} for key in cases},
    }
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('workspace', type=Path)
    p.add_argument('evidence', type=Path)
    p.add_argument('--resources', type=Path, help='Frozen prompts and independent artifact record; defaults to evidence directory')
    args = p.parse_args()
    print(json.dumps(audit(args.workspace, args.evidence, args.resources or args.evidence,
                           runtime_config=args.workspace/'.masc/config/runtime.toml'), indent=2, ensure_ascii=False))


if __name__ == '__main__':
    main()
