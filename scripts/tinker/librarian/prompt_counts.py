# pyright: strict
"""What one run of the pinned sets counts for a prompt comparison (RFC-0517 §2.3).

`prompt_compare.py` compares these counts. A run is an E-synth run, an E-real run and the blind
judges' folders of the E-synth run (`e_synth_audit.py drops`, `merge_cases.py`), None when the run
has no off-label drop or no absorb. `measure` counts each metric as hits over chances from the rows
and the judges' decisions, as `eval_admission.measure_synth` does, and reads no number from
summary.json. The summary says what the run was: its set, pass lines, provider and template, whether
it stopped, and the name it sent the model under, which picks the model's rows in a folder that
holds another target's rows too.

A run folder is parsed where it is read (`summary_of`, `read_rows`): summary.json into a
`RunSummary`, each line of rows.jsonl into a `SynthRow` or a `RealRow`. A file that cannot be read
or is not JSON, a field left out and a field of another type each end the count in one line that
names the file and the field. No field is filled in. What counts takes the parsed values only.

A baseline in prompt_lines.json is such counts kept as numbers. It names the sha256 of this file,
so a change here leaves every pinned baseline stale until its runs are counted again. The sha256 of
a run's rows that a baseline keeps says which rows files the counts came from, and the answered
calls it keeps (`call_sha256`) say which answers were counted, so a later run that counts one of
them again can be refused. The judges' decisions are not kept, so the pinned counts are the record.
"""

from __future__ import annotations

import hashlib
import json
import sys
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from types import MappingProxyType
from typing import cast

import audit_decisions as D
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
    sha256, its E-real record, and the answered calls it counts, each as `call_sha256` names it."""

    counts: Mapping[Metric, Count]
    template_sha256: str
    synth_rows_sha256: str
    real_rows_sha256: str
    real_record: RealRecord
    answered: frozenset[str]


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def call_sha256(row: JsonObject, where: Path) -> str:
    """The answered call the row of `where` counts, as one sha256 of the call's key and the time it
    was sent. Two runs of one prompt share keys; the calls they sent differ in the time, which the
    callers keep to the millisecond. The row is read as parsed, so a row written again with other
    spacing, key order or number format names the same call. SystemExit when the row names no key,
    or no time: a finite number of at least zero."""
    key, sent = row.get("call_key"), row.get("sent_at")
    if (not isinstance(key, str) or isinstance(sent, bool) or not isinstance(sent, (int, float))
            or not 0 <= sent <= sys.float_info.max):
        raise SystemExit(f"{where} holds a row that does not name its call's key and the time it was sent")
    return hashlib.sha256(f"{key} {float(sent)!r}".encode()).hexdigest()


def strings_of(raw: object) -> tuple[str, ...] | None:
    """`raw` as the strings a JSON list holds, or None when it is anything else."""
    if not isinstance(raw, list):
        return None
    held = cast(list[object], raw)
    return tuple(x for x in held if isinstance(x, str)) if all(isinstance(x, str) for x in held) else None


def strings_by_name(raw: object) -> Mapping[str, str] | None:
    """`raw` as a JSON object of strings, or None when it is anything else."""
    if not isinstance(raw, dict):
        return None
    held = cast(dict[str, object], raw)
    named = {name: value for name, value in held.items() if isinstance(value, str)}
    return MappingProxyType(named) if len(named) == len(held) else None


@dataclass(frozen=True, slots=True)
class Fields:
    """One JSON object of a run folder, read field by field. `where` names its file, and its line in
    rows.jsonl. A reader ends in SystemExit, naming `where` and the field, when the field is left
    out or is of another type."""

    held: JsonObject
    where: str

    def refused(self, key: str, want: str) -> SystemExit:
        return SystemExit(f"{self.where}: `{key}` is not {want}" if key in self.held
                          else f"{self.where}: `{key}` is missing")

    def text(self, key: str) -> str:
        got = self.held.get(key)
        if not isinstance(got, str):
            raise self.refused(key, "a string")
        return got

    def text_or_null(self, key: str) -> str | None:
        got = self.held.get(key)
        if key not in self.held or not isinstance(got, str | None):
            raise self.refused(key, "a string or null")
        return got

    def flag(self, key: str) -> bool:
        got = self.held.get(key)
        if not isinstance(got, bool):
            raise self.refused(key, "true or false")
        return got

    def count(self, key: str) -> int:
        got = self.held.get(key)
        if isinstance(got, bool) or not isinstance(got, int) or got < 0:
            raise self.refused(key, "a whole number of at least zero")
        return got

    def strings(self, key: str) -> tuple[str, ...]:
        got = strings_of(self.held.get(key))
        if got is None:
            raise self.refused(key, "a list of strings")
        return got

    def named_strings(self, key: str) -> Mapping[str, str]:
        got = strings_by_name(self.held.get(key))
        if got is None:
            raise self.refused(key, "an object of strings")
        return got

    def string_lists(self, key: str) -> tuple[tuple[str, ...], ...]:
        raw = self.held.get(key)
        lists = [strings_of(x) for x in cast(list[object], raw)] if isinstance(raw, list) else [None]
        got = tuple(x for x in lists if x is not None)
        if len(got) != len(lists):
            raise self.refused(key, "a list of lists of strings")
        return got


@dataclass(frozen=True, slots=True)
class RunSummary:
    """What summary.json says its run was: its set, the pass lines and the template it went out
    under, its provider, the model each target name was sent as, and why it stopped, None when it
    ran to its last item."""

    kind: str
    pass_lines_sha256: str
    template_sha256: str
    provider: str
    targets: Mapping[str, str]
    stopped: str | None


@dataclass(frozen=True, slots=True)
class Row:
    """What a row of either set says: the target and the item it answers, its answered call
    (`call_sha256`), whether the answer was valid, and the candidates of its request."""

    target: str
    item: str
    call: str
    valid: bool
    candidates: int


@dataclass(frozen=True, slots=True)
class SynthRow(Row):
    """An E-synth row's scores (`memory_scores.score_synth`) that the counts and the judges read."""

    state_correct: int
    planted: int
    planted_dropped: int
    dropped: int
    dropped_expected: int
    merges: int
    dropped_off_label: tuple[str, ...]
    dropped_unmerged: tuple[str, ...]
    absorbs: Mapping[str, str]
    merges_absorbed: tuple[tuple[str, ...], ...]

    def for_judges(self) -> JsonObject:
        """The row as `audit_decisions` and `merge_decisions` read one: the fields they take, as JSON."""
        return {"item": self.item, "target": self.target, "dropped_off_label": list(self.dropped_off_label),
                "dropped_unmerged": list(self.dropped_unmerged), "absorbs": dict(self.absorbs),
                "merges": self.merges, "merges_absorbed": [list(merge) for merge in self.merges_absorbed]}


@dataclass(frozen=True, slots=True)
class RealRow(Row):
    """An E-real row's scores (`memory_scores.score_real`) that the record reads."""

    agree: int
    dropped_not_in_live: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class Rows[R: Row]:
    """The rows of one rows.jsonl in its order, and the sha256 of the bytes they were parsed from."""

    rows: tuple[R, ...]
    sha256: str


def written_in(path: Path) -> tuple[str, str]:
    """The text of the file at `path` and the sha256 of its bytes. SystemExit when it cannot be read
    or is not UTF-8."""
    try:
        written = path.read_bytes()
    except OSError as error:
        raise SystemExit(f"{path} cannot be read: {error.strerror}") from None
    try:
        return written.decode("utf-8"), hashlib.sha256(written).hexdigest()
    except UnicodeDecodeError:
        raise SystemExit(f"{path} is not UTF-8 text") from None


def fields_of(written: str, where: str) -> Fields:
    """The JSON object `written` holds. SystemExit when it holds anything else."""
    try:
        raw: object = json.loads(written)
    except json.JSONDecodeError:
        raise SystemExit(f"{where} is not JSON") from None
    if not isinstance(raw, dict):
        raise SystemExit(f"{where} is not a JSON object")
    return Fields(cast(JsonObject, raw), where)


def summary_of(folder: Path) -> RunSummary:
    """<folder>/summary.json, parsed. SystemExit when the file cannot be read or does not say what a
    `RunSummary` holds."""
    path = folder / "summary.json"
    held = fields_of(written_in(path)[0], str(path))
    return RunSummary(held.text("set"), held.text("pass_lines_sha256"), held.text("template_sha256"),
                      held.text("provider"), held.named_strings("targets"), held.text_or_null("stopped"))


def row_of(held: Fields, folder: Path) -> Row:
    return Row(held.text("target"), held.text("item"), call_sha256(held.held, folder), held.flag("valid"),
               held.count("candidates"))


def synth_row_of(held: Fields, folder: Path) -> SynthRow:
    """One line of an E-synth run's rows.jsonl, parsed."""
    row = row_of(held, folder)
    return SynthRow(row.target, row.item, row.call, row.valid, row.candidates, held.count("state_correct"),
                    held.count("planted"), held.count("planted_dropped"), held.count("dropped"),
                    held.count("dropped_expected"), held.count("merges"), held.strings("dropped_off_label"),
                    held.strings("dropped_unmerged"), held.named_strings("absorbs"),
                    held.string_lists("merges_absorbed"))


def real_row_of(held: Fields, folder: Path) -> RealRow:
    """One line of an E-real run's rows.jsonl, parsed."""
    row = row_of(held, folder)
    return RealRow(row.target, row.item, row.call, row.valid, row.candidates, held.count("agree"),
                   held.strings("dropped_not_in_live"))


def read_rows[R: Row](folder: Path, parse: Callable[[Fields, Path], R]) -> Rows[R]:
    """Every line of <folder>/rows.jsonl, parsed with `parse`. SystemExit when the file cannot be
    read or a line is not the row `parse` reads."""
    path = folder / "rows.jsonl"
    text, sha256 = written_in(path)
    return Rows(tuple(parse(fields_of(line, f"{path} line {n}"), folder)
                      for n, line in enumerate(text.splitlines(), 1)), sha256)


def synth_counts(scored: Sequence[SynthRow], wrong_outside: int, merges: JsonObject) -> dict[Metric, Count]:
    """One target's E-synth counts over its scored rows, with the wrong drops on rows left out of
    scoring, as `eval_admission.summarize` and `merge_decisions.MergeAdjudication.numbers` rate them."""
    return {
        Metric.SYNTH_VALID: Count(sum(r.valid for r in scored), len(scored)),
        Metric.MEMORY_STATE: Count(sum(r.state_correct for r in scored), sum(r.candidates for r in scored)),
        Metric.STALE_RECALL: Count(sum(r.planted_dropped for r in scored), sum(r.planted for r in scored)),
        Metric.DROP_PRECISION: Count(sum(r.dropped_expected for r in scored),
                                     sum(r.dropped for r in scored) + wrong_outside),
        Metric.ABSORB_PRECISION: Count(cast(int, merges["absorbs_mergeable"]), cast(int, merges["absorbs"])),
        Metric.MERGE_RECALL: Count(cast(int, merges["merges_mergeable"]), cast(int, merges["merges"])),
    }


def real_record(rows: Sequence[RealRow]) -> RealRecord:
    """The E-real record of one target's rows, over its valid answers."""
    valid = [r for r in rows if r.valid]
    return RealRecord(sum(r.agree for r in valid), sum(r.candidates for r in valid),
                      sum(len(r.dropped_not_in_live) for r in valid))


def target_of(summary: RunSummary, kind: str, pin: str, provider: str, model: str, where: Path) -> str:
    """The name the run sent `model` under. SystemExit unless the run is a finished `kind` run under
    the pass lines `pin`, on `provider`, sending the model under one name."""
    names = [n for n, m in summary.targets.items() if m == model]
    if (summary.kind, summary.pass_lines_sha256, summary.provider) != (kind, pin, provider):
        raise SystemExit(f"{where} is not an E-{kind} run on {provider} under the pinned pass lines")
    if summary.stopped is not None or len(names) != 1:
        raise SystemExit(f"{where} stopped before its last item or does not send {model} under one name")
    return names[0]


def own_rows[R: Row](rows: Sequence[R], target: str, items: int) -> list[R] | None:
    """The rows sent as `target` when they are one row for each of `items` items; None otherwise."""
    mine = [r for r in rows if r.target == target]
    return mine if len(mine) == items == len({r.item for r in mine}) else None


def measure(run: Run, *, provider: str, model: str, pin: str, items: tuple[int, int]) -> Measured:
    """`run`'s counts for `model` on `provider`, recomputed from its rows and its judges' folders.
    `items` are the sizes of E-synth and E-real: a run that does not hold one row of the model for
    each item of a set is refused. The judges' modules read a row as JSON (`SynthRow.for_judges`)."""
    synth_summary, real_summary = summary_of(run.synth), summary_of(run.real)
    target = target_of(synth_summary, "synth", pin, provider, model, run.synth)
    real_target = target_of(real_summary, "real", pin, provider, model, run.real)
    if synth_summary.template_sha256 != real_summary.template_sha256:
        raise SystemExit(f"{run.synth} and {run.real} drew their prompts with different templates")
    synth = read_rows(run.synth, synth_row_of)
    sent = own_rows(synth.rows, target, items[0])
    if sent is None:
        raise SystemExit(f"{run.synth} does not hold one row for each of the {items[0]} E-synth items")
    shown = [(row, row.for_judges()) for row in synth.rows]
    rows = [as_json for _, as_json in shown]
    off = D.off_label(rows)
    if off and run.drops is None:
        raise SystemExit(f"{run.synth} has off-label drops and no drop judge's folder")
    judged = D.read_adjudication(run.drops, off, synth_render.TEMPLATE) if off and run.drops else D.NO_DROPS
    scored = [(row, as_json) for row, as_json in shown if judged.scored([as_json])]
    mine = [row for row, _ in scored if row.target == target]
    if not mine:
        raise SystemExit(f"the judge's drops leave none of {run.synth} to score")
    merges = MD.for_run(rows, run.merges, synth_render.TEMPLATE, run.synth).numbers(
        rows, [as_json for _, as_json in scored], target)
    counts = synth_counts(mine, judged.wrong_outside(rows).get(target, 0), merges)
    real = read_rows(run.real, real_row_of)
    real_rows = own_rows(real.rows, real_target, items[1])
    if real_rows is None:
        raise SystemExit(f"{run.real} does not hold one row for each of the {items[1]} E-real items")
    counts[Metric.REAL_VALID] = Count(sum(r.valid for r in real_rows), len(real_rows))
    return Measured(counts, synth_summary.template_sha256, synth.sha256, real.sha256, real_record(real_rows),
                    frozenset(r.call for r in (*sent, *real_rows)))


def summed(side: list[Measured]) -> dict[Metric, Count]:
    out: dict[Metric, Count] = {}
    for measured in side:
        for metric, count in measured.counts.items():
            out[metric] = out.get(metric, Count(0, 0)) + count
    return out


def run_of(raw: object) -> Run:
    """One run as runs.json lists it: its `synth` and `real` folders and its judges' `drops` and
    `merges` folders, each of the two null or left out when the run has none. SystemExit when it is
    anything else, or names a folder by an empty string, which would read the working directory."""
    held = cast(dict[str, object], raw) if isinstance(raw, dict) else {}
    synth, real, drops, merges = held.get("synth"), held.get("real"), held.get("drops"), held.get("merges")
    if (not isinstance(synth, str) or not isinstance(real, str) or not isinstance(drops, str | None)
            or not isinstance(merges, str | None) or not set(held) <= RUN_KEYS
            or "" in (synth, real, drops, merges)):
        raise SystemExit("runs.json: a run names its synth and real folders, and its drops and merges folders or null")
    return Run(Path(synth), Path(real), None if drops is None else Path(drops),
               None if merges is None else Path(merges))
