#!/usr/bin/env python3
"""Read a finished isolated evaluation and check its retained provenance."""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


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
    metadata = json.loads((args.evidence/'metadata.json').read_text())
    require((metadata['plan'] == plan), "validation failed: metadata['plan'] == plan")
    require((metadata['build']['commit_source'] == 'embedded'), "validation failed: metadata['build']['commit_source'] == 'embedded'")
    require((metadata['build']['commit'] == plan['source_commit']), "validation failed: metadata['build']['commit'] == plan['source_commit']")
    require((metadata['build']['binary_commit'] == plan['source_commit']), "validation failed: metadata['build']['binary_commit'] == plan['source_commit']")
    corpus = (args.workspace/'cases.json').read_bytes()
    require((sha(corpus) == plan['cases_sha256']), "validation failed: sha(corpus) == plan['cases_sha256']")
    require((sha((args.workspace/'.masc/config/runtime.toml').read_bytes()) == plan['runtime_config_sha256']), "validation failed: sha((args.workspace/'.masc/config/runtime.toml').read_bytes()) == plan['runtime_config_sha256']")
    prompt_bodies = {}
    for name, digest in plan['prompt_sha256'].items():
        prompt_raw = (args.workspace/'prompts'/name).read_bytes()
        require((sha(prompt_raw) == digest), 'validation failed: sha(prompt_raw) == digest')
        prompt_text = prompt_raw.decode()
        require((prompt_text.startswith('---\n')), "validation failed: prompt_text.startswith('---\\n')")
        # The frozen files use one frontmatter block; preserve body newlines.
        prompt_bodies[name] = prompt_text.split('\n---\n', 1)[1]
    cases = {case['id']: case for case in json.loads(corpus)}
    raw = (args.evidence/'results.jsonl').read_bytes()
    require((raw.endswith(b'\n')), 'partial result line')
    rows = [json.loads(line) for line in raw.splitlines()]
    require((len(rows) == plan['planned_calls']), 'evaluation is not complete')
    seen = set()
    run_ids = set()
    prompt_hashes = defaultdict(set)
    input_hashes = defaultdict(set)
    status_counts = Counter()
    selected_slots = Counter()
    decisions = defaultdict(list)
    for row in rows:
        case = cases[row['case_id']]
        require((row['stage'] == case['stage']), "validation failed: row['stage'] == case['stage']")
        require((type(row['trial']) is int and 1 <= row['trial'] <= plan['trials']), "validation failed: type(row['trial']) is int and 1 <= row['trial'] <= plan['trials']")
        pair = (row['case_id'], row['trial'])
        require((pair not in seen), 'validation failed: pair not in seen')
        seen.add(pair)
        receipt = row['receipt']
        require((receipt['run_id'] not in run_ids), "validation failed: receipt['run_id'] not in run_ids")
        run_ids.add(receipt['run_id'])
        require((receipt['lane'] == 'candle_appraiser'), "validation failed: receipt['lane'] == 'candle_appraiser'")
        require((receipt['subject_id'] is None), "validation failed: receipt['subject_id'] is None")
        require((receipt['input']['kind'] == 'exact'), "validation failed: receipt['input']['kind'] == 'exact'")
        require((receipt['payload_availability'] == {'input': {'state': 'available'}, 'output': {'state': 'available'}}), "validation failed: receipt['payload_availability'] == {'input': {'state': 'available'}, 'output': {'state': 'available'}}")
        payload = receipt['input']['payload']
        require((payload['goal_id'] == case['id']), "validation failed: payload['goal_id'] == case['id']")
        require((payload['request_id'] == f"eval-{case['id']}-{row['trial']}"), 'validation failed: payload[\'request_id\'] == f"eval-{case[\'id\']}-{row[\'trial\']}"')
        require((payload['verification_run_id'] == 'synthetic-eval-verification'), "validation failed: payload['verification_run_id'] == 'synthetic-eval-verification'")
        require((payload['stage'] == case['stage']), "validation failed: payload['stage'] == case['stage']")
        require((payload['actual_input'] == expected_input(case)), "validation failed: payload['actual_input'] == expected_input(case)")
        prompt = payload['prompt']
        require((prompt['source'] == 'file'), "validation failed: prompt['source'] == 'file'")
        require((prompt['key'] == 'candle_appraiser_'+case['stage']), "validation failed: prompt['key'] == 'candle_appraiser_'+case['stage']")
        require((prompt['effective_template'] == prompt_bodies[prompt['key']+'.md']), "validation failed: prompt['effective_template'] == prompt_bodies[prompt['key']+'.md']")
        encoded_input = json.dumps(payload['actual_input'], ensure_ascii=False, separators=(',', ':'))
        require((prompt['rendered'] == prompt['effective_template'].replace('{{appraisal_input}}', encoded_input)), "validation failed: prompt['rendered'] == prompt['effective_template'].replace('{{appraisal_input}}', encoded_input)")
        prompt_hashes[case['id']].add(sha(prompt['rendered'].encode()))
        input_hashes[case['id']].add(sha(encoded_input.encode()))
        require((receipt['output']['semantic_verification'] == 'not_performed'), "validation failed: receipt['output']['semantic_verification'] == 'not_performed'")
        if row['status'] == 'ok':
            require((receipt['status'] == 'succeeded'), "validation failed: receipt['status'] == 'succeeded'")
            require((receipt['selected_slot'] == plan['runtime_id']), "validation failed: receipt['selected_slot'] == plan['runtime_id']")
            require((receipt['output']['result'] == row['answer']), "validation failed: receipt['output']['result'] == row['answer']")
        else:
            require((receipt['status'] == 'failed'), "validation failed: receipt['status'] == 'failed'")
        dispatch = [attempt for attempt in receipt['output']['attempts'] if attempt['kind'] == 'dispatch']
        require((len(dispatch) == 1), 'validation failed: len(dispatch) == 1')
        require((dispatch[0]['slot'] == plan['runtime_id']), "validation failed: dispatch[0]['slot'] == plan['runtime_id']")
        status_counts[row['status']] += 1
        selected_slots[receipt['selected_slot']] += 1
        decisions[case['id']].append({'trial': row['trial'], 'run_id': receipt['run_id'],
            'status': row['status'], 'answer': row.get('answer')})
    require((len(seen) == len(cases) * plan['trials']), "validation failed: len(seen) == len(cases) * plan['trials']")
    require((all(len(values) == 1 for values in prompt_hashes.values())), 'validation failed: all(len(values) == 1 for values in prompt_hashes.values())')
    require((all(len(values) == 1 for values in input_hashes.values())), 'validation failed: all(len(values) == 1 for values in input_hashes.values())')
    require((len({row['receipt']['actor'] for row in rows}) == 1), "validation failed: len({row['receipt']['actor'] for row in rows}) == 1")
    # Independently re-read the persisted registry and hash-addressed payloads.
    # The hydrated result must describe the same registered/completed run.
    receipts = {row['receipt']['run_id']: row['receipt'] for row in rows}
    events_raw = (args.evidence/'exact-lane-runs-v6.jsonl').read_bytes()
    events = [json.loads(line) for line in events_raw.splitlines()]
    registered, completed = set(), set()
    for event in events:
        run_id = event['id']
        receipt = receipts[run_id]
        if event['event'] == 'register':
            require((run_id not in registered), 'validation failed: run_id not in registered')
            registered.add(run_id)
            registration = event['registration']
            require((registration['lane'] == receipt['lane']), "validation failed: registration['lane'] == receipt['lane']")
            require((registration['actor'] == receipt['actor']), "validation failed: registration['actor'] == receipt['actor']")
            require((event['started_at'] == receipt['started_at']), "validation failed: event['started_at'] == receipt['started_at']")
            side, reference, expected = 'input', registration['input'], receipt['input']['payload']
        else:
            require((event['event'] == 'complete'), "validation failed: event['event'] == 'complete'")
            require((run_id in registered and run_id not in completed), 'validation failed: run_id in registered and run_id not in completed')
            completed.add(run_id)
            completion = event['completion']
            require((completion['outcome'] == receipt['status']), "validation failed: completion['outcome'] == receipt['status']")
            require((completion['selected_slot'] == receipt['selected_slot']), "validation failed: completion['selected_slot'] == receipt['selected_slot']")
            require((completion['elapsed_s'] == receipt['elapsed_s']), "validation failed: completion['elapsed_s'] == receipt['elapsed_s']")
            side, reference, expected = 'output', completion['output'], receipt['output']
        require((reference['kind'] == 'file'), "validation failed: reference['kind'] == 'file'")
        path = args.evidence/'exact-lane-run-payloads'/run_id/f"{side}-{reference['sha256']}.json"
        payload_bytes = path.read_bytes()
        require((len(payload_bytes) == reference['bytes']), "validation failed: len(payload_bytes) == reference['bytes']")
        require((sha(payload_bytes) == reference['sha256']), "validation failed: sha(payload_bytes) == reference['sha256']")
        require((json.loads(payload_bytes) == expected), 'validation failed: json.loads(payload_bytes) == expected')
    require((registered == completed == run_ids), 'validation failed: registered == completed == run_ids')
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
        'cases': {key: {'input_sha256': next(iter(input_hashes[key])),
            'rendered_prompt_sha256': next(iter(prompt_hashes[key])),
            'decisions': sorted(decisions[key], key=lambda row: row['trial'])} for key in cases},
    }
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == '__main__':
    main()
