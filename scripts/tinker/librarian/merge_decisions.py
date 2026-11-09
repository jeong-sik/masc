# pyright: strict
"""Read a judge's decisions on the memories E-synth answers absorb, for the verdict.

Before MASC applies an answer that absorbs a memory into a claim, its absorb
gate asks a judgment model whether that memory can retire into the claim
(keeper_librarian_absorb_gate.mli). The model reads the memory, the claim and
the observations the claim cites, and picks one of four classes that
config/prompts/librarian.md words in its `absorb_*` slots. Only `mergeable`
lets the memory go. `merge_cases.py` puts the same question, in the same
words, to a judge that sees no label, target or request.

The judge gets no case for an absorbed planted stale fact. The label plants it
as a transient state that no candidate continues: no candidate targets it
(`synth_rows.holds`), and a new candidate is written as knowledge its memory
lacks (`synth_prompts.TASK_NEW`). librarian.md 133-136 has such a state leave
by `dropped`; 136-138 lets a record absorb an earlier state only when it tells
how that event went on to now. So the label alone makes the absorb wrong.
Every other absorb stands in exactly one case, and every case gets one class.

A case shows the claims of one run's answers, so its class holds for that run
only. `merge_cases.py` writes the sha256 of the run's call log and rows beside
the key (RUN_FILES), and `for_run` reads no decision for other run files.

From the classes the verdict reports, per target:
- absorb precision: absorbs judged `mergeable` over every absorb its valid
  answers make, planted stale facts included (1.0 with no absorbs). It counts
  the rows the drop judge leaves out of scoring too: a class does not depend
  on the label, and a planted stale fact is stale by construction.
- judged merge recall: merges the label expects (a complement target into the
  complement's claim, a duplicate pair left as one fact) that the answer made
  with every absorb judged `mergeable`, over the merges the labels expect, on
  the rows the verdict scores.

The judge's folder works as the drop judge's does (`audit_decisions`).
"""

from __future__ import annotations

import json
from collections.abc import Mapping
from dataclasses import dataclass, replace
from pathlib import Path
from types import MappingProxyType
from typing import Literal, cast

import audit_decisions as D

type JsonObject = dict[str, object]
type Consolidation = Literal["mergeable", "different_context", "loses_knowledge", "uncertain"]
# keeper_librarian_absorb_gate.ml `consolidation_label`, in its order.
CONSOLIDATIONS: tuple[Consolidation, ...] = ("mergeable", "different_context", "loses_knowledge", "uncertain")
# (item, target, memory ID): a memory one target's answer absorbed on one request.
type Absorb = tuple[str, str, str]
RUN_FILES = "run-files.json"
# The run files the cases come from: the answers, and the rows that name the call of each.
RUN_LOGS = ("calls.jsonl", "rows.jsonl")


def consolidation(text: object) -> Consolidation | None:
    """A decision's class, or None when the gate has no such class."""
    return next((c for c in CONSOLIDATIONS if c == text), None)


def to_judge(rows: list[JsonObject]) -> frozenset[Absorb]:
    """The absorbs of an E-synth run's rows that the judge classifies: every one but planted stale facts."""
    return frozenset((cast(str, r["item"]), cast(str, r["target"]), mid)
                     for r in rows for mid, what in cast(dict[str, str], r["absorbs"]).items() if what != "stale")


@dataclass(frozen=True, slots=True)
class MergeAdjudication:
    """The judge's class for each absorb it was asked about, and the sha256 of the files it decided on."""

    judged: Mapping[Absorb, Consolidation]
    judge_files: tuple[tuple[str, str], ...] = ()

    def mergeable(self, row: JsonObject, memory_id: str) -> bool:
        """Whether the judge found the row's absorb of `memory_id` mergeable; an absorbed planted stale
        fact has no class and is not."""
        return self.judged.get((cast(str, row["item"]), cast(str, row["target"]), memory_id)) == "mergeable"

    def numbers(self, rows: list[JsonObject], scored: list[JsonObject], target: str) -> JsonObject:
        """Absorb precision over every row of `target`, judged merge recall over its scored rows."""
        absorbs = [(r, mid) for r in rows if r["target"] == target for mid in cast(dict[str, str], r["absorbs"])]
        right = sum(self.mergeable(r, mid) for r, mid in absorbs)
        mine = [r for r in scored if r["target"] == target]
        merges = sum(cast(int, r["merges"]) for r in mine)
        made = sum(all(self.mergeable(r, mid) for mid in merge)
                   for r in mine for merge in cast(list[list[str]], r["merges_absorbed"]))
        return {"absorbs": len(absorbs), "absorbs_mergeable": right,
                "absorb_precision": right / len(absorbs) if absorbs else 1.0,
                "merges": merges, "merges_mergeable": made, "judged_merge_recall": made / merges if merges else None}

    def record(self) -> JsonObject:
        return {"absorbs": [{"item": item, "target": target, "memory_id": mid, "judged": judged}
                            for (item, target, mid), judged in sorted(self.judged.items())],
                "judge_files": dict(self.judge_files)}


NO_MERGES = MergeAdjudication(MappingProxyType({}))


def adjudicate(keys: list[JsonObject], decisions: list[JsonObject], absorbs: frozenset[Absorb]) -> MergeAdjudication:
    """The judge's class for each of `absorbs`. SystemExit when the cases were made for other absorbs or
    name one twice, or a decision is missing or is no class of the gate."""
    listed = [cast(Absorb, tuple(a)) for k in keys for a in cast(list[list[str]], k["absorbs"])]
    if len(set(listed)) != len(listed) or frozenset(listed) != absorbs:
        raise SystemExit("the merge cases were made for other absorbs: run merge_cases.py on this run")
    by_case = D.decisions_by_case(decisions)
    if set(by_case) != {cast(str, k["case"]) for k in keys}:
        raise SystemExit(f"decisions cover {len(by_case)} cases, the merge cases are {len(keys)}")
    judged: dict[Absorb, Consolidation] = {}
    for key in keys:
        case = cast(str, key["case"])
        written = by_case[case].get("decision")
        got = consolidation(written)
        if got is None:
            raise SystemExit(f"{case}: {written!r} is no class of the absorb gate")
        judged.update((cast(Absorb, tuple(a)), got) for a in cast(list[list[str]], key["absorbs"]))
    return MergeAdjudication(MappingProxyType(judged))


def run_files(run: Path) -> dict[str, str | None]:
    """The sha256 of each of RUN_LOGS in `run`."""
    return {name: D.file_sha256(run / name) for name in RUN_LOGS}


def record_run_files(folder: Path, run: Path) -> None:
    """Write <folder>/RUN_FILES: the sha256 of the run files the cases in <folder> were made from."""
    (folder / RUN_FILES).write_text(json.dumps(run_files(run), indent=1) + "\n", encoding="utf-8")


def for_run(rows: list[JsonObject], folder: Path | None, rules: Path, run: Path) -> MergeAdjudication:
    """The judge's classes for the absorbs of the E-synth run in `run`, whose rows are `rows`, from
    <folder>/key.jsonl, written by `merge_cases.py`, and the judge's decisions
    (`audit_decisions.judge_decisions`). SystemExit when an absorb needs a class and there is no folder,
    or the cases were made from other run files."""
    absorbs = to_judge(rows)
    if not absorbs:
        return NO_MERGES
    if folder is None:
        raise SystemExit(f"{len(absorbs)} E-synth absorbs need the merge judge: "
                         "run merge_cases.py, then pass its --out as --merges")
    if json.loads((folder / RUN_FILES).read_text(encoding="utf-8")) != run_files(run):
        raise SystemExit(f"the merge cases in {folder} were made from other run files than {run}'s: "
                         "run merge_cases.py on this run")
    files, decisions = D.judge_decisions(folder, rules)
    judged = adjudicate(D.read_jsonl(folder / "key.jsonl"), decisions, absorbs)
    return replace(judged, judge_files=tuple(sorted(files.items())))


def report(rows: list[JsonObject], scored: list[JsonObject], folder: Path | None, rules: Path, run: Path,
           targets: list[str]) -> JsonObject:
    """The verdict's merge part: each absorb's class, the judge's files, and the numbers of each target,
    with precision over `rows` and recall over `scored`."""
    merges = for_run(rows, folder, rules, run)
    return {**merges.record(), "by_target": {n: merges.numbers(rows, scored, n) for n in targets}}
