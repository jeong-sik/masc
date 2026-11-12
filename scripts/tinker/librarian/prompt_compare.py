# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Whether a draft of config/prompts/librarian.md goes in (RFC-0517 §2.3).

    uv run scripts/tinker/librarian/prompt_compare.py compare --runs <runs.json> --out <compare.json>
    uv run scripts/tinker/librarian/prompt_compare.py baseline --runs <runs.json>

<runs.json> names each model's runs: the draft's runs for `compare`, runs of the pinned template for
`baseline`.

    {"inkling": [{"synth": <dir>, "real": <dir>, "drops": <dir or null>, "merges": <dir or null>}, ...],
     "glm": [...]}

`drops` and `merges` are the blind judges' folders of the synth run (`e_synth_audit.py drops`,
`merge_cases.py`), null when the run has no off-label drop or no absorb. `prompt_counts.py` counts a
run. A draft runs on GLM only after its Inkling runs pass, so a model may be left out; the result
then says it is incomplete, and an incomplete draft does not go in. Every model's draft runs draw
their prompts with one template, and an answered call counts in one listed run only, so a run listed
twice, or a folder copied from another listed run, is refused. A draft run that counts an answered
call a pinned baseline counted is refused too, and so is one whose rows file has the sha256 of a
baseline's rows. The callers answer a request from the log of the run's folder when it holds a
reply, so a draft run made in a copy of a baseline run's folder counts the baseline's answers again
wherever the draft leaves a request as it was.

prompt_lines.json fixes the comparison before a draft runs (`prompt_lines.py`): the pass lines, the
template of the baseline, how many runs each side takes, the noise widths, and each model's baseline
as numbers, with the answered calls its runs counted. `compare` reads the baseline from the file and
measures only the draft's runs. A comparison then needs neither the baseline's run folders nor its
judges' decisions, and neither can move a pinned count. `baseline` measures runs of the pinned
template and prints the baseline to pin.

A metric counts hits over chances, summed over a side's runs. The draft's rate minus the baseline's
is d. Its noise σ is the binomial standard error of that difference at the pooled rate p:
σ = sqrt(p(1 - p)(1/n_base + 1/n_draft)). A metric is worse when d < -worse_sigmas·σ and better when
d > better_sigmas·σ; a difference of exactly a width is neither. The draft goes in when no metric of
any model is worse and memory state accuracy, stale drop recall or judged merge recall of a model
in `better_from` is better.
A metric with chances on only one side leaves the comparison incomplete. With
no chances on either side it supplies neither degradation nor improvement.

E-real outcome agreement and the drops of memories the live answer kept are recorded for each
side and not judged: the RFC leaves the changed drops to a person.
"""

from __future__ import annotations

import argparse
import json
import math
from collections.abc import Mapping
from dataclasses import asdict
from enum import StrEnum
from fractions import Fraction
from pathlib import Path
from typing import cast

import eval_admission as V
from prompt_counts import Count, Measured, Metric, Run, measure, run_of, summed
from prompt_lines import (
    COUNTS,
    Baseline,
    Lines,
    ModelLines,
    as_written,
    baseline_json,
    model_of,
    pinned_lines,
)

type JsonObject = dict[str, object]

# RFC-0517 §2.3: only memory state, stale drop recall or judged merge recall can justify adoption.
# Drop/absorb precision and the valid rates remain non-degradation checks.
QUALITY = frozenset({Metric.MEMORY_STATE, Metric.STALE_RECALL, Metric.MERGE_RECALL})


class Change(StrEnum):
    WORSE = "worse"
    SAME = "same"
    BETTER = "better"
    UNCOUNTED = "uncounted"  # a side had nothing to count


def change_of(base: Count, draft: Count, worse_sigmas: float, better_sigmas: float) -> tuple[Change, float | None,
                                                                                               float | None]:
    """The change from `base` to `draft`, with d and σ; UNCOUNTED, None, None when a side has no chance.
    The widths are compared as exact fractions, d² against (width·σ)², so a difference of exactly a
    width is SAME whatever a float would round it to. A width is read as the decimal its float prints."""
    if base.chances == 0 or draft.chances == 0:
        return Change.UNCOUNTED, None, None
    d = Fraction(draft.hits, draft.chances) - Fraction(base.hits, base.chances)
    p = Fraction(base.hits + draft.hits, base.chances + draft.chances)
    variance = p * (1 - p) * (Fraction(1, base.chances) + Fraction(1, draft.chances))
    shown = float(d), math.sqrt(variance)
    if d < 0 and d * d > Fraction(str(worse_sigmas)) ** 2 * variance:
        return Change.WORSE, *shown
    if d > 0 and d * d > Fraction(str(better_sigmas)) ** 2 * variance:
        return Change.BETTER, *shown
    return Change.SAME, *shown


def baseline_problem(name: str, model: ModelLines, base: list[Measured], template: str) -> str | None:
    """Why the runs `base` cannot be the model's baseline, or None: the pinned number of runs, each
    drawn with the pinned template."""
    if len(base) != model.runs:
        return f"{name} takes {model.runs} baseline runs, not {len(base)}"
    if {m.template_sha256 for m in base} != {template}:
        return f"a {name} baseline run drew its prompts with another template than the pinned one"
    return None


def draft_problem(name: str, model: ModelLines, draft: list[Measured], template: str) -> str | None:
    """Why a model's draft runs cannot be compared, or None: the pinned number of runs, sharing one
    template other than the pinned one."""
    if len(draft) != model.runs:
        return f"{name} takes {model.runs} draft runs, not {len(draft)}"
    drafts = {m.template_sha256 for m in draft}
    if len(drafts) != 1 or template in drafts:
        return f"the {name} draft runs do not share one template other than the pinned one"
    return None


def shared_call_problem(runs: Mapping[str, list[Measured]]) -> str | None:
    """Why the runs are not each its own sample, or None: no answered call counts in two of them."""
    seen: dict[str, str] = {}
    for name, listed in runs.items():
        for m in listed:
            shared = {seen[call] for call in m.answered if call in seen}
            if shared:
                return (f"runs of {' and '.join(sorted(shared | {name}))} count the same answered call: "
                        "a run is listed twice or copied")
            seen.update(dict.fromkeys(m.answered, name))
    return None


def plan_problem(drafts: Mapping[str, list[Measured]]) -> str | None:
    """Why the models' draft runs cannot be compared together, or None: the draft runs of every model
    drew their prompts with one template, so the result speaks of one draft, and each run is its own
    sample (`shared_call_problem`)."""
    if len({m.template_sha256 for draft in drafts.values() for m in draft}) > 1:
        return "the models' draft runs drew their prompts with different templates"
    return shared_call_problem(drafts)


def plan_of(raw: object) -> dict[str, list[Run]]:
    """runs.json as each model's runs. SystemExit unless it is an object that lists runs under each
    model's name (`prompt_counts.run_of`)."""
    if not isinstance(raw, dict):
        raise SystemExit("runs.json is not an object of each model's runs")
    plan: dict[str, list[Run]] = {}
    for name, listed in cast(dict[str, object], raw).items():
        if not isinstance(listed, list):
            raise SystemExit(f"runs.json does not list runs under {name}")
        plan[name] = [run_of(run) for run in cast(list[object], listed)]
    return plan


def measured_runs(lines: Lines, plan: Mapping[str, list[Run]], items: tuple[int, int]) -> dict[str, list[Measured]]:
    """What each run that `plan` lists counts for its model (`prompt_counts.measure`). SystemExit when
    `plan` names a model prompt_lines.json does not hold."""
    out: dict[str, list[Measured]] = {}
    for name, runs in plan.items():
        model = model_of(lines, name)
        out[name] = [measure(run, provider=model.provider, model=model.model, pin=lines.pass_lines_sha256,
                             items=items) for run in runs]
    return out


def baselines(lines: Lines, runs: Mapping[str, list[Measured]]) -> dict[str, Baseline]:
    """The baseline each listed model's runs counted. SystemExit when a model's runs cannot be its
    baseline (`baseline_problem`) or two runs share an answered call."""
    out: dict[str, Baseline] = {}
    for name, base in runs.items():
        model = model_of(lines, name)
        problem = baseline_problem(name, model, base, lines.baseline_template_sha256)
        if problem is not None:
            raise SystemExit(problem)
        out[name] = Baseline(model.provider, model.model, lines.pass_lines_sha256, lines.baseline_template_sha256,
                             lines.files_sha256[COUNTS], summed(base), tuple(m.real_record for m in base),
                             tuple(m.synth_rows_sha256 for m in base), tuple(m.real_rows_sha256 for m in base),
                             tuple(m.answered for m in base))
    problem = shared_call_problem(runs)
    if problem is not None:
        raise SystemExit(problem)
    return out


def sides_of(lines: Lines, drafts: Mapping[str, list[Measured]]) -> dict[str, tuple[Baseline, list[Measured]]]:
    """Each listed model's pinned baseline beside its draft runs. SystemExit when the file pins no
    baseline for a model yet, a draft run counts an answered call a pinned baseline of any model
    counted or holds the rows one was counted from, or the draft runs cannot be compared
    (`draft_problem`, `plan_problem`)."""
    pinned = frozenset(call for m in lines.models.values() if m.baseline is not None
                       for run in m.baseline.answered for call in run)
    pinned_rows = frozenset(rows for m in lines.models.values() if m.baseline is not None
                            for rows in (*m.baseline.synth_rows_sha256, *m.baseline.real_rows_sha256))
    sides: dict[str, tuple[Baseline, list[Measured]]] = {}
    for name, draft in drafts.items():
        model = model_of(lines, name)
        if model.baseline is None:
            raise SystemExit(f"prompt_lines.json pins no {name} baseline yet")
        if any(m.answered & pinned for m in draft):
            raise SystemExit(f"a {name} draft run counts an answered call a pinned baseline counted")
        if any({m.synth_rows_sha256, m.real_rows_sha256} & pinned_rows for m in draft):
            raise SystemExit(f"a {name} draft run holds the rows a pinned baseline was counted from")
        problem = draft_problem(name, model, draft, lines.baseline_template_sha256)
        if problem is not None:
            raise SystemExit(problem)
        sides[name] = (model.baseline, draft)
    problem = plan_problem(drafts)
    if problem is not None:
        raise SystemExit(problem)
    return sides


def compared(lines: Lines, sides: Mapping[str, tuple[Baseline, list[Measured]]]) -> JsonObject:
    """The comparison of each model's draft runs with its pinned baseline, and whether the draft goes in."""
    models: JsonObject = {}
    worse: list[str] = []
    better: list[str] = []
    uncompared: list[str] = []
    for name, (baseline, draft) in sides.items():
        b, d = baseline.counts, summed(draft)
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
        models[name] = {"metrics": metrics,
                        "real_record": {"base": [asdict(r) for r in baseline.real_record],
                                        "draft": [asdict(m.real_record) for m in draft]},
                        "base_rows_sha256": {"synth": list(baseline.synth_rows_sha256),
                                             "real": list(baseline.real_rows_sha256)},
                        "draft_rows_sha256": {"synth": [m.synth_rows_sha256 for m in draft],
                                              "real": [m.real_rows_sha256 for m in draft]}}
    complete = set(sides) == set(lines.models) and not uncompared
    templates = sorted({m.template_sha256 for _, draft in sides.values() for m in draft})
    return {"draft_template_sha256": templates, "models": models, "worse": worse, "better": better,
            "uncompared": uncompared,
            "complete": complete, "goes_in": complete and not worse and bool(better)}


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    compare = sub.add_parser("compare", help="whether a draft goes in, against the pinned baselines")
    compare.add_argument("--runs", required=True, help="runs.json: each model's draft runs")
    compare.add_argument("--out", required=True, help="where the comparison is written")
    baseline = sub.add_parser("baseline", help="print the baseline that runs of the pinned template counted")
    baseline.add_argument("--runs", required=True, help="runs.json: each model's runs of the pinned template")
    args = ap.parse_args()
    lines = pinned_lines()
    pass_lines = V.load_pass_lines()
    items = (cast(int, cast(JsonObject, pass_lines["e_synth"])["items"]),
             cast(int, cast(JsonObject, pass_lines["e_real"])["items"]))
    plan = plan_of(as_written(Path(cast(str, args.runs)).read_bytes(), "runs.json"))
    runs = measured_runs(lines, plan, items)
    if args.cmd == "baseline":
        print(json.dumps({name: baseline_json(b) for name, b in baselines(lines, runs).items()}, indent=1))
        return 0
    result = compared(lines, sides_of(lines, runs))
    Path(cast(str, args.out)).write_text(json.dumps(result, indent=1) + "\n", encoding="utf-8")
    print(json.dumps({k: result[k] for k in ("worse", "better", "uncompared", "complete", "goes_in")}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
