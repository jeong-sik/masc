# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""What the LoRA candidate is trained on: the examples and the steps of its one pass.

train_sft.py renders and trains what `plan` returns. This module imports no
training library, so its tests run without one.

An example is a request of the training split and the teacher answer accepted
for it. The answers are read from the teacher's folder as
`teacher_sample.py apply` reads them (`teacher_sample.accepted`): the answers
kept at once and the waiting answers whose every absorb the merge judge classed
mergeable. Each is the reply the teacher's call log holds for its request,
asked as the request, its label note and the pass lines' request settings are
now, and each is screened again for its request. accepted.jsonl is not read,
so a file an earlier `apply` left cannot become training data.

The label note the teacher was shown and the teacher's reasoning are not part
of an example. What the teacher wrote in the `reason` fields of its answer is:
a reason can repeat the note's words, and nothing here reads reasons.

`plan` refuses a teacher run that did not ask every request to the end (it
stopped on its budget, or a request ended in an HTTP error), one that names no
label audit of its requests, requests other than the ones the teacher was
sampled on, requests of a Keeper whose memories belong to E-synth
(`synth_spec.EVAL_KEEPERS`), and a folder without an accepted answer.

The examples are rendered at the scalar of the reasoning effort the teacher's
calls are keyed with (EFFORTS): Tinker's guide says to render supervised
examples at the effort their answers were generated at. The candidate is
trained in one pass: the examples are shuffled once and cut into steps of
BATCH, so each example is in one step, and a step's loss is measured before
the weights saw its examples. Requests of one memory share that memory's
facts, so that loss is not the loss on memories the weights have not seen.
"""

from __future__ import annotations

import hashlib
import json
import random
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType
from typing import cast

import audit_decisions as D
import eval_admission as V
import synth_spec as S
import teacher_sample as T

SEED = 20261109
# Examples per optimizer step. No run has compared values, and the Tinker pages read on 2026-11-12
# (LoRA primer, supervised-learning hyperparameters) give no batch size for this model.
BATCH = 4
# Tinker's named reasoning efforts as the scalars its renderer takes
# (https://tinker-docs.thinkingmachines.ai/cookbook/inkling/thinking-effort/, read 2026-11-12).
EFFORTS: Mapping[str, float] = MappingProxyType(
    {"none": 0.0, "minimal": 0.1, "low": 0.2, "medium": 0.7, "high": 0.9, "xhigh": 0.99})

type JsonObject = dict[str, object]


@dataclass(frozen=True, slots=True)
class Example:
    """A request as MASC renders it and the teacher answer accepted for it."""

    item_id: str
    request: str
    answer: str


@dataclass(frozen=True, slots=True)
class Plan:
    """One training run: the examples by item ID, the effort they are rendered at, the examples of
    each optimizer step by position, and what the run records of the teacher run it read."""

    examples: tuple[Example, ...]
    effort: float
    steps: tuple[tuple[int, ...], ...]
    teacher: JsonObject


def one_pass(n: int, batch: int, seed: int) -> tuple[tuple[int, ...], ...]:
    """The examples of each optimizer step, by position: all n shuffled once and cut into steps of `batch`."""
    order = list(range(n))
    random.Random(seed).shuffle(order)
    return tuple(tuple(order[start:start + batch]) for start in range(0, n, batch))


def held_out_keepers(requests: Path) -> list[str]:
    """The Keepers of `requests` whose memories belong to E-synth."""
    rows = (cast(JsonObject, cast(JsonObject, json.loads(line))["request"])
            for line in requests.read_text(encoding="utf-8").splitlines())
    return sorted({cast(str, cast(JsonObject, row["keeper"])["key"]) for row in rows} & S.EVAL_KEEPERS)


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def examples_sha256(examples: tuple[Example, ...]) -> str:
    """One sha256 for what is trained on: a line per example, in order, of its item ID and the
    sha256 of its request and of its answer."""
    return sha256_text("".join(f"{e.item_id} {sha256_text(e.request)} {sha256_text(e.answer)}\n" for e in examples))


def plan(requests: Path, teacher: Path) -> Plan:
    """The run that trains on every answer accepted in `teacher` for `requests`. SystemExit as the
    module text says, and as `teacher_sample.sampling_of` and `teacher_sample.accepted` do."""
    sampled = T.sampling_of(requests, teacher)
    summary = sampled.summary
    if "stopped" not in summary or summary["stopped"] is not None or summary.get("http_errors") != {}:
        raise SystemExit(f"the teacher run in {teacher} did not ask every request to the end; "
                         "run `sample` again with the same --out")
    if not summary.get("audits_sha256"):
        raise SystemExit(f"the teacher run in {teacher} names no label audit of its requests")
    held_out = held_out_keepers(requests)
    if held_out:
        raise SystemExit(f"the requests hold E-synth Keepers {held_out}; train on the train split only")
    got = T.accepted(sampled, teacher)
    records = sorted(got.records(), key=lambda record: cast(str, record["item"]))
    if not records:
        raise SystemExit(f"the teacher run in {teacher} holds no accepted answer")
    examples = tuple(Example(cast(str, r["item"]), sampled.items[cast(str, r["item"])].text, cast(str, r["answer"]))
                     for r in records)
    source: JsonObject = {
        "requests_sha256": summary["requests_sha256"], "audits_sha256": summary["audits_sha256"],
        "summary_sha256": V.sha256_file(teacher / "summary.json"), "calls_sha256": V.sha256_file(teacher / T.CALLS),
        "kept_sha256": V.sha256_file(teacher / T.KEPT), "pending_sha256": V.sha256_file(teacher / T.PENDING),
        "judge_files": dict(got.merges.judge_files),
        "decisions_sha256": D.file_sha256(teacher / T.MERGES / D.JUDGE_DIR / D.DECISIONS),
        "requests": len(sampled.items), "kept": len(got.kept), "merged": len(got.merged),
        "examples_sha256": examples_sha256(examples)}
    return Plan(examples, EFFORTS[sampled.effort], one_pass(len(examples), BATCH, SEED), source)
