"""Post-hoc breakdown of replay_addon_exact.py rows.

The cause buckets and the 57,344-token split below were chosen after the run,
so they are not pass lines. Reads one rows.jsonl; no network, no other input.

    python3 -I replay_addon_breakdown.py replay-addon-rows.jsonl
"""

import json
import sys
from collections import Counter
from pathlib import Path

WINDOW = 65536
MAX_TOKENS = 8192
# A prompt above this leaves less than MAX_TOKENS of the window for the answer.
FIT_LIMIT = WINDOW - MAX_TOKENS
PREFILL_PER_M = 0.30


def prompt_of(row):
    if row.get("window_refused"):
        return row["window_prompt_tokens"]
    return row.get("prompt_tokens")


def cause_of(row):
    if row.get("window_refused"):
        return "window_400"
    if row["status"] != 200:
        return "http_%s" % row["status"]
    s = row["score"]
    finish = row["finish_reason"]
    if finish == "length":
        if row["prompt_tokens"] + row["completion_tokens"] == WINDOW:
            return "window_clamped"
        if row["completion_tokens"] == MAX_TOKENS:
            return "max_tokens_truncated"
        return "length_other"
    if finish != "stop":
        return "finish_%s" % finish
    if row["json_form"] != "bare":
        return "not_bare_%s" % row["json_form"]
    if not s["schema_valid"]:
        return "schema_invalid"
    if row["output"] == "admission" and not s["candidates_covered"]:
        return "coverage_miss"
    return "valid"


def breakdown(sel):
    causes = Counter(cause_of(r) for r in sel)
    prompts = [p for p in (prompt_of(r) for r in sel) if p is not None]
    fit = [r for r in sel if prompt_of(r) is not None and prompt_of(r) <= FIT_LIMIT]
    valid = [r for r in sel if cause_of(r) == "valid"]
    counts = Counter()
    for r in valid:
        c = r["score"]["counts"]
        for k in ("new_claims", "dropped"):
            counts[k] += c[k]
            counts["ref_" + k] += c["ref_" + k]
        counts["zero_new_claims"] += c["new_claims"] == 0
        counts["ref_zero_new_claims"] += c["ref_new_claims"] == 0
    long_rows = [r for r in sel if cause_of(r) in ("window_400", "window_clamped")]
    long_prefill = sum(prompt_of(r) for r in long_rows)
    return {
        "n": len(sel),
        "causes": dict(causes),
        "prompt_over_window": sum(1 for p in prompts if p > WINDOW),
        "prompt_over_fit_limit_within_window": sum(1 for p in prompts if FIT_LIMIT < p <= WINDOW),
        "min_window_400_prompt": min((prompt_of(r) for r in sel if r.get("window_refused")), default=None),
        "max_prompt": max(prompts),
        "fit_rows": len(fit),
        "fit_valid": sum(1 for r in fit if cause_of(r) == "valid"),
        "fit_not_valid": [(r["key"][:8], cause_of(r)) for r in fit if cause_of(r) != "valid"],
        "valid_counts": dict(counts),
        "long_rows": len(long_rows),
        "long_prefill_tokens": long_prefill,
        "long_prefill_usd": round(long_prefill * PREFILL_PER_M / 1e6, 4),
    }


def main(path):
    rows = [json.loads(line) for line in Path(path).read_text().splitlines() if line]
    for output in ("admission", "durable"):
        sel = [r for r in rows if r["output"] == output]
        print(output, json.dumps(breakdown(sel), ensure_ascii=False))
    print("prompt_unknown", [(r["key"][:8], r["status"]) for r in rows if prompt_of(r) is None])


if __name__ == "__main__":
    main(sys.argv[1])
