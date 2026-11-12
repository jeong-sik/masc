# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Answer synthetic requests pass_lines.json does not pin with the base model, for their blind label audit.

    uv run scripts/tinker/librarian/audit_baseline.py \
        --requests artifacts/tinker/librarian/synth-train/requests.jsonl \
        --out artifacts/tinker/librarian/train-base --budget 6

`eval_admission.py run --set synth` answers only the E-synth pass_lines.json
pins. An E-synth batch before its audit and the training split are not pinned,
and their audit reads the base model's answers too: `e_synth_audit.py cases
--run <out> --baseline <name>` shows the judge in full the facts each answer
touched, and tells apart the requests whose answer left its label. `<name>` is
`comparison.baseline` in pass_lines.json, and the model is its
`baseline_model`.

A request goes out as a measured run sends it (`eval_admission.run_item`): the
pinned template, the pass lines' effort and output budget, a warm call first.
The folder is not a measured run. It holds no rows.jsonl, and its summary.json
says `"set": "audit"`.

Output: <out>/calls.jsonl and <out>/summary.json.
"""

from __future__ import annotations

import argparse
import json
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import cast

import eval_admission as V
from tinker_oai import Caller

type JsonObject = dict[str, object]


def run(requests: Path, out: Path, budget: float) -> int:
    lines = V.load_pass_lines()
    request, comparison = cast(JsonObject, lines["request"]), cast(JsonObject, lines["comparison"])
    targets = [(cast(str, comparison["baseline"]), cast(str, comparison["baseline_model"]))]
    items: list[V.Item] = list(V.synth_items(requests))
    template, items = V.drawn_with(None, items)
    out.mkdir(parents=True, exist_ok=True)
    lane = V.TinkerLane(Caller(out / "calls.jsonl", budget), cast(str, request["reasoning_effort"]),
                        cast(int, request["max_tokens"]))

    def one(item: V.Item) -> list[JsonObject]:
        return V.run_item(lane, targets, item)

    with ThreadPoolExecutor(max_workers=V.in_flight(lane)) as pool:
        rows = [row for rows_of_item in pool.map(one, items) for row in rows_of_item]
    summary = {"set": "audit", "requests": len(items), "requests_sha256": V.sha256_file(requests),
               "pass_lines_sha256": V.sha256_file(V.PASS_LINES), "template_sha256": V.sha256_file(template),
               "targets": dict(targets), "answered": len(rows), "valid": sum(bool(row["valid"]) for row in rows),
               **V.spending(lane), "stopped": lane.caller.stopped}
    (out / "summary.json").write_text(json.dumps(summary, indent=1) + "\n", encoding="utf-8")
    print(json.dumps(summary))
    return 2 if lane.caller.stopped is not None else 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--requests", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--budget", type=float, required=True)
    args = ap.parse_args()
    return run(Path(cast(str, args.requests)), Path(cast(str, args.out)), cast(float, args.budget))


if __name__ == "__main__":
    sys.exit(main())
