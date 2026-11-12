# pyright: strict
"""Invented rows, runs, counts and pinned lines for the tests of the prompt comparison
(`prompt_counts.py`, `prompt_lines.py`, `prompt_compare.py`).

`prompt_counts` imports `eval_admission`, which imports the Tinker caller, which imports openai, so
a test that uses this file runs with `uv run`.
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

import prompt_counts as C
import prompt_lines as L

type Row = dict[str, object]


def sha(text: str) -> str:
    """A sha256 digest that stands for the file `text` names."""
    return hashlib.sha256(text.encode()).hexdigest()


PIN = sha("pass lines")
BASE_T, DRAFT_T, OTHER_T = sha("base template"), sha("draft template"), sha("other template")
FILES = {name: sha(name) for name in L.PINNED_FILES}
RECORD = C.RealRecord(1, 2, 0)


def synth_row(item: str, **counts: object) -> Row:
    base: Row = {"target": "base", "item": item, "call_key": f"key-{item}", "sent_at": 1.0,
                 "status": 200, "wall_s": 1.0, "valid": True, "cost_usd": 0.0,
                 "prompt_tokens": 1, "cached_tokens": 1, "candidates": 2, "correct": 2, "dropped": 0,
                 "absorbed": 0, "dropped_expected": 0, "planted": 1, "planted_dropped": 0, "state_correct": 2,
                 "state_by_kind": {"new": [2, 2]}, "dropped_unmerged": [], "planted_absorbed": 0,
                 "scheduled_ahead": 0, "scheduled_ahead_dropped": 0, "scheduled_past": 0, "scheduled_past_dropped": 0,
                 "merges": 0, "merges_done": 0, "added": 0, "removed": 0, "expected_added": 0, "expected_removed": 0,
                 "dropped_off_label": [], "absorbs": {}, "merges_absorbed": []}
    return {**base, **counts}


def real_row(item: str, **counts: object) -> Row:
    base: Row = {"target": "base", "item": item, "call_key": f"key-{item}", "sent_at": 2.0,
                 "status": 200, "wall_s": 1.0, "valid": True, "cost_usd": 0.0,
                 "prompt_tokens": 1, "cached_tokens": 1, "candidates": 2, "agree": 1,
                 "dropped_not_in_live": [], "absorbed_not_in_live": [], "added": 0, "removed": 0,
                 "live_added": 0, "live_removed": 0}
    return {**base, **counts}


def write_run(root: Path, name: str, kind: str, rows: list[Row], **summary: object) -> Path:
    """A finished run's folder under `root`: its rows, and the summary of a Tinker run under PIN that
    sent inkling-model as `base` and drew its prompts with DRAFT_T, but for what `summary` names."""
    run = root / name
    run.mkdir()
    (run / "rows.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")
    body = {"set": kind, "pass_lines_sha256": PIN, "template_sha256": DRAFT_T, "provider": "tinker",
            "targets": {"base": "inkling-model"}, "stopped": None, **summary}
    (run / "summary.json").write_text(json.dumps(body), encoding="utf-8")
    return run


def counts(hits: dict[str, tuple[int, int]]) -> dict[C.Metric, C.Count]:
    """Every metric at 5 of 10, but those named."""
    out = {m: C.Count(5, 10) for m in C.Metric}
    out.update({C.Metric(k): C.Count(*v) for k, v in hits.items()})
    return out


def measured(template: str, run: str = "run", hits: dict[str, tuple[int, int]] | None = None,
             answered: frozenset[tuple[str, float]] = frozenset(), record: C.RealRecord = RECORD) -> C.Measured:
    """What the run named `run` counted: `counts(hits)`, drawn with `template`."""
    return C.Measured(counts(hits or {}), template, sha(f"{run} synth"), sha(f"{run} real"), record, answered)


def baseline(*runs: str) -> L.Baseline:
    """The pinned baseline of the runs named `runs`, each counting every metric at 5 of 10."""
    return L.Baseline(PIN, BASE_T, FILES[L.COUNTS], {m: C.Count(5 * len(runs), 10 * len(runs)) for m in C.Metric},
                      tuple(RECORD for _ in runs), tuple(sha(f"{r} synth") for r in runs),
                      tuple(sha(f"{r} real") for r in runs))


INKLING = L.ModelLines("tinker", "inkling-model", 2, baseline("i1", "i2"))
GLM = L.ModelLines("glm", "glm-model", 1, baseline("g1"))
LINES = L.Lines(PIN, BASE_T, FILES, 2.5, 2.0, frozenset({"inkling"}), {"inkling": INKLING, "glm": GLM})
