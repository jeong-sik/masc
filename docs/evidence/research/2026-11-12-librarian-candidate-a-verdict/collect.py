# pyright: strict
"""Copy the numbers of candidate A's verdict out of the run folders into this folder.

    python3 collect.py <artifacts/tinker/librarian> <this folder>

Writes
- verdict.json: the output of `eval_admission.py verdict`, as it was printed;
- runs.json: each run's summary, the training steps, the check of the rendered training examples,
  the sha256 of the files each run left, and the counts of the training split before and after its
  label audit;
- rows.jsonl: one row per request and target of the two verdict runs.

Rows keep counts, labels, memory IDs and item IDs. Candidate IDs and call keys are left out: E-real
rows list each candidate's [live outcome, target outcome] in the order of the candidate IDs, E-synth
rows already carry the counts. The checkpoint path and the budget a run was given are left out.
Stops when a value to write holds a `tinker://` path.
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path
from typing import cast

type JsonObject = dict[str, object]

CHECKPOINT = "tinker://"
LEFT_OUT = ("sampler_path", "budget_usd")
RUN_FILES = {
    "verdict-real": ("calls.jsonl", "rows.jsonl", "summary.json"),
    "verdict-synth": ("calls.jsonl", "rows.jsonl", "summary.json"),
    "verdict-drops": ("key.jsonl", "judge-files.json", "judge/decisions.jsonl"),
    "verdict-merges": ("key.jsonl", "judge-files.json", "run-files.json", "judge/decisions.jsonl"),
    "train-A": ("config.json", "steps.jsonl", "summary.json"),
    "teacher": ("calls.jsonl", "kept.jsonl", "pending.jsonl", "summary.json", "accepted-summary.json"),
}
ROW_LEFT_OUT = ("call_key", "error", "per_candidate")


def read_json(path: Path) -> JsonObject:
    return cast(JsonObject, json.loads(path.read_text(encoding="utf-8")))


def read_jsonl(path: Path) -> list[JsonObject]:
    return [cast(JsonObject, json.loads(line)) for line in path.read_text(encoding="utf-8").split("\n") if line]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def masked(value: object) -> object:
    """The value without the keys in LEFT_OUT, a checkpoint path replaced by the word for it."""
    if isinstance(value, dict):
        return {k: masked(v) for k, v in cast(JsonObject, value).items() if k not in LEFT_OUT}
    if isinstance(value, list):
        return [masked(v) for v in cast(list[object], value)]
    if isinstance(value, str) and value.startswith(CHECKPOINT):
        return "<checkpoint path>"
    return value


def row_of(row: JsonObject) -> JsonObject:
    """A verdict run's row without candidate IDs. E-real outcomes become a list of [live, target] in
    the order of the candidate IDs, so the two targets' rows of one item line up by position."""
    kept: JsonObject = {k: v for k, v in row.items() if k not in ROW_LEFT_OUT}
    if "outcomes" in row:
        kept["outcomes"] = [pair for _, pair in sorted(cast(dict[str, list[object]], row["outcomes"]).items())]
    return kept


def main() -> int:
    runs, out = Path(sys.argv[1]), Path(sys.argv[2])
    verdict = read_json(runs / "verdict.out")
    record: JsonObject = {}
    for name, files in RUN_FILES.items():
        folder = runs / name
        part: JsonObject = {"sha256": {f: sha256(folder / f) for f in files}}
        if "summary.json" in files:
            part["summary"] = masked(read_json(folder / "summary.json"))
        record[name] = part
    train = cast(JsonObject, record["train-A"])
    train["steps"] = read_jsonl(runs / "train-A" / "steps.jsonl")
    # What a local rendering of every training example showed before the run (no API call).
    train["examples_check"] = read_json(runs / "teacher-read" / "train-examples-check.json")
    cast(JsonObject, record["teacher"])["accepted"] = masked(read_json(runs / "teacher" / "accepted-summary.json"))
    record["train-split"] = {"sha256": {"requests.jsonl": sha256(runs / "train-audited" / "requests.jsonl")},
                             "kinds": read_json(runs / "train-audited" / "kind-counts.json")}
    rows = [row_of(r) for name in ("verdict-real", "verdict-synth") for r in read_jsonl(runs / name / "rows.jsonl")]
    texts = {
        "verdict.json": json.dumps(verdict, ensure_ascii=False, indent=1) + "\n",
        "runs.json": json.dumps(record, ensure_ascii=False, indent=1) + "\n",
        "rows.jsonl": "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows),
    }
    for name, text in texts.items():
        if CHECKPOINT in text:
            raise SystemExit(f"{name} would hold a checkpoint path")
    for name, text in texts.items():
        (out / name).write_text(text, encoding="utf-8")
    print(json.dumps({name: len(text) for name, text in texts.items()} | {"rows": len(rows)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
