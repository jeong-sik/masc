#!/usr/bin/env python3
"""Prepare an isolated appraiser evaluation, or report its measured responses.

Preparation and reporting make no provider calls. Execute the CI-built
candle_appraiser_eval_cli separately, with --execute, inside this workspace.
"""
from __future__ import annotations

import argparse
from collections import Counter
import copy
import hashlib
import json
import math
import os
from pathlib import Path
import statistics
import tomllib

ROOT = Path(__file__).resolve().parent.parent
SCHEMA = "masc.candle_appraiser_eval.v1"
PROMPTS = [f"candle_appraiser_{stage}.md" for stage in ("grade", "relation", "weights")]
GRADES = ["trivial", "small", "medium", "large", "epic"]


def digest(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def dump(path: Path, value) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def toml_document(value: dict) -> str:
    lines = []

    def table(data, keys):
        if keys:
            lines.append("[" + ".".join(json.dumps(k) for k in keys) + "]")
        for key, item in data.items():
            if not isinstance(item, dict):
                lines.append(json.dumps(key) + " = " + json.dumps(item, ensure_ascii=False))
        lines.append("")
        for key, item in data.items():
            if isinstance(item, dict):
                table(item, [*keys, key])

    table(value, [])
    text = "\n".join(lines)
    if tomllib.loads(text) != value:
        raise ValueError("selected runtime did not round-trip as TOML")
    return text


def prepare(args) -> dict:
    if args.trials < 1 or args.max_output_tokens < 1:
        raise ValueError("trials and max-output-tokens must be positive")
    if not math.isfinite(args.exact_body_timeout_s) or args.exact_body_timeout_s <= 0:
        raise ValueError("exact-body-timeout-s must be finite and positive")
    if len(args.source_commit) != 40 or any(c not in "0123456789abcdef" for c in args.source_commit):
        raise ValueError("source-commit must be the exact 40-character CI source SHA")
    source = tomllib.loads(args.source_runtime.read_text())
    matches = [(p, m) for p in source["providers"] for m in source.get(p, {})
               if f"{p}.{m}" == args.runtime and m in source["models"]]
    if len(matches) != 1:
        raise ValueError("runtime must name exactly one existing provider/model binding")
    provider_id, model_id = matches[0]
    provider = copy.deepcopy(source["providers"][provider_id])
    # This first probe deliberately covers HTTP, with exactly one declared slot.
    # No subscription login files or extra provider credentials are copied.
    if provider.get("protocol") != "openai-compatible-http":
        raise ValueError("this isolated probe currently requires an openai-compatible-http slot")
    credentials = provider.get("credentials", {})
    if credentials.get("type") != "env" or not isinstance(credentials.get("key"), str):
        raise ValueError("selected provider must use an environment credential reference")
    credential_env = credentials["key"]
    if not os.environ.get(credential_env):
        raise ValueError("selected provider credential environment variable is unavailable")
    prior_body_timeout = provider.get("exact-body-timeout-s")
    provider["exact-body-timeout-s"] = args.exact_body_timeout_s
    selected = {
        "runtime": {"default": args.runtime, "exact_output_lanes": {
            "candle_appraiser": {"slots": [args.runtime], "cli_slots": [],
                                 "max_output_tokens": args.max_output_tokens}}},
        "providers": {provider_id: provider},
        "models": {model_id: source["models"][model_id]},
        provider_id: {model_id: source[provider_id][model_id]},
    }
    runtime_text = toml_document(selected)
    cases_raw = args.cases.read_bytes()
    cases = json.loads(cases_raw)
    ids = [case["id"] for case in cases]
    if not ids or len(ids) != len(set(ids)):
        raise ValueError("case ids must be nonempty and unique")
    prompt_bytes = {name: (args.prompt_dir / name).read_bytes() for name in PROMPTS}
    # Refuse reuse, including any existing live base. Nothing above writes.
    args.workspace.mkdir(mode=0o700, parents=False, exist_ok=False)
    config = args.workspace / ".masc" / "config"
    config.mkdir(parents=True, mode=0o700)
    runtime_path = config / "runtime.toml"
    runtime_path.write_text(runtime_text)
    runtime_path.chmod(0o600)
    (args.workspace / "cases.json").write_bytes(cases_raw)
    prompts = args.workspace / "prompts"
    prompts.mkdir(mode=0o700)
    for name, raw in prompt_bytes.items():
        (prompts / name).write_bytes(raw)
    plan = {
        "schema": SCHEMA, "source_commit": args.source_commit,
        "runtime_id": args.runtime, "credential_env": credential_env,
        "trials": args.trials, "case_count": len(cases),
        "planned_calls": args.trials * len(cases),
        "runtime_config_sha256": digest(runtime_path.read_bytes()),
        "cases_sha256": digest(cases_raw),
        "prompt_sha256": {name: digest(raw) for name, raw in prompt_bytes.items()},
        "evaluation_overrides": {"exact-body-timeout-s": args.exact_body_timeout_s,
                                 "source-exact-body-timeout-s": prior_body_timeout,
                                 "max-output-tokens": args.max_output_tokens},
        "calibration": {"status": "not_performed", "reason": "No human-graded set of 20 Goals is supplied"},
        "scope": "Synthetic isolated stage judgments; no Goal, Task, Candle ledger or Paid mutations",
    }
    dump(args.workspace / "plan.json", plan)
    return plan


def modes(counter: Counter) -> list:
    return sorted(k for k, n in counter.items() if n == max(counter.values())) if counter else []


def report(workspace: Path, evidence_path: Path | None = None) -> dict:
    plan = json.loads((workspace / "plan.json").read_text())
    if plan["schema"] != SCHEMA:
        raise ValueError("unknown evaluation schema")
    raw = (workspace / "cases.json").read_bytes()
    if digest(raw) != plan["cases_sha256"]:
        raise ValueError("case corpus changed after preparation")
    cases = {case["id"]: case for case in json.loads(raw)}
    groups = {key: [] for key in cases}
    seen = set()
    run_ids = set()
    path = (evidence_path or workspace / "evidence") / "results.jsonl"
    for line in path.read_text().splitlines():
        row = json.loads(line)
        case_id, trial = row["case_id"], row["trial"]
        if case_id not in cases or type(trial) is not int or not 1 <= trial <= plan["trials"]:
            raise ValueError("result does not belong to the planned corpus/trials")
        if (case_id, trial) in seen:
            raise ValueError("duplicate case/trial result must not inflate measurements")
        seen.add((case_id, trial))
        if row["stage"] != cases[case_id]["stage"] or row["status"] not in {
            "ok", "invalid_response", "transport_unavailable"
        }:
            raise ValueError("result stage or status is invalid")
        if not isinstance(row["receipt"], dict) or not row["receipt"].get("run_id"):
            raise ValueError("result must retain the production exact run receipt")
        run_id = row["receipt"]["run_id"]
        if run_id in run_ids:
            raise ValueError("duplicate exact run receipt must not count as another trial")
        run_ids.add(run_id)
        groups[case_id].append(row)
    summaries = {}
    for case_id, rows in groups.items():
        case = cases[case_id]
        accepted = [row["answer"] for row in rows if row["status"] == "ok"]
        counts = Counter(row["status"] for row in rows)
        summary = {"observed": len(rows), "planned": plan["trials"],
                   "missing": plan["trials"] - len(rows), "statuses": dict(counts)}
        if case["stage"] in {"grade", "relation"}:
            key = case["stage"]
            tally = Counter(answer[key] for answer in accepted)
            summary.update({"answers": dict(tally), "modes": modes(tally)})
            if case["relation_expectation"] is not None:
                summary["expected_matches"] = tally[case["relation_expectation"]]
                summary["expectation"] = case["relation_expectation"]
        else:
            shares = {keeper: [] for keeper in case["input"]["keepers"]}
            for answer in accepted:
                weights = answer["weights"]
                total = sum(weights.values())
                for keeper in shares:
                    shares[keeper].append(weights[keeper] / total)
            summary["shares"] = {keeper: {"samples": len(values),
                "mean": statistics.mean(values) if values else None,
                "min": min(values) if values else None,
                "max": max(values) if values else None} for keeper, values in shares.items()}
        summaries[case_id] = summary
    comparisons = []
    for case_id, case in cases.items():
        compare = case["comparison"]
        if compare is None:
            continue
        baseline = summaries[compare["baseline"]]
        candidate = summaries[case_id]
        row = {"case_id": case_id, **compare,
               "baseline_invalid_responses": baseline["statuses"].get("invalid_response", 0),
               "candidate_invalid_responses": candidate["statuses"].get("invalid_response", 0),
               "complete_pair": baseline["missing"] == candidate["missing"] == 0}
        if case["stage"] in {"grade", "relation"}:
            a, b = baseline["modes"], candidate["modes"]
            row.update({"baseline_modes": a, "candidate_modes": b,
                        "unique_mode_unchanged": a == b if len(a) == len(b) == 1 else None})
            if case["stage"] == "grade":
                row["unique_mode_increased"] = GRADES.index(b[0]) > GRADES.index(a[0]) if len(a) == len(b) == 1 else None
        else:
            a = baseline["shares"][compare["baseline_keeper"]]["mean"]
            b = candidate["shares"][compare["candidate_keeper"]]["mean"]
            row.update({"baseline_mean_share": a, "candidate_mean_share": b,
                        "mean_share_delta": b-a if a is not None and b is not None else None})
        comparisons.append(row)
    return {"schema": SCHEMA, "source_commit": plan["source_commit"],
            "runtime_id": plan["runtime_id"], "observed_calls": len(seen),
            "planned_calls": plan["planned_calls"], "complete": len(seen) == plan["planned_calls"],
            "calibration": plan["calibration"], "cases": summaries, "comparisons": comparisons,
            "acceptance": "Measurements only. RFC proposal thresholds need operator adoption; no global PASS is inferred."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prep = commands.add_parser("prepare")
    prep.add_argument("--source-runtime", type=Path, required=True)
    prep.add_argument("--runtime", required=True)
    prep.add_argument("--workspace", type=Path, required=True)
    prep.add_argument("--source-commit", required=True)
    prep.add_argument("--max-output-tokens", type=int, required=True)
    prep.add_argument("--exact-body-timeout-s", type=float, required=True)
    # RFC-goal-candle-ledger section 5: 20 repetitions of identical input.
    prep.add_argument("--trials", type=int, default=20)
    prep.add_argument("--cases", type=Path, default=ROOT / "test/fixtures/candle_appraiser_eval_cases.json")
    prep.add_argument("--prompt-dir", type=Path, default=ROOT / "config/prompts")
    summary = commands.add_parser("report")
    summary.add_argument("--workspace", type=Path, required=True)
    summary.add_argument("--evidence-path", type=Path)
    args = parser.parse_args()
    value = prepare(args) if args.command == "prepare" else report(args.workspace, args.evidence_path)
    if args.command == "report":
        dump((args.evidence_path or args.workspace / "evidence") / "report.json", value)
    print(json.dumps(value, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
