#!/usr/bin/env python3
"""Replay the frozen synthetic experiment; never reads Keeper runtime data."""
import argparse
import base64
import concurrent.futures
import hashlib
import json
import math
import os
from pathlib import Path
import sys
import urllib.error
import urllib.request


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON object key: " + key)
        result[key] = value
    return result


def choice_decision(answer, options):
    """Match Typesafeai_types.decode_choice before scoring a provider answer."""
    if not isinstance(answer, dict) or answer.get("type") != "choice":
        raise ValueError("expected a choice answer")
    probabilities = answer.get("probabilities")
    if not isinstance(probabilities, dict) or set(probabilities) != set(options):
        raise ValueError("probabilities must cover each declared option exactly once")

    def unit_probability(value):
        return (type(value) in (int, float) and 0 <= value <= 1
                and math.isfinite(value))

    if not unit_probability(answer.get("confidence")) or not all(
            unit_probability(value) for value in probabilities.values()):
        raise ValueError("probabilities and confidence must be finite values from zero to one")
    # Use the same sequential IEEE-754 addition and tolerance as the OCaml decoder.
    total = 0.0
    for probability in probabilities.values():
        total += probability
    if abs(total - 1.0) > sys.float_info.epsilon * len(probabilities):
        raise ValueError("probabilities must sum to one")
    decision = answer.get("choice")
    if not isinstance(decision, str) or decision not in probabilities:
        raise ValueError("choice must name a declared option")
    if any(probabilities[decision] < value for value in probabilities.values()):
        raise ValueError("choice must have a highest probability")
    return decision


def retain_response(row, raw):
    # Keep exact bytes before parsing, including malformed JSON and duplicate keys.
    row["response_raw_base64"] = base64.b64encode(raw).decode("ascii")
    row["response_sha256"] = hashlib.sha256(raw).hexdigest()


def request_body(policy, case, arm):
    state = {"source_memory": case["source_memory"],
             "proposed_memory": case["proposed_memory"]}
    if arm != "pair_only":
        state["new_observations"] = (
            case["new_observations"] if arm == "with_evidence" else [])
    return {"model": policy["model"], "state": state,
            "questions": policy["arms"][arm]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--execute", action="store_true",
                        help="Make paid Jev calls using TYPESAFEAI_API_KEY")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.repeats < 1:
        parser.error("--repeats must be positive")
    root = Path(__file__).resolve().parent
    policy = json.loads((root / "policy.json").read_text())
    cases = json.loads((root / "cases.json").read_text())
    key = os.environ.get("TYPESAFEAI_API_KEY")
    if args.execute and not key:
        parser.error("TYPESAFEAI_API_KEY is required for --execute")

    def run(job):
        case, arm, repeat = job
        body = request_body(policy, case, arm)
        encoded = json.dumps(body).encode()
        row = {"case": case["id"], "mode": arm, "repeat": repeat,
               "expected": case["expected_mergeable"],
               "request_sha256": hashlib.sha256(encoded).hexdigest()}
        if not args.execute:
            return {**row, "request": body}
        request = urllib.request.Request(
            "https://api.typesafe.ai/v1/systemone", data=encoded,
            headers={"Authorization": "Bearer " + key,
                     "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                raw = response.read()
            retain_response(row, raw)
            row["response"] = json.loads(raw, object_pairs_hook=unique_object)
            decision = choice_decision(
                row["response"]["answers"]["s0_0"],
                body["questions"]["s0_0"]["criteria"])
            row["decision"] = decision
            row["matches_expected"] = (
                (decision == "mergeable") == row["expected"])
        except urllib.error.HTTPError as error:
            with error:
                retain_response(row, error.read())
            row["error"] = type(error).__name__
            row["http_status"] = error.code
        except (urllib.error.URLError, TimeoutError, ValueError, KeyError,
                TypeError) as error:
            row["error"] = type(error).__name__
        return row

    jobs = [(case, arm, repeat) for case in cases
            for arm in policy["arms"] for repeat in range(args.repeats)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        rows = list(pool.map(run, jobs))
    args.output.write_text(json.dumps(rows, ensure_ascii=False, indent=2) + "\n")
    for arm in policy["arms"]:
        selected = [r for r in rows if r["mode"] == arm]
        print(arm, {"requests": len(selected),
                    "errors": sum("error" in r for r in selected),
                    "matched": sum(r.get("matches_expected", False) for r in selected)
                    if args.execute else None})


if __name__ == "__main__":
    main()
