# pyright: basic
"""Label-only screening table for the pass-time research runs (exp-time/PLAN.md). Numbers only.

    python3 time_screen.py --runs screen-runs.json [--root <runs folder>] [--out screen.json]

<screen-runs.json> lists runs: {"runs": [{"label": ..., "group": ..., "synth": <run dir>,
"merges": <merge_cases.py folder or null>}, ...], "contrasts": [[<group>, <against group>], ...]}.
Paths are relative to `--root` (default: the folder the file sits two levels under), or absolute.

Every count is summed over a run's rows as `eval_admission.summarize` sums it, so a rate here is
the rate of the run's summary.json. A group's counts are its runs' counts added up. A contrast
prints d = rate(group) - rate(against) and d/σ with σ = sqrt(p(1-p)(1/n1 + 1/n2)), p the pooled
rate, the formula of prompt_compare.py.

`big3` counts absorbs made by a claim that absorbs three or more memories. It reads the blind
merge judges' folder for the claim each absorb belongs to (cases.jsonl with key.jsonl) and never
their decisions. `answers>=10` counts the valid answers that absorb ten memories or more, and the
absorbs they hold. The last table line counts invalid answers by the problem kind their row names.
"""

from __future__ import annotations

import argparse
import collections
import json
import math
from pathlib import Path
from typing import Any

METRICS = ("valid", "ahead_keep", "past_drop", "stale_drop", "merge", "state", "drop_prec")
# An answer that absorbs this many memories or more is counted as a big answer.
BIG_ANSWER = 10


def counts_of(run: Path) -> dict[str, tuple[int, int]]:
    rows = [json.loads(line) for line in (run / "rows.jsonl").open(encoding="utf-8")]

    def total(key: str) -> int:
        return sum(int(r[key]) for r in rows)

    ahead, past = total("scheduled_ahead"), total("scheduled_past")
    big = [int(r["absorbed"]) for r in rows if r["valid"] and int(r["absorbed"]) >= BIG_ANSWER]
    return {
        "valid": (sum(bool(r["valid"]) for r in rows), len(rows)),
        "ahead_keep": (ahead - total("scheduled_ahead_dropped"), ahead),
        "past_drop": (total("scheduled_past_dropped"), past),
        "stale_drop": (total("planted_dropped"), total("planted")),
        "merge": (total("merges_done"), total("merges")),
        "state": (total("state_correct"), total("candidates")),
        "drop_prec": (total("dropped_expected"), total("dropped")),
        "absorbed": (total("absorbed"), 0),
        "big_answers": (len(big), 0),
        "big_answer_absorbs": (sum(big), 0),
        "off_label_drops": (sum(len(r["dropped_off_label"]) for r in rows), 0),
        "net": (total("added") - total("removed"), len(rows)),
    }


def invalid_kinds(run: Path) -> dict[str, int]:
    """How many invalid answers name each problem kind (the text before a problem's first colon)."""
    kinds: collections.Counter[str] = collections.Counter()
    for line in (run / "rows.jsonl").open(encoding="utf-8"):
        row = json.loads(line)
        if not row["valid"]:
            kinds.update({str(problem).split(":")[0] for problem in row["problems"]})
    return dict(sorted(kinds.items()))


def claim_sizes(merges: Path | None) -> dict[str, int] | None:
    """Absorbs by how many memories their claim absorbs: {"1": n, "2": n, "3+": n, "claims3+": n}."""
    if merges is None or not (merges / "key.jsonl").exists():
        return None
    cases = {}
    for line in (merges / "judge" / "cases.jsonl").open(encoding="utf-8"):
        case = json.loads(line)
        cases[case["case"]] = case
    groups: dict[tuple[str, str], int] = collections.Counter()
    for line in (merges / "key.jsonl").open(encoding="utf-8"):
        key = json.loads(line)
        for absorb in key["absorbs"]:
            groups[(absorb[0], cases[key["case"]]["proposed_memory"])] += 1
    out = {"1": 0, "2": 0, "3+": 0, "claims3+": 0}
    for size in groups.values():
        out["1" if size == 1 else "2" if size == 2 else "3+"] += size
        out["claims3+"] += size >= 3
    return out


def rate(pair: tuple[int, int]) -> float | None:
    return pair[0] / pair[1] if pair[1] else None


def sigma(a: tuple[int, int], b: tuple[int, int]) -> tuple[float, float] | None:
    if not a[1] or not b[1]:
        return None
    d = a[0] / a[1] - b[0] / b[1]
    p = (a[0] + b[0]) / (a[1] + b[1])
    s = math.sqrt(p * (1 - p) * (1 / a[1] + 1 / b[1]))
    return d, (d / s if s else math.inf if d else 0.0)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--runs", required=True)
    parser.add_argument("--root", default=None)
    parser.add_argument("--out", default=None)
    args = parser.parse_args()
    config_path = Path(args.runs).resolve()
    root = config_path.parent.parent if args.root is None else Path(args.root).resolve()
    config = json.loads(config_path.read_text(encoding="utf-8"))

    def at(value: str | None) -> Path | None:
        return None if value is None else (Path(value) if Path(value).is_absolute() else root / value)

    table: list[dict[str, Any]] = []
    groups: dict[str, dict[str, tuple[int, int]]] = {}
    for run in config["runs"]:
        synth = at(run["synth"])
        assert synth is not None
        counts = counts_of(synth)
        summary = json.loads((synth / "summary.json").read_text(encoding="utf-8"))
        sizes = claim_sizes(at(run.get("merges")))
        table.append({"label": run["label"], "group": run["group"], "template": summary["template_sha256"][:8],
                      "pass_lines": summary["pass_lines_sha256"][:8], "spent_usd": summary.get("spent_usd"),
                      "stopped": summary.get("stopped"), "counts": counts, "claim_sizes": sizes,
                      "invalid_kinds": invalid_kinds(synth)})
        held = groups.setdefault(run["group"], {})
        for name, pair in counts.items():
            before = held.get(name, (0, 0))
            held[name] = (before[0] + pair[0], before[1] + pair[1])
    head = ["run", "valid", "ahead_keep", "past_drop", "stale_drop", "merge", "state", "drop_prec", "absorbed",
            "big3", f"answers>={BIG_ANSWER}", "off_label", "net/item", "spent"]
    print(" | ".join(head))
    for row in table:
        c = row["counts"]
        sizes = row["claim_sizes"]
        cells = [str(row["label"])]
        for name in METRICS:
            pair = c[name]
            cells.append(f"{pair[0]}/{pair[1]}" + (f" {pair[0] / pair[1]:.2f}" if pair[1] else ""))
        cells += [str(c["absorbed"][0]), "-" if sizes is None else f"{sizes['3+']} ({sizes['claims3+']} claims)",
                  f"{c['big_answers'][0]} ({c['big_answer_absorbs'][0]} absorbs)", str(c["off_label_drops"][0]), f"{c['net'][0] / c['net'][1]:+.2f}", str(row["spent_usd"])]
        print(" | ".join(cells))
    kinds: collections.Counter[str] = collections.Counter()
    for row in table:
        kinds.update(row["invalid_kinds"])
    print("invalid answers by problem kind, all runs: " + ", ".join(f"{k} {n}" for k, n in sorted(kinds.items())))
    contrasts: list[dict[str, object]] = []
    for group, against in config.get("contrasts", []):
        if group not in groups or against not in groups:
            continue
        line: dict[str, object] = {"group": group, "against": against}
        parts = []
        for name in METRICS:
            found = sigma(groups[group][name], groups[against][name])
            if found is None:
                continue
            line[name] = {"d": round(found[0], 4), "sigmas": round(found[1], 2),
                          "group": list(groups[group][name]), "against": list(groups[against][name])}
            parts.append(f"{name} {found[0]:+.3f} ({found[1]:+.1f}σ)")
        contrasts.append(line)
        print(f"{group} vs {against}: " + ", ".join(parts))
    if args.out is not None:
        Path(args.out).write_text(json.dumps({"runs": table, "contrasts": contrasts}, ensure_ascii=False, indent=1)
                                  + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
