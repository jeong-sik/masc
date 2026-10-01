#!/usr/bin/env python3
"""Read a finished isolated evaluation and check its retained provenance."""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path


def require(condition, detail):
    if not condition:
        raise ValueError(detail)


def validate_result(row, runtime_id):
    receipt = row['receipt']
    if row['status'] == 'ok':
        require(receipt['status'] == 'succeeded' and receipt['selected_slot'] == runtime_id,
                'successful result classification or slot mismatch')
        require(same_json(receipt['output']['result'], row['answer']), 'successful answer mismatch')
    else:
        require(row['status'] in {'invalid_response', 'transport_unavailable'}, 'unknown result status')
        code = {'invalid_response': 'candle_appraisal_rejected',
                'transport_unavailable': 'candle_appraisal_unavailable'}[row['status']]
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


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('workspace', type=Path)
    p.add_argument('evidence', type=Path)
    args = p.parse_args()
    plan = json.loads((args.workspace/'plan.json').read_text())
    exit_code = json.loads((args.evidence/'exit.json').read_text())['exit_code']
    require(type(exit_code) is int and exit_code == 0, 'retained evaluation exit is not zero')
    metadata = json.loads((args.evidence/'metadata.json').read_text())
    require(same_json(metadata['plan'], plan), "Evidence validation failed: same_json(metadata['plan'], plan)")
    require(metadata['build']['commit_source'] == 'embedded', "Evidence validation failed: metadata['build']['commit_source'] == 'embedded'")
    require(metadata['build']['commit'] == plan['source_commit'], "Evidence validation failed: metadata['build']['commit'] == plan['source_commit']")
    require(metadata['build']['binary_commit'] == plan['source_commit'], "Evidence validation failed: metadata['build']['binary_commit'] == plan['source_commit']")
    frozen_prompt_commit = None
    for filename, source_key in (('freeze.json', 'binary_commit'), ('frozen-audit.json', 'source_commit')):
        provenance = json.loads((args.evidence/filename).read_text())
        require(provenance[source_key] == plan['source_commit'], 'survey binary source disagrees with frozen provenance')
        require(provenance['executable_sha256'] == metadata['build']['executable_sha256'],
                'survey executable hash disagrees with frozen provenance')
        require(provenance['plan_sha256'] == sha((args.workspace/'plan.json').read_bytes()),
                'survey plan disagrees with frozen provenance')
        for field, plan_field in [('cases_sha256', 'cases_sha256'),
                ('runtime_config_sha256', 'runtime_config_sha256'),
                ('prompt_sha256', 'prompt_sha256'), ('case_count', 'case_count'),
                ('trials_each', 'trials'), ('planned_calls', 'planned_calls'),
                ('runtime_id', 'runtime_id')]:
            require(same_json(provenance[field], plan[plan_field]),
                    f'{filename} frozen {field} disagrees with plan')
        if frozen_prompt_commit is None:
            frozen_prompt_commit = provenance['prompt_commit']
        else:
            require(provenance['prompt_commit'] == frozen_prompt_commit,
                    'frozen prompt source declarations disagree')
    corpus = (args.workspace/'cases.json').read_bytes()
    require(sha(corpus) == plan['cases_sha256'], "Evidence validation failed: sha(corpus) == plan['cases_sha256']")
    require(sha((args.workspace/'.masc/config/runtime.toml').read_bytes()) == plan['runtime_config_sha256'], "Evidence validation failed: sha((args.workspace / '.masc/config/runtime.toml').read_bytes()) == plan['runtime_config_sha256']")
    prompt_bodies = {}
    for name, digest in plan['prompt_sha256'].items():
        prompt_raw = (args.workspace/'prompts'/name).read_bytes()
        require(sha(prompt_raw) == digest, 'Evidence validation failed: sha(prompt_raw) == digest')
        prompt_text = prompt_raw.decode()
        require(prompt_text.startswith('---\n'), "Evidence validation failed: prompt_text.startswith('---\\n')")
        # The frozen files use one frontmatter block; preserve body newlines.
        prompt_bodies[name] = prompt_text.split('\n---\n', 1)[1]
    raw_cases = json.loads(corpus)
    require(isinstance(raw_cases, list) and len(raw_cases) == plan['case_count'],
            'raw corpus count disagrees with declared case count')
    cases = {case['id']: case for case in raw_cases}
    require(len(cases) == len(raw_cases), 'raw corpus contains duplicate case IDs')
    raw = (args.evidence/'results.jsonl').read_bytes()
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
        require(row['stage'] == case['stage'], "Evidence validation failed: row['stage'] == case['stage']")
        require(type(row['trial']) is int and 1 <= row['trial'] <= plan['trials'], "Evidence validation failed: type(row['trial']) is int and 1 <= row['trial'] <= plan['trials']")
        pair = (row['case_id'], row['trial'])
        require(pair not in seen, 'Evidence validation failed: pair not in seen')
        seen.add(pair)
        receipt = row['receipt']
        require(receipt['run_id'] not in run_ids, "Evidence validation failed: receipt['run_id'] not in run_ids")
        run_ids.add(receipt['run_id'])
        require(receipt['lane'] == 'candle_appraiser', "Evidence validation failed: receipt['lane'] == 'candle_appraiser'")
        require(receipt['subject_id'] is None, "Evidence validation failed: receipt['subject_id'] is None")
        require(receipt['input']['kind'] == 'exact', "Evidence validation failed: receipt['input']['kind'] == 'exact'")
        require(receipt['payload_availability'] == {'input': {'state': 'available'}, 'output': {'state': 'available'}}, "Evidence validation failed: receipt['payload_availability'] == {'input': {'state': 'available'}, 'output': {'state': 'available'}}")
        payload = receipt['input']['payload']
        require(payload['goal_id'] == case['id'], "Evidence validation failed: payload['goal_id'] == case['id']")
        require(payload['request_id'] == f"eval-{case['id']}-{row['trial']}", 'Evidence validation failed: payload[\'request_id\'] == f"eval-{case[\'id\']}-{row[\'trial\']}"')
        require(payload['verification_run_id'] == 'synthetic-eval-verification', "Evidence validation failed: payload['verification_run_id'] == 'synthetic-eval-verification'")
        require(payload['stage'] == case['stage'], "Evidence validation failed: payload['stage'] == case['stage']")
        require(same_json(payload['actual_input'], expected_input(case)), "Evidence validation failed: same_json(payload['actual_input'], expected_input(case))")
        require(same_json(payload['output_schema'], expected_schema(case)),
                'receipt output schema disagrees with frozen stage and case')
        prompt = payload['prompt']
        require(prompt['source'] == 'file', "Evidence validation failed: prompt['source'] == 'file'")
        require(prompt['key'] == 'candle_appraiser_'+case['stage'], "Evidence validation failed: prompt['key'] == 'candle_appraiser_' + case['stage']")
        require(prompt['effective_template'] == prompt_bodies[prompt['key']+'.md'], "Evidence validation failed: prompt['effective_template'] == prompt_bodies[prompt['key'] + '.md']")
        encoded_input = json.dumps(payload['actual_input'], ensure_ascii=False, separators=(',', ':'))
        require(prompt['rendered'] == prompt['effective_template'].replace('{{appraisal_input}}', encoded_input), "Evidence validation failed: prompt['rendered'] == prompt['effective_template'].replace('{{appraisal_input}}', encoded_input)")
        prompt_hashes[case['id']].add(sha(prompt['rendered'].encode()))
        input_hashes[case['id']].add(sha(encoded_input.encode()))
        require(receipt['output']['semantic_verification'] == 'not_performed', "Evidence validation failed: receipt['output']['semantic_verification'] == 'not_performed'")
        validate_result(row, plan['runtime_id'])
        dispatch = [attempt for attempt in receipt['output']['attempts'] if attempt['kind'] == 'dispatch']
        require(len(dispatch) == 1, 'Evidence validation failed: len(dispatch) == 1')
        require(dispatch[0]['slot'] == plan['runtime_id'], "Evidence validation failed: dispatch[0]['slot'] == plan['runtime_id']")
        status_counts[row['status']] += 1
        selected_slots[receipt['selected_slot']] += 1
        decisions[case['id']].append({'trial': row['trial'], 'run_id': receipt['run_id'],
            'status': row['status'], 'answer': row.get('answer')})
    require(len(seen) == len(cases) * plan['trials'], "Evidence validation failed: len(seen) == len(cases) * plan['trials']")
    require(all(len(values) == 1 for values in prompt_hashes.values()), 'Evidence validation failed: all((len(values) == 1 for values in prompt_hashes.values()))')
    require(all(len(values) == 1 for values in input_hashes.values()), 'Evidence validation failed: all((len(values) == 1 for values in input_hashes.values()))')
    require(len({row['receipt']['actor'] for row in rows}) == 1, "Evidence validation failed: len({row['receipt']['actor'] for row in rows}) == 1")
    # Independently re-read the persisted registry and hash-addressed payloads.
    # The hydrated result must describe the same registered/completed run.
    receipts = {row['receipt']['run_id']: row['receipt'] for row in rows}
    events_raw = (args.evidence/'exact-lane-runs-v6.jsonl').read_bytes()
    events = [json.loads(line) for line in events_raw.splitlines()]
    registered, completed = set(), set()
    registration_order = []
    for event in events:
        run_id = event['id']
        receipt = receipts[run_id]
        if event['event'] == 'register':
            require(run_id not in registered, 'Evidence validation failed: run_id not in registered')
            registered.add(run_id)
            registration_order.append(run_id)
            registration = event['registration']
            require(registration['lane'] == receipt['lane'], "Evidence validation failed: registration['lane'] == receipt['lane']")
            require(registration['actor'] == receipt['actor'], "Evidence validation failed: registration['actor'] == receipt['actor']")
            require(event['started_at'] == receipt['started_at'], "Evidence validation failed: event['started_at'] == receipt['started_at']")
            side, reference, expected = 'input', registration['input'], receipt['input']['payload']
        else:
            require(event['event'] == 'complete', "Evidence validation failed: event['event'] == 'complete'")
            require(run_id in registered and run_id not in completed, 'Evidence validation failed: run_id in registered and run_id not in completed')
            completed.add(run_id)
            completion = event['completion']
            require(completion['outcome'] == receipt['status'], "Evidence validation failed: completion['outcome'] == receipt['status']")
            require(completion['selected_slot'] == receipt['selected_slot'], "Evidence validation failed: completion['selected_slot'] == receipt['selected_slot']")
            require(completion['elapsed_s'] == receipt['elapsed_s'], "Evidence validation failed: completion['elapsed_s'] == receipt['elapsed_s']")
            side, reference, expected = 'output', completion['output'], receipt['output']
        require(reference['kind'] == 'file', "Evidence validation failed: reference['kind'] == 'file'")
        path = args.evidence/'exact-lane-run-payloads'/run_id/f"{side}-{reference['sha256']}.json"
        payload_bytes = path.read_bytes()
        require(len(payload_bytes) == reference['bytes'], "Evidence validation failed: len(payload_bytes) == reference['bytes']")
        require(sha(payload_bytes) == reference['sha256'], "Evidence validation failed: sha(payload_bytes) == reference['sha256']")
        require(same_json(json.loads(payload_bytes), expected), 'Evidence validation failed: same_json(json.loads(payload_bytes), expected)')
    require(registered == completed == run_ids, 'Evidence validation failed: registered == completed == run_ids')
    require(registration_order == [row['receipt']['run_id'] for row in rows],
            'reported trial order disagrees with registry registration order')
    result = {
        'scope': 'Provenance and structural checks, not semantic acceptance',
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
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == '__main__':
    main()
