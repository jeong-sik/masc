# pyright: strict
"""What one run of the pinned sets counts for a prompt comparison (RFC-0517 §2.3).

`prompt_compare.py` compares these counts. A run is an E-synth run, an E-real run and the blind
judges' folders of the E-synth run (`e_synth_audit.py drops`, `merge_cases.py`), None when the run
has no off-label drop or no absorb. `measure` counts each metric as hits over chances from the rows
and the judges' decisions, as `eval_admission.measure_synth` does, and reads no number from
summary.json. The summary says what the run was: its set, pass lines, provider and template, whether
it stopped, and the name it sent the model under, which picks the model's rows in a folder that
holds another target's rows too.

A baseline in prompt_lines.json is such counts kept as numbers. It names the sha256 of this file,
so a change here leaves every pinned baseline stale until its runs are counted again. The sha256 of
a run's rows that a baseline keeps says which rows files the counts came from. The judges'
decisions are not kept, so the pinned counts are the record.
"""

from __future__ import annotations

import hashlib
import json
from collections.abc import Mapping
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from typing import cast

import audit_decisions as D
import eval_admission as V
import merge_decisions as MD
import synth_render

type JsonObject = dict[str, object]

RUN_KEYS = frozenset({"synth", "real", "drops", "merges"})


class Metric(StrEnum):
    SYNTH_VALID = "synth_valid_rate"
    REAL_VALID = "real_valid_rate"
    MEMORY_STATE = "memory_state_accuracy"
    STALE_RECALL = "stale_drop_recall"
    MERGE_RECALL = "judged_merge_recall"
    DROP_PRECISION = "drop_precision"
    ABSORB_PRECISION = "absorb_precision"


@dataclass(frozen=True, slots=True)
class Count:
    hits: int
    chances: int

    def __add__(self, other: Count) -> Count:
        return Count(self.hits + other.hits, self.chances + other.chances)


@dataclass(frozen=True, slots=True)
class RealRecord:
    """Recorded, not judged: outcome agreement with the live answer over a run's valid E-real answers,
    and the memories they drop that the live answer kept."""

    agree: int
    candidates: int
    dropped_not_in_live: int


@dataclass(frozen=True, slots=True)
class Run:
    synth: Path
    real: Path
    drops: Path | None
    merges: Path | None


@dataclass(frozen=True, slots=True)
class Measured:
    """One run's counts for the model's target, the template it drew its prompts with, its rows'
    sha256, its E-real record, and the answered calls it counts. A call is its key and the time it
    was sent: two runs of one prompt share keys, never a sent call."""

    counts: Mapping[Metric, Count]
    template_sha256: str
    synth_rows_sha256: str
    real_rows_sha256: str
    real_record: RealRecord
    answered: frozenset[tuple[str, float]]


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def total(key: str, rows: list[JsonObject]) -> int:
    return sum(cast(int, r[key]) for r in rows)


def synth_counts(scored: list[JsonObject], wrong_outside: int, merges: JsonObject) -> dict[Metric, Count]:
    """One target's E-synth counts over its scored rows, with the wrong drops on rows left out of
    scoring, as `eval_admission.summarize` and `merge_decisions.MergeAdjudication.numbers` rate them."""
    return {
        Metric.SYNTH_VALID: Count(sum(bool(r["valid"]) for r in scored), len(scored)),
        Metric.MEMORY_STATE: Count(total("state_correct", scored), total("candidates", scored)),
        Metric.STALE_RECALL: Count(total("planted_dropped", scored), total("planted", scored)),
        Metric.DROP_PRECISION: Count(total("dropped_expected", scored), total("dropped", scored) + wrong_outside),
        Metric.ABSORB_PRECISION: Count(cast(int, merges["absorbs_mergeable"]), cast(int, merges["absorbs"])),
        Metric.MERGE_RECALL: Count(cast(int, merges["merges_mergeable"]), cast(int, merges["merges"])),
    }


def real_record(rows: list[JsonObject]) -> RealRecord:
    """The E-real record of one target's rows, over its valid answers."""
    valid = [r for r in rows if r["valid"]]
    return RealRecord(total("agree", valid), total("candidates", valid),
                      sum(len(cast(list[str], r["dropped_not_in_live"])) for r in valid))


def target_of(summary: JsonObject, kind: str, pin: str, provider: str, model: str, where: Path) -> str:
    """The name the run sent `model` under. SystemExit unless the run is a finished `kind` run under
    the pass lines `pin`, on `provider`, sending the model under one name."""
    names = [n for n, m in cast(dict[str, str], summary["targets"]).items() if m == model]
    if (summary["set"], summary["pass_lines_sha256"], summary["provider"]) != (kind, pin, provider):
        raise SystemExit(f"{where} is not an E-{kind} run on {provider} under the pinned pass lines")
    if summary["stopped"] is not None or len(names) != 1:
        raise SystemExit(f"{where} stopped before its last item or does not send {model} under one name")
    return names[0]


def measure(run: Run, *, provider: str, model: str, pin: str, items: tuple[int, int]) -> Measured:
    """`run`'s counts for `model` on `provider`, recomputed from its rows and its judges' folders.
    `items` are the sizes of E-synth and E-real: a run that does not hold that many rows for the
    model is refused."""
    synth_summary = cast(JsonObject, json.loads((run.synth / "summary.json").read_text(encoding="utf-8")))
    real_summary = cast(JsonObject, json.loads((run.real / "summary.json").read_text(encoding="utf-8")))
    target = target_of(synth_summary, "synth", pin, provider, model, run.synth)
    real_target = target_of(real_summary, "real", pin, provider, model, run.real)
    if synth_summary["template_sha256"] != real_summary["template_sha256"]:
        raise SystemExit(f"{run.synth} and {run.real} drew their prompts with different templates")
    rows = V.read_rows(run.synth)
    if sum(r["target"] == target for r in rows) != items[0]:
        raise SystemExit(f"{run.synth} does not hold one row for each of the {items[0]} E-synth items")
    off = D.off_label(rows)
    if off and run.drops is None:
        raise SystemExit(f"{run.synth} has off-label drops and no drop judge's folder")
    judged = D.read_adjudication(run.drops, off, synth_render.TEMPLATE) if off and run.drops else D.NO_DROPS
    scored = judged.scored(rows)
    mine = [r for r in scored if r["target"] == target]
    if not mine:
        raise SystemExit(f"the judge's drops leave none of {run.synth} to score")
    merges = MD.for_run(rows, run.merges, synth_render.TEMPLATE, run.synth).numbers(rows, scored, target)
    counts = synth_counts(mine, judged.wrong_outside(rows).get(target, 0), merges)
    real_rows = [r for r in V.read_rows(run.real) if r["target"] == real_target]
    if len(real_rows) != items[1]:
        raise SystemExit(f"{run.real} does not hold one row for each of the {items[1]} E-real items")
    counts[Metric.REAL_VALID] = Count(sum(bool(r["valid"]) for r in real_rows), len(real_rows))
    answered = frozenset((cast(str, r["call_key"]), cast(float, r["sent_at"]))
                         for r in [*(r for r in rows if r["target"] == target), *real_rows])
    return Measured(counts, cast(str, synth_summary["template_sha256"]), sha256_file(run.synth / "rows.jsonl"),
                    sha256_file(run.real / "rows.jsonl"), real_record(real_rows), answered)


def summed(side: list[Measured]) -> dict[Metric, Count]:
    out: dict[Metric, Count] = {}
    for measured in side:
        for metric, count in measured.counts.items():
            out[metric] = out.get(metric, Count(0, 0)) + count
    return out


def run_of(raw: object) -> Run:
    """One run as runs.json lists it: its `synth` and `real` folders and its judges' `drops` and
    `merges` folders, each of the two null or left out when the run has none. SystemExit when it is
    anything else."""
    held = cast(dict[str, object], raw) if isinstance(raw, dict) else {}
    synth, real, drops, merges = held.get("synth"), held.get("real"), held.get("drops"), held.get("merges")
    if (not isinstance(synth, str) or not isinstance(real, str) or not isinstance(drops, str | None)
            or not isinstance(merges, str | None) or not set(held) <= RUN_KEYS):
        raise SystemExit("runs.json: a run names its synth and real folders, and its drops and merges folders or null")
    return Run(Path(synth), Path(real), None if drops is None else Path(drops),
               None if merges is None else Path(merges))
