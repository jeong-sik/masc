# pyright: strict
"""The stored runs and labels the helpers in this folder read. Imported, not run.

The helpers run from the root of a checkout of the T stack's top layer (branch
`tinker/librarian-drop-adjudication`, head 365233db560b, PR #50181). That
checkout's `scripts/tinker/librarian/` holds the harness imported here, and its
git-ignored `artifacts/tinker/librarian/` holds the runs. Nothing here calls a
model or writes a file.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Literal, cast

sys.path.insert(0, str(Path("scripts") / "tinker" / "librarian"))

import admission_validator as AV
import eval_admission as V
import prompt_facts as PF
import tinker_oai as T

__all__ = ["AV", "PF", "T", "V"]

type JsonObject = dict[str, object]
type Kind = Literal["new", "corrects", "restates", "transient"]
type Answered = tuple[V.SynthItem, AV.AdmissionAnswer | None]

KINDS: tuple[Kind, ...] = ("new", "corrects", "restates", "transient")
RUNS = Path("artifacts") / "tinker" / "librarian"
E_SYNTH = RUNS / "e-synth-3" / "requests.jsonl"  # the pinned 119 (pass_lines.json e_synth)
TRAIN = RUNS / "synth-train-4" / "requests.jsonl"  # the train split, 404 requests
BASE_SYNTH = RUNS / "eval-base-synth-3"  # base model, effort low, on the 144 before the label audit
BASE_REAL = RUNS / "eval-base-real-3"  # base model, effort low, on E-real
TEACHER = RUNS / "teacher-4"  # base model as teacher, effort high, on the train split
MANIFEST = Path("scripts") / "tinker" / "librarian" / "e_real_manifest.json"
# Outcomes whose candidate can support a memory change: `verify_support`,
# lib/keeper/keeper_memory_admission_judgment.ml:109-130.
SUPPORTING = frozenset({"incorporated", "already_represented"})


def rows(path: Path) -> list[JsonObject]:
    return [cast(JsonObject, json.loads(line)) for line in path.read_text(encoding="utf-8").splitlines()]


def candidates(item: V.SynthItem) -> list[JsonObject]:
    return cast(list[JsonObject], item.label["candidates"])


def planted(item: V.SynthItem) -> set[str]:
    return set(cast(list[str], item.label["planted_stale"]))


def targets(item: V.SynthItem) -> set[str]:
    return {cast(str, c["supersedes"]) for c in candidates(item) if c.get("supersedes") is not None}


def kind(label: JsonObject) -> Kind:
    """A label candidate's kind: its outcome, with a correction told apart from a new fact."""
    match label["outcome"]:
        case "incorporated":
            return "corrects" if label.get("supersedes") is not None else "new"
        case "already_represented":
            return "restates"
        case "not_durable":
            return "transient"
        case other:
            raise SystemExit(f"unknown label outcome {other!r}")


def supported(item: V.SynthItem) -> bool:
    """Whether a right answer may change memory: some label candidate can support the change."""
    return any(c["outcome"] in SUPPORTING for c in candidates(item))


def ids_of(item: V.SynthItem, claim: object) -> set[str]:
    """The short IDs (`m1`, ...) of the current facts whose claim is `claim`."""
    memory = item.prompt.current_memory
    facts = memory.facts if memory is not None else ()
    return {PF.surrogate_id(i) for i, fact in enumerate(facts) if fact.claim == claim}


def synth(path: Path) -> dict[str, V.SynthItem]:
    return {i.item_id: i for i in V.synth_items(path)}


def calls(run: Path) -> list[T.Call]:
    out: list[T.Call] = []
    for row in rows(run / "calls.jsonl"):
        call = T.call_from_row(row)
        if call is None:
            raise SystemExit(f"{run}/calls.jsonl: a row is not a call")
        out.append(call)
    return out


def measured(run: Path, set_name: str, target: str) -> dict[str, T.Call]:
    """Item → its measured call in an eval run. Warm calls carry a fourth label part and are skipped.
    An item answered after an earlier failure keeps the HTTP 200 call."""
    out: dict[str, T.Call] = {}
    for call in calls(run):
        parts = call.label.split(":")
        if len(parts) == 3 and parts[:2] == [set_name, target]:
            if parts[2] not in out or call.status == T.HTTP_OK:
                out[parts[2]] = call
    return out


def base_synth() -> list[Answered]:
    """The base model's answers on the pinned E-synth, None where MASC's checks refuse the answer."""
    items = synth(E_SYNTH)
    answered = measured(BASE_SYNTH, "synth", "base")
    missing = sorted(set(items) - set(answered))
    if missing:
        raise SystemExit(f"{BASE_SYNTH}: no measured call for {len(missing)} items")
    return [(item, V.check(item.prompt, answered[i].answer()).answer) for i, item in sorted(items.items())]


def teacher() -> list[tuple[V.SynthItem, T.Call, V.Check]]:
    """Every teacher attempt that got an HTTP response with status 200, checked as MASC checks it.
    teacher_sample.py does not count other statuses as attempts."""
    items = synth(TRAIN)
    out: list[tuple[V.SynthItem, T.Call, V.Check]] = []
    for call in calls(TEACHER):
        if call.status == T.HTTP_OK:
            item = items[call.label.removeprefix("teacher:")]
            out.append((item, call, V.check(item.prompt, call.answer())))
    return out


def accepted() -> list[tuple[V.SynthItem, AV.AdmissionAnswer]]:
    """The teacher answers teacher_sample.py kept for training."""
    items = synth(TRAIN)
    out: list[tuple[V.SynthItem, AV.AdmissionAnswer]] = []
    for row in rows(TEACHER / "accepted.jsonl"):
        item = items[cast(str, row["item"])]
        answer = V.check(item.prompt, cast(str, row["answer"])).answer
        if answer is None:
            raise SystemExit(f"{TEACHER}/accepted.jsonl: an accepted answer for {item.item_id} is refused")
        out.append((item, answer))
    return out


def real() -> dict[str, V.RealItem]:
    """E-real: the manifest's records, read in place from the store under MASC_BASE_PATH."""
    base = os.environ.get("MASC_BASE_PATH")
    if base is None:
        raise SystemExit("set MASC_BASE_PATH to the MASC base path whose store holds the E-real records")
    return {i.item_id: i for i in V.real_items(MANIFEST, Path(base))}
