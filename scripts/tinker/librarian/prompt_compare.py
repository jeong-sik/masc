# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Whether a draft of config/prompts/librarian.md goes in (RFC-0517 §2.3).

    uv run scripts/tinker/librarian/prompt_compare.py --runs <runs.json> --out <compare.json>

<runs.json> names each model's runs of the pinned template ("base") and of the draft ("draft"):

    {"inkling": {"base": [{"synth": <dir>, "real": <dir>, "drops": <dir or null>, "merges": <dir or null>}],
                 "draft": [...]},
     "glm": {...}}

`drops` and `merges` are the blind judges' folders of the synth run (`e_synth_audit.py drops`,
`merge_cases.py`), null when the run has no off-label drop or no absorb. A draft runs on GLM only
after its Inkling runs pass, so a model may be left out; the result then says it is incomplete,
and an incomplete draft does not go in. Every model's draft runs draw their prompts with one
template, and an answered call counts in one run only, so a run listed twice, or a folder copied
from another run, is refused.

prompt_lines.json fixes the comparison before a draft runs: the pass lines and the template the
baseline runs were drawn with, the rows of each baseline run, how many runs each side takes, and
the noise widths. A metric counts hits over chances, summed over a side's runs. The draft's rate
minus the baseline's is d. Its noise σ is the binomial standard error of that difference at the
pooled rate p: σ = sqrt(p(1 - p)(1/n_base + 1/n_draft)). A metric is worse when
d < -worse_sigmas·σ and better when d > better_sigmas·σ. The draft goes in when no metric of any
model is worse and memory state accuracy, stale drop recall or judged merge recall of a model
in `better_from` is better.
A metric with chances on only one side leaves the comparison incomplete. With
no chances on either side it supplies neither degradation nor improvement.

E-real outcome agreement and the drops of memories the live answer kept are recorded for each
side and not judged: the RFC leaves the changed drops to a person.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
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

HERE = Path(__file__).resolve().parent
PROMPT_LINES = HERE / "prompt_lines.json"


class Metric(StrEnum):
    SYNTH_VALID = "synth_valid_rate"
    REAL_VALID = "real_valid_rate"
    MEMORY_STATE = "memory_state_accuracy"
    STALE_RECALL = "stale_drop_recall"
    MERGE_RECALL = "judged_merge_recall"
    DROP_PRECISION = "drop_precision"
    ABSORB_PRECISION = "absorb_precision"


# RFC-0517 §2.3: only memory state, stale drop recall or judged merge recall can justify adoption.
# Drop/absorb precision and the valid rates remain non-degradation checks.
QUALITY = frozenset({Metric.MEMORY_STATE, Metric.STALE_RECALL, Metric.MERGE_RECALL})


class Change(StrEnum):
    WORSE = "worse"
    SAME = "same"
    BETTER = "better"
    UNCOUNTED = "uncounted"  # a side had nothing to count


@dataclass(frozen=True, slots=True)
class Count:
    hits: int
    chances: int

    def __add__(self, other: Count) -> Count:
        return Count(self.hits + other.hits, self.chances + other.chances)


@dataclass(frozen=True, slots=True)
class ModelLines:
    provider: str
    model: str
    runs: int
    base_synth_rows: frozenset[str]
    base_real_rows: frozenset[str]


@dataclass(frozen=True, slots=True)
class Lines:
    pass_lines_sha256: str
    baseline_template_sha256: str
    worse_sigmas: float
    better_sigmas: float
    better_from: frozenset[str]
    models: Mapping[str, ModelLines]


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
    real_record: JsonObject
    answered: frozenset[tuple[str, float]]


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def lines_of(raw: JsonObject) -> Lines:
    models = cast(dict[str, JsonObject], raw["models"])
    return Lines(cast(str, raw["pass_lines_sha256"]), cast(str, raw["baseline_template_sha256"]),
                 float(cast(float, raw["worse_sigmas"])), float(cast(float, raw["better_sigmas"])),
                 frozenset(cast(list[str], raw["better_from"])),
                 {name: ModelLines(cast(str, m["provider"]), cast(str, m["model"]), cast(int, m["runs"]),
                                   frozenset(cast(list[str], m["base_synth_rows_sha256"])),
                                   frozenset(cast(list[str], m["base_real_rows_sha256"])))
                  for name, m in models.items()})


def change_of(base: Count, draft: Count, worse_sigmas: float, better_sigmas: float) -> tuple[Change, float | None,
                                                                                               float | None]:
    """The change from `base` to `draft`, with d and σ; UNCOUNTED, None, None when a side has no chance."""
    if base.chances == 0 or draft.chances == 0:
        return Change.UNCOUNTED, None, None
    d = draft.hits / draft.chances - base.hits / base.chances
    p = (base.hits + draft.hits) / (base.chances + draft.chances)
    sigma = math.sqrt(p * (1 - p) * (1 / base.chances + 1 / draft.chances))
    if d < -worse_sigmas * sigma:
        return Change.WORSE, d, sigma
    if d > better_sigmas * sigma:
        return Change.BETTER, d, sigma
    return Change.SAME, d, sigma


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


def real_record(rows: list[JsonObject]) -> JsonObject:
    """Recorded, not judged: outcome agreement with the live answer over the valid answers, and the
    memories they drop that the live answer kept."""
    valid = [r for r in rows if r["valid"]]
    return {"agree": total("agree", valid), "candidates": total("candidates", valid),
            "dropped_not_in_live": sum(len(cast(list[str], r["dropped_not_in_live"])) for r in valid)}


def target_of(summary: JsonObject, kind: str, pin: str, model: ModelLines, where: Path) -> str:
    """The name the run sent the model under. SystemExit unless the run is a finished `kind` run under
    the pass lines `pin`, on the model's provider, sending the model under one name."""
    names = [n for n, m in cast(dict[str, str], summary["targets"]).items() if m == model.model]
    if (summary["set"], summary["pass_lines_sha256"], summary["provider"]) != (kind, pin, model.provider):
        raise SystemExit(f"{where} is not an E-{kind} run on {model.provider} under the pinned pass lines")
    if summary["stopped"] is not None or len(names) != 1:
        raise SystemExit(f"{where} stopped before its last item or does not send {model.model} under one name")
    return names[0]


def measure(run: Run, model: ModelLines, pin: str, items: tuple[int, int]) -> Measured:
    """`run`'s counts, recomputed from its rows and its judges' folders as `eval_admission.measure_synth`
    does, so an edited summary.json cannot change them."""
    synth_summary = cast(JsonObject, json.loads((run.synth / "summary.json").read_text(encoding="utf-8")))
    real_summary = cast(JsonObject, json.loads((run.real / "summary.json").read_text(encoding="utf-8")))
    target = target_of(synth_summary, "synth", pin, model, run.synth)
    real_target = target_of(real_summary, "real", pin, model, run.real)
    if synth_summary["template_sha256"] != real_summary["template_sha256"]:
        raise SystemExit(f"{run.synth} and {run.real} drew their prompts with different templates")
    rows = V.read_rows(run.synth)
    if sum(r["target"] == target for r in rows) != items[0]:
        raise SystemExit(f"{run.synth} has not answered all {items[0]} E-synth items")
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
        raise SystemExit(f"{run.real} has not answered all {items[1]} E-real items")
    counts[Metric.REAL_VALID] = Count(sum(bool(r["valid"]) for r in real_rows), len(real_rows))
    answered = frozenset((cast(str, r["call_key"]), cast(float, r["sent_at"]))
                         for r in [*(r for r in rows if r["target"] == target), *real_rows])
    return Measured(counts, cast(str, synth_summary["template_sha256"]), sha256_file(run.synth / "rows.jsonl"),
                    sha256_file(run.real / "rows.jsonl"), real_record(real_rows), answered)


def side_problem(name: str, model: ModelLines, base: list[Measured], draft: list[Measured],
                 baseline_template: str) -> str | None:
    """Why a model's runs cannot be compared, or None: each side takes the pinned number of runs, the
    baseline runs are the pinned ones, drawn with the pinned template, and the draft runs share one
    other template."""
    if len(base) != model.runs or len(draft) != model.runs:
        return f"{name} takes {model.runs} base and {model.runs} draft runs, not {len(base)} and {len(draft)}"
    if not model.base_synth_rows or not model.base_real_rows:
        return f"prompt_lines.json pins no {name} baseline runs yet"
    if (frozenset(m.synth_rows_sha256 for m in base) != model.base_synth_rows
            or frozenset(m.real_rows_sha256 for m in base) != model.base_real_rows):
        return f"the {name} baseline runs are not the ones prompt_lines.json pins"
    if {m.template_sha256 for m in base} != {baseline_template}:
        return f"a {name} baseline run drew its prompts with another template than the pinned one"
    drafts = {m.template_sha256 for m in draft}
    if len(drafts) != 1 or baseline_template in drafts:
        return f"the {name} draft runs do not share one template other than the pinned one"
    return None


def plan_problem(sides: Mapping[str, tuple[list[Measured], list[Measured]]]) -> str | None:
    """Why the models' runs cannot be compared together, or None: the draft runs of every model drew
    their prompts with one template, so the result speaks of one draft, and no answered call counts
    in two runs, so each run is its own sample."""
    if len({m.template_sha256 for _, draft in sides.values() for m in draft}) > 1:
        return "the models' draft runs drew their prompts with different templates"
    seen: set[tuple[str, float]] = set()
    for name, (base, draft) in sides.items():
        for m in [*base, *draft]:
            if m.answered & seen:
                return f"two {name} runs count the same answered call: a run is listed twice or copied"
            seen |= m.answered
    return None


def summed(side: list[Measured]) -> dict[Metric, Count]:
    out: dict[Metric, Count] = {}
    for measured in side:
        for metric, count in measured.counts.items():
            out[metric] = out.get(metric, Count(0, 0)) + count
    return out


def compared(lines: Lines, sides: Mapping[str, tuple[list[Measured], list[Measured]]]) -> JsonObject:
    """The comparison of each model's sides, and whether the draft goes in."""
    models: JsonObject = {}
    worse: list[str] = []
    better: list[str] = []
    uncompared: list[str] = []
    for name, (base, draft) in sides.items():
        b, d = summed(base), summed(draft)
        metrics: JsonObject = {}
        for metric in Metric:
            change, diff, sigma = change_of(b[metric], d[metric], lines.worse_sigmas, lines.better_sigmas)
            metrics[metric.value] = {"base": [b[metric].hits, b[metric].chances],
                                     "draft": [d[metric].hits, d[metric].chances],
                                     "d": diff, "sigma": sigma, "change": change.value}
            if change is Change.WORSE:
                worse.append(f"{name}.{metric.value}")
            if change is Change.UNCOUNTED and ((b[metric].chances == 0) != (d[metric].chances == 0)):
                uncompared.append(f"{name}.{metric.value}")
            if change is Change.BETTER and metric in QUALITY and name in lines.better_from:
                better.append(f"{name}.{metric.value}")
        models[name] = {"metrics": metrics, "real_record": {"base": [m.real_record for m in base],
                                                            "draft": [m.real_record for m in draft]}}
    complete = set(sides) == set(lines.models) and not uncompared
    templates = sorted({m.template_sha256 for _, draft in sides.values() for m in draft})
    return {"draft_template_sha256": templates, "models": models, "worse": worse, "better": better,
            "uncompared": uncompared,
            "complete": complete, "goes_in": complete and not worse and bool(better)}


def run_of(raw: JsonObject) -> Run:
    def folder(key: str) -> Path | None:
        value = raw.get(key)
        return None if value is None else Path(cast(str, value))

    return Run(Path(cast(str, raw["synth"])), Path(cast(str, raw["real"])), folder("drops"), folder("merges"))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", required=True, help="runs.json: each model's base and draft runs")
    ap.add_argument("--out", required=True, help="where the comparison is written")
    args = ap.parse_args()
    raw = cast(JsonObject, json.loads(PROMPT_LINES.read_text(encoding="utf-8")))
    if cast(dict[str, str], raw["files_sha256"]) != {Path(__file__).name: sha256_file(Path(__file__))}:
        raise SystemExit("prompt_compare.py differs from the file prompt_lines.json pins")
    lines = lines_of(raw)
    pin = sha256_file(V.PASS_LINES)
    if pin != lines.pass_lines_sha256:
        raise SystemExit("prompt_lines.json was fixed under other pass lines")
    pass_lines = V.load_pass_lines()
    items = (cast(int, cast(JsonObject, pass_lines["e_synth"])["items"]),
             cast(int, cast(JsonObject, pass_lines["e_real"])["items"]))
    plan = cast(dict[str, dict[str, list[JsonObject]]], json.loads(Path(cast(str, args.runs)).read_text(encoding="utf-8")))
    sides: dict[str, tuple[list[Measured], list[Measured]]] = {}
    for name, runs in plan.items():
        model = lines.models.get(name)
        if model is None:
            raise SystemExit(f"prompt_lines.json names no model {name}")
        base = [measure(run_of(r), model, pin, items) for r in runs["base"]]
        draft = [measure(run_of(r), model, pin, items) for r in runs["draft"]]
        problem = side_problem(name, model, base, draft, lines.baseline_template_sha256)
        if problem is not None:
            raise SystemExit(problem)
        sides[name] = (base, draft)
    problem = plan_problem(sides)
    if problem is not None:
        raise SystemExit(problem)
    result = compared(lines, sides)
    Path(cast(str, args.out)).write_text(json.dumps(result, indent=1) + "\n", encoding="utf-8")
    print(json.dumps({k: result[k] for k in ("worse", "better", "uncompared", "complete", "goes_in")}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
