# pyright: strict
"""Read a judge's decisions on E-synth cases, for the label audit and for the verdict.

A case (`e_synth_audit.render_case`) shows candidates k1, k2, … and memory facts
in full, and the judge classifies every one of them by `e_synth_audit.JUDGE`.
`classes` checks a decision against its case's key.

The label audit compares the classes with the label (`misfits`). The verdict
reads them for off-label drops (`adjudicate`): memory IDs a valid answer drops
that are neither planted stale facts nor correction targets of the label. G3
needs drop precision 1.0, and a generated memory can hold a fact its label keeps
that a careful reader drops. In the audit's agreement check, one judge kept and
another dropped one of 372 facts shown in full: it copied the role material.

`e_synth_audit.py drops` makes one case per request with an off-label drop.
Every case of a memory shows the same facts in full: each fact an answer
dropped off label on that memory, filled up with facts drawn once for that
memory. Laid side by side, the cases have no fact in common that marks a drop,
and none shows the answer, the label or the target. Each drop is judged in the
case of the request it was made on. When the judge takes the fact out as well
(`drop`, or `superseded:<k>`), the label is in doubt, and the verdict scores no
request on that memory for any target. When the judge keeps the fact, the drop
stays wrong, also when its memory leaves scoring for another drop:
`wrong_outside` counts it against the target that made it.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import cast

type JsonObject = dict[str, object]
# item → memory ID → the targets whose valid answer dropped it off label
type OffLabel = dict[str, dict[str, list[str]]]

CANDIDATE_VERBS = frozenset({"new", "transient", "restates", "corrects"})
FACT_VERBS = frozenset({"keep", "drop", "superseded"})
# The folder a judge gets: the cases and the judging text, never the key.
JUDGE_DIR = "judge"


def read_jsonl(path: Path) -> list[JsonObject]:
    return [cast(JsonObject, json.loads(line)) for line in path.read_text(encoding="utf-8").splitlines()]


def memory_of(item_id: str) -> str:
    """`<split>-<memory key>-<index>`; the memory key names one generated memory."""
    return item_id.rsplit("-", 1)[0]


def decisions_by_case(decisions: list[JsonObject]) -> dict[str, JsonObject]:
    """The decisions by case ID, or SystemExit when a case has more than one."""
    by_case = {cast(str, d["case"]): d for d in decisions}
    if len(by_case) != len(decisions):
        raise SystemExit("decisions.jsonl decides a case more than once")
    return by_case


def classes(key: JsonObject, decision: JsonObject) -> tuple[dict[str, str], dict[str, str]]:
    """The decision's candidate and fact classes. SystemExit unless it classifies exactly the
    case's candidates and facts, each in the judge's terms and naming only what the case shows."""
    case = cast(str, key["case"])
    refs = set(cast(list[str], key["refs"]))
    want_c, want_f = cast(dict[str, str], key["candidates"]), cast(dict[str, str], key["facts"])
    got_c, got_f = cast(dict[str, str], decision.get("candidates", {})), cast(dict[str, str], decision.get("facts", {}))
    if set(got_c) != set(want_c) or set(got_f) != set(want_f):
        raise SystemExit(f"{case}: the decision does not classify exactly the case's candidates and facts")
    for ref in want_c:
        got = got_c[ref]
        verb, _, target = got.partition(":")
        if verb not in CANDIDATE_VERBS or (bool(target) != (verb in {"restates", "corrects"})):
            raise SystemExit(f"{case}: {ref} has an unknown classification {got!r}")
        named = target.split(",") if verb == "restates" else [target] if target else []
        if any(m not in refs for m in named):
            raise SystemExit(f"{case}: {ref} names {target}, which the case does not show")
    for mid in want_f:
        got = got_f[mid]
        verb, _, target = got.partition(":")
        if verb not in FACT_VERBS or (bool(target) != (verb == "superseded")):
            raise SystemExit(f"{case}: {mid} has an unknown classification {got!r}")
        if target and target not in want_c:
            raise SystemExit(f"{case}: {mid} names {target}, which is not a candidate of the case")
    return got_c, got_f


def misfits(key: JsonObject, decision: JsonObject) -> tuple[list[str], list[str]]:
    """(request-level misfits, memory-level misfits) as ID-only strings, or SystemExit on a malformed decision."""
    got_c, got_f = classes(key, decision)
    request = [f"{ref} expect {want} got {got_c[ref]}"
               for ref, want in cast(dict[str, str], key["candidates"]).items() if got_c[ref] != want]
    memory: list[str] = []
    for mid, want in cast(dict[str, str], key["facts"]).items():
        got = got_f[mid]
        if got == want:
            continue
        line = f"{mid} expect {want} got {got}"
        flawed = (want == "keep" and got == "drop") or (want == "drop" and got == "keep")
        (memory if flawed else request).append(line)
    return request, memory


def off_label(rows: list[JsonObject]) -> OffLabel:
    """The off-label drops of an E-synth run, from its rows (`eval_admission.score_synth`)."""
    found: OffLabel = {}
    for row in rows:
        for mid in cast(list[str], row["dropped_off_label"]):
            found.setdefault(cast(str, row["item"]), {}).setdefault(mid, []).append(cast(str, row["target"]))
    return {item: {mid: sorted(found[item][mid]) for mid in sorted(found[item])} for item in sorted(found)}


def dropped_on_memory(drops: OffLabel) -> dict[str, set[str]]:
    """Memory key → every memory ID an answer dropped off label on one of its requests."""
    out: dict[str, set[str]] = {}
    for item, mids in drops.items():
        out.setdefault(memory_of(item), set()).update(mids)
    return out


@dataclass(frozen=True, slots=True)
class Judged:
    item: str
    memory_id: str
    targets: tuple[str, ...]
    judged: str


@dataclass(frozen=True, slots=True)
class Adjudication:
    """The judge's class for each off-label drop, and the memories the verdict leaves out."""
    drops: tuple[Judged, ...]
    excluded: frozenset[str]

    def scored(self, rows: list[JsonObject]) -> list[JsonObject]:
        """The E-synth rows the verdict scores: none on an excluded memory, whatever the target."""
        return [r for r in rows if memory_of(cast(str, r["item"])) not in self.excluded]

    def wrong_outside(self) -> dict[str, int]:
        """Per target, its drops the judge kept that sit on an excluded memory. They are wrong
        drops whose rows `scored` leaves out, so drop precision counts them apart."""
        out: dict[str, int] = {}
        for d in self.drops:
            if d.judged == "keep" and memory_of(d.item) in self.excluded:
                for target in d.targets:
                    out[target] = out.get(target, 0) + 1
        return dict(sorted(out.items()))

    def record(self, items_scored: int) -> JsonObject:
        return {"off_label_drops": [{"item": d.item, "memory_id": d.memory_id, "targets": list(d.targets),
                                     "judged": d.judged} for d in self.drops],
                "excluded_memories": sorted(self.excluded), "wrong_outside": self.wrong_outside(),
                "items_scored": items_scored}


NO_DROPS = Adjudication((), frozenset())


def adjudicate(keys: list[JsonObject], decisions: list[JsonObject], drops: OffLabel) -> Adjudication:
    """The judge's classes for `drops`. SystemExit when the cases were made for other drops, a case
    does not show every off-label drop of its memory, or a decision is missing or malformed."""
    if {cast(str, k["item"]): k["off_label"] for k in keys} != drops or len(keys) != len(drops):
        raise SystemExit("the drop cases were made for other drops: run e_synth_audit.py drops on this run")
    by_case = decisions_by_case(decisions)
    if set(by_case) != {cast(str, k["case"]) for k in keys}:
        raise SystemExit(f"decisions cover {len(by_case)} cases, the drop cases are {len(keys)}")
    on_memory = dropped_on_memory(drops)
    judged: list[Judged] = []
    for key in keys:
        item = cast(str, key["item"])
        if not on_memory[memory_of(item)] <= set(cast(dict[str, str], key["facts"])):
            raise SystemExit(f"{key['case']}: the case does not show every off-label drop of its memory")
        _, facts = classes(key, by_case[cast(str, key["case"])])
        judged += [Judged(item, mid, tuple(targets), facts[mid]) for mid, targets in drops[item].items()]
    return Adjudication(tuple(judged), frozenset(memory_of(d.item) for d in judged if d.judged != "keep"))


def read_adjudication(folder: Path, drops: OffLabel) -> Adjudication:
    """`adjudicate` over <folder>/key.jsonl, written by `e_synth_audit.py drops`, and the judge's
    <folder>/judge/decisions.jsonl."""
    return adjudicate(read_jsonl(folder / "key.jsonl"), read_jsonl(folder / JUDGE_DIR / "decisions.jsonl"), drops)
