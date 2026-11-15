# pyright: basic
"""Request-level view of the judged contrasts of the pass-time research runs. Numbers only.

    python3 time_cluster.py --runs judged-runs.json --draft F --baseline base [--root <runs folder>] \
        [--judged judged.json] [--out cluster.json]

prompt_compare.py divides a difference by a binomial σ, which treats every absorb or drop as its own
draw. One answer can make dozens of them, so this script resamples requests instead. Both sides
answered the same pinned requests, so a resample draws request IDs with replacement and takes each
side's rows of those requests (paired cluster bootstrap, 10,000 draws, fixed seed). For each metric
it prints both sides' counts, the difference of the rates, the 2.5th and 97.5th percentile of the
resampled difference and the share of draws where the draft's rate is lower.

Counts per request come from rows.jsonl (`dropped`, `dropped_expected`, `scheduled_ahead`,
`scheduled_ahead_dropped`, `absorbs`) and, for absorbs, the blind merge judge's key.jsonl and
judge/decisions.jsonl. An absorb the judge was not asked about (a planted stale fact) counts as not
mergeable, as merge_decisions.py counts it. The script stops when a side's totals differ from the
counts time_judged.py wrote to <judged.json> (`--judged`).
"""

from __future__ import annotations

import argparse
import collections
import json
import random
from pathlib import Path
from typing import Any

DRAWS = 10_000
SEED = 20261116
METRICS = ("absorb_precision", "drop_precision", "ahead_keep")


def lines(path: Path) -> list[dict[str, Any]]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]


def per_request(synth: Path, merges: Path | None) -> dict[str, dict[str, tuple[int, int]]]:
    mergeable: set[tuple[str, str]] = set()
    if merges is not None:
        decisions = {row["case"]: row["decision"] for row in lines(merges / "judge" / "decisions.jsonl")}
        for key in lines(merges / "key.jsonl"):
            if decisions[key["case"]] == "mergeable":
                mergeable.update((item, memory) for item, _target, memory in key["absorbs"])
    out: dict[str, dict[str, tuple[int, int]]] = {}
    for row in lines(synth / "rows.jsonl"):
        item = row["item"]
        absorbs = list(row["absorbs"])
        ahead = int(row["scheduled_ahead"])
        out[item] = {
            "absorb_precision": (sum((item, memory) in mergeable for memory in absorbs), len(absorbs)),
            "drop_precision": (int(row["dropped_expected"]), int(row["dropped"])),
            "ahead_keep": (ahead - int(row["scheduled_ahead_dropped"]), ahead),
        }
    return out


def rate(pairs: list[tuple[int, int]]) -> float | None:
    chances = sum(c for _, c in pairs)
    return sum(h for h, _ in pairs) / chances if chances else None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--runs", required=True)
    parser.add_argument("--root", default=None)
    parser.add_argument("--draft", required=True)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--judged", default=None)
    parser.add_argument("--out", default=None)
    args = parser.parse_args()
    config_path = Path(args.runs).resolve()
    root = config_path.parent.parent if args.root is None else Path(args.root).resolve()
    config = json.loads(config_path.read_text(encoding="utf-8"))

    def at(value: str | None) -> Path | None:
        return None if value is None else (Path(value) if Path(value).is_absolute() else root / value)

    def side(label: str) -> list[dict[str, dict[str, tuple[int, int]]]]:
        runs = {**config.get("baseline", {}), **config.get("drafts", {})}[label]
        listed = []
        for run in runs:
            synth = at(run["synth"])
            assert synth is not None
            listed.append(per_request(synth, at(run.get("merges"))))
        return listed

    sides = {"draft": side(args.draft), "baseline": side(args.baseline)}
    items = sorted(sides["draft"][0])
    for runs in sides.values():
        for run in runs:
            if sorted(run) != items:
                raise SystemExit("the runs did not answer the same requests")
    judged = None if args.judged is None else json.loads(Path(args.judged).read_text(encoding="utf-8"))["sides"]
    rng = random.Random(SEED)
    draws = [[rng.choice(items) for _ in items] for _ in range(DRAWS)]
    report: dict[str, Any] = {"draft": args.draft, "baseline": args.baseline, "requests": len(items),
                              "draws": DRAWS, "seed": SEED, "metrics": {}}
    for metric in METRICS:
        totals = {name: (sum(run[i][metric][0] for run in runs for i in items),
                         sum(run[i][metric][1] for run in runs for i in items)) for name, runs in sides.items()}
        if judged is not None and metric in judged[args.draft]:
            for name, label in (("draft", args.draft), ("baseline", args.baseline)):
                if tuple(judged[label][metric]) != totals[name]:
                    raise SystemExit(f"{label} {metric}: counted {totals[name]}, judged.json has {judged[label][metric]}")
        diffs = []
        undefined = 0
        for draw in draws:
            d = rate([run[i][metric] for run in sides["draft"] for i in draw])
            b = rate([run[i][metric] for run in sides["baseline"] for i in draw])
            if d is None or b is None:
                undefined += 1
                continue
            diffs.append(d - b)
        diffs.sort()
        low, high = diffs[int(0.025 * len(diffs))], diffs[int(0.975 * len(diffs)) - 1]
        lower = sum(d < 0 for d in diffs) / len(diffs)
        point = totals["draft"][0] / totals["draft"][1] - totals["baseline"][0] / totals["baseline"][1]
        holders = collections.Counter({i: sum(run[i][metric][1] for run in sides["draft"]) for i in items})
        top_item, top = holders.most_common(1)[0]
        report["metrics"][metric] = {
            "draft": list(totals["draft"]), "baseline": list(totals["baseline"]), "d": round(point, 4),
            "low": round(low, 4), "high": round(high, 4), "draft_lower_share": round(lower, 4),
            "undefined_draws": undefined, "largest_request": top_item, "largest_request_chances": top,
        }
        print(f"{metric}: draft {totals['draft'][0]}/{totals['draft'][1]} baseline "
              f"{totals['baseline'][0]}/{totals['baseline'][1]} d {point:+.3f} "
              f"[{low:+.3f}, {high:+.3f}] draft lower in {lower:.1%} of draws; "
              f"largest request holds {top} of the draft's {totals['draft'][1]}")
    if args.out is not None:
        Path(args.out).write_text(json.dumps(report, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
