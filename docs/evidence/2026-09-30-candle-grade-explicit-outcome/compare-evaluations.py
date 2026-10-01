#!/usr/bin/env python3
"""Compare complete frozen appraiser runs without assigning an acceptance score."""
import argparse
from collections import Counter
from fractions import Fraction
import hashlib
import json
import runpy
from pathlib import Path


# Share the complete artifact, registry and durable-payload audit with the CLI.
AUDIT_MODULE = runpy.run_path(str(Path(__file__).with_name('audit-candidate.py')))
AUDIT = AUDIT_MODULE['audit']
same_json = AUDIT_MODULE['same_json']

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


def load_run(directory, resources):
    plan = json.loads((directory / "plan.json").read_text())
    cases_raw = (directory / "cases.json").read_bytes()
    require(hashlib.sha256(cases_raw).hexdigest() == plan["cases_sha256"], "Evidence validation failed: hashlib.sha256(cases_raw).hexdigest() == plan['cases_sha256']")
    cases = {case["id"]: case for case in json.loads(cases_raw)}
    raw = (directory / "results.jsonl").read_bytes()
    require(raw.endswith(b"\n"), "partial result line")
    rows = [json.loads(line) for line in raw.splitlines()]
    require(len(rows) == plan["planned_calls"], "wait for the entire frozen run")
    pairs = {(row["case_id"], row["trial"]) for row in rows}
    require(pairs == {(case_id, trial) for case_id in cases for trial in range(1, plan["trials"] + 1)}, "Evidence validation failed: pairs == {(case_id, trial) for case_id in cases for trial in range(1, plan['trials'] + 1)}")
    require(len(pairs) == len(rows), "duplicate case/trial")
    require(len({row["receipt"]["run_id"] for row in rows}) == len(rows), "Evidence validation failed: len({row['receipt']['run_id'] for row in rows}) == len(rows)")
    metadata = json.loads((directory / "metadata.json").read_text())
    require(same_json(metadata["plan"], plan), "Evidence validation failed: same_json(metadata['plan'], plan)")
    require(metadata["build"]["commit"] == plan["source_commit"], "Evidence validation failed: metadata['build']['commit'] == plan['source_commit']")
    require(json.loads((directory / "exit.json").read_text())["exit_code"] == 0, "Evidence validation failed: json.loads((directory / 'exit.json').read_text())['exit_code'] == 0")
    prompt_bodies = {}
    for name, digest in plan['prompt_sha256'].items():
        frozen = (resources/'prompts'/name).read_bytes()
        require(hashlib.sha256(frozen).hexdigest() == digest, 'frozen prompt hash mismatch')
        text = frozen.decode('utf-8')
        require(text.startswith('---\n') and '\n---\n' in text, 'frozen prompt frontmatter missing')
        prompt_bodies[name] = text.split('\n---\n', 1)[1]
    for row in rows:
        case = cases[row['case_id']]
        payload = row['receipt']['input']['payload']
        require(payload['stage'] == case['stage'] and payload['goal_id'] == case['id'],
                'receipt input stage or case identity mismatch')
        require(payload['request_id'] == f"eval-{case['id']}-{row['trial']}",
                'receipt request identity mismatch')
        require(same_json(payload['actual_input'], expected_input(case)),
                'receipt actual input disagrees with frozen case')
        validate_result(row, plan['runtime_id'])
        prompt = payload['prompt']
        require(prompt['source'] == 'file' and prompt['key'] == 'candle_appraiser_' + case['stage'],
                'receipt prompt source or stage mismatch')
        require(prompt['effective_template'] == prompt_bodies[prompt['key'] + '.md'],
                'receipt effective template disagrees with frozen prompt')
        encoded = json.dumps(payload['actual_input'], ensure_ascii=False, separators=(',', ':'))
        require(prompt['rendered'] == prompt['effective_template'].replace('{{appraisal_input}}', encoded),
                'receipt rendered prompt disagrees with frozen template and input')
    audited = AUDIT(directory, directory, resources)
    summaries = {}
    for case_id, case in cases.items():
        selected = [row for row in rows if row["case_id"] == case_id]
        require(all(row["stage"] == case["stage"] for row in selected), "Evidence validation failed: all((row['stage'] == case['stage'] for row in selected))")
        valid = [row for row in selected if row["status"] == "ok"]
        tally = {"statuses": dict(Counter(row["status"] for row in selected))}
        if case["stage"] == "weights":
            comparison = case["comparison"]
            contributor = comparison["candidate_keeper"] if comparison else case["input"]["keepers"][0]
            ratios = [Fraction(row["answer"]["weights"][contributor], sum(row["answer"]["weights"].values())) for row in valid]
            counts = Counter(str(ratio) for ratio in ratios)
            tally.update({"contributor": contributor, "share_counts": dict(sorted(counts.items())),
                          "mean_share_exact": str(sum(ratios, Fraction()) / len(ratios)) if ratios else None})
        else:
            counts = Counter(row["answer"][case["stage"]] for row in valid)
            tally["answers"] = dict(sorted(counts.items()))
        tally["modes"] = sorted(value for value, count in counts.items() if count == max(counts.values())) if counts else []
        tally["modal_count"] = max(counts.values()) if counts else 0
        summaries[case_id] = tally
    return plan, metadata, summaries, hashlib.sha256(raw).hexdigest(), {row["receipt"]["run_id"] for row in rows}, audited["trial_order"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument('--baseline-resources', type=Path, help='Baseline frozen prompts and artifact record; defaults to baseline directory')
    parser.add_argument('--candidate-resources', type=Path, help='Candidate frozen prompts and artifact record; defaults to candidate directory')
    args = parser.parse_args()
    baseline, base_meta, base_cases, base_hash, base_ids, base_order = load_run(args.baseline, args.baseline_resources or args.baseline)
    candidate, candidate_meta, candidate_cases, candidate_hash, candidate_ids, candidate_order = load_run(args.candidate, args.candidate_resources or args.candidate)
    require(base_order == candidate_order, "baseline and candidate trial order differs")
    require(base_ids.isdisjoint(candidate_ids), "baseline and candidate reuse run IDs")
    require({key: value for key, value in baseline.items() if key != "prompt_sha256"} == {
        key: value for key, value in candidate.items() if key != "prompt_sha256"}, "Evidence validation failed: {key: value for key, value in baseline.items() if key != 'prompt_sha256'} == {key: value for key, value in candidate.items() if key != 'prompt_sha256'}")
    require(base_meta["build"]["executable_sha256"] == candidate_meta["build"]["executable_sha256"], "Evidence validation failed: base_meta['build']['executable_sha256'] == candidate_meta['build']['executable_sha256']")
    changed = [name for name in baseline["prompt_sha256"] if baseline["prompt_sha256"][name] != candidate["prompt_sha256"][name]]
    require(changed == ["candle_appraiser_grade.md"], "only the reviewed Grade prompt may change")
    prompt_source = json.loads((args.candidate / "prompt-source.json").read_text())
    require(baseline["prompt_sha256"] == prompt_source["baseline_prompt_sha256"],
            "baseline prompt hashes disagree with declared original baseline")
    require(prompt_source["binary_commit"] == candidate["source_commit"], "Evidence validation failed: prompt_source['binary_commit'] == candidate['source_commit']")
    require(prompt_source["prompt_sha256"] == candidate["prompt_sha256"], "Evidence validation failed: prompt_source['prompt_sha256'] == candidate['prompt_sha256']")
    print(json.dumps({
        "scope": "Complete same-corpus measurements, not an acceptance or calibration verdict",
        "binary_commit": baseline["source_commit"], "prompt_commit": prompt_source["prompt_commit"],
        "runtime_config_verification": "declared_hash_only; private configuration bytes are not published",
        "runtime_id": baseline["runtime_id"], "calls_each": baseline["planned_calls"],
        "cases_sha256": baseline["cases_sha256"], "runtime_config_sha256": baseline["runtime_config_sha256"],
        "changed_prompt_files": changed,
        "baseline_results_sha256": base_hash, "candidate_results_sha256": candidate_hash,
        "calibration": baseline["calibration"],
        "cases": {case_id: {"baseline": base_cases[case_id], "candidate": candidate_cases[case_id]} for case_id in base_cases},
        "acceptance": "Operator thresholds are unset; no global PASS is inferred."
    }, indent=2))


if __name__ == "__main__":
    main()
