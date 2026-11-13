# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""What each baseline run of the prompt comparison counts, and whether prompt_lines.json pins those counts.

    cd <checkout>
    uv run <this folder>/baseline_counts.py <baseline-runs.json>

Runs from the root of the checkout, whose `scripts/tinker/librarian/` holds the comparison imported
here. <baseline-runs.json> names each model's baseline runs as prompt_compare.py's runs.json does:

    {"inkling": [{"synth": <dir>, "real": <dir>, "drops": <dir or null>, "merges": <dir or null>}, ...],
     "glm": [...]}

prompt_lines.json is read as the comparison reads it (`prompt_lines.pinned_lines`) and each run is
measured with `prompt_counts.measure`, so a file, a run or a judges' folder the comparison refuses
stops this script too.

Prints one JSON object. `prompt_lines` is what the file pins. Under `models`, for each model of
prompt_lines.json:

- `runs_are_the_pinned_ones`: whether the baseline its listed runs count is the one the file pins,
  number for number and answered call for answered call.
- `problem`: why the listed runs cannot be the model's baseline (their number, their template), or
  null. Runs that can be its baseline but count other numbers or calls than the file pins leave it
  null and `runs_are_the_pinned_ones` false; stderr names the model.
- `pinned`: the baseline the file holds, with how many answered calls each run counted in place of
  their sha256, or null.
- `runs`: for each listed run its counts as [hits, chances], the sha256 of its rows, the template its
  prompts were drawn with, its E-real record, how many answered calls it counts, how the model's
  calls ended, and how the judges classed the model's off-label drops and absorbs, with the sha256
  of the decisions read. An answered call is one call per row, as `prompt_counts.measure` names it,
  so a call the endpoint refused is one too. An ok call is an HTTP 200 with no error in its body.
- `summed` and `turns`, for a model with listed runs: the counts summed over the runs, and the counts
  at which a draft with the baseline's chances turns worse or better.

The top `problem` is why the listed runs are not each its own sample, or null. Exits 1, with the
reasons on stderr, unless every model's listed runs count its pinned baseline and no problem is found.
"""

from __future__ import annotations

import json
import statistics
import sys
from collections import Counter
from collections.abc import Mapping
from dataclasses import asdict
from pathlib import Path
from typing import cast

sys.path.insert(0, str(Path("scripts") / "tinker" / "librarian"))

import audit_decisions as D
import eval_admission as V
import merge_decisions as MD
import prompt_compare as P
import prompt_counts as C
import prompt_lines as L
import synth_render
from tinker_oai import HTTP_OK

type JsonObject = dict[str, object]


def counts_of(counts: Mapping[C.Metric, C.Count]) -> JsonObject:
    return {metric.value: [counts[metric].hits, counts[metric].chances] for metric in C.Metric}


def pinned_of(baseline: L.Baseline) -> JsonObject:
    """`baseline` as prompt_lines.json holds it, with the number of answered calls of each run in place
    of their sha256: the calls are in the file, and `runs_are_the_pinned_ones` compares them."""
    held = {k: v for k, v in L.baseline_json(baseline).items() if k != "answered_sha256"}
    return held | {"answered_calls": [len(run) for run in baseline.answered]}


def sent_as(folder: Path, kind: str, lines: L.Lines, model: L.ModelLines) -> tuple[JsonObject, str]:
    """The run's summary and the name it sent the model under (`prompt_counts.target_of`)."""
    summary = cast(JsonObject, json.loads((folder / "summary.json").read_text(encoding="utf-8")))
    return summary, C.target_of(summary, kind, lines.pass_lines_sha256, model.provider, model.model, folder)


def answers_of(folder: Path, kind: str, lines: L.Lines, model: L.ModelLines) -> JsonObject:
    """How the model's calls of one run ended: statuses, the finishes of the ok calls, why answers
    were not valid, and the medians of the answer tokens and the wall seconds over the ok calls, None
    when no call was ok. A call is ok as `eval_admission.summarize` counts it: an HTTP 200 with no
    error in its body. `run_spent_usd` is what the whole run spent at public rates, warm calls and
    every target included; None where the summary holds no spend."""
    summary, target = sent_as(folder, kind, lines, model)
    rows = [r for r in V.read_rows(folder) if r["target"] == target]
    ok = [r for r in rows if r["status"] == HTTP_OK and r.get("error") is None]
    refused = Counter("+".join(cast(list[str], r["problems"])) for r in rows if not r["valid"])
    tokens = [cast(int, r["completion_tokens"]) for r in ok]
    seconds = [cast(float, r["wall_s"]) for r in ok]
    return {
        "items": len(rows), "valid": sum(bool(r["valid"]) for r in rows), "ok": len(ok),
        "status": dict(sorted(Counter(str(r["status"]) for r in rows).items())),
        "finish": dict(sorted(Counter(str(r["finish"]) for r in ok).items())),
        "invalid": dict(sorted(refused.items())),
        "completion_tokens_p50": statistics.median(tokens) if tokens else None,
        "wall_s_p50": round(statistics.median(seconds), 2) if seconds else None,
        "run_spent_usd": summary.get("spent_usd"),
    }


def judged_of(run: C.Run, target: str) -> JsonObject:
    """How the judges classed the off-label drops and the absorbs of the answers sent as `target`, read
    as `prompt_counts.measure` reads them; how many memories the drop classes leave out of scoring;
    and the sha256 of the decisions read, None where the run gave that judge nothing to class."""
    rows = V.read_rows(run.synth)
    off = D.off_label(rows)
    drops = D.read_adjudication(run.drops, off, synth_render.TEMPLATE) if off and run.drops else D.NO_DROPS
    absorbs = MD.to_judge(rows)
    merges = MD.for_run(rows, run.merges, synth_render.TEMPLATE, run.synth)
    return {
        "off_label_drops": dict(sorted(Counter(d.judged.text() for d in drops.drops if target in d.targets).items())),
        "memories_left_out": len(drops.excluded),
        "absorbs": dict(sorted(Counter(judged for (_, sent, _), judged in merges.judged.items()
                                       if sent == target).items())),
        "drops_decisions_sha256": D.file_sha256(run.drops / D.JUDGE_DIR / D.DECISIONS) if off and run.drops else None,
        "merges_decisions_sha256": (D.file_sha256(run.merges / D.JUDGE_DIR / D.DECISIONS)
                                    if absorbs and run.merges else None),
    }


def turns_of(base: Mapping[C.Metric, C.Count], name: str, lines: L.Lines) -> JsonObject:
    """For each metric, the most hits at which a draft with the baseline's chances is worse and the
    fewest at which it is better, by `prompt_compare.change_of`; None where no number of hits is, as
    when the baseline has no chance. `admits` says whether a better count can justify adoption: a
    quality metric of a model in `better_from`."""
    out: JsonObject = {}
    for metric in C.Metric:
        chances = base[metric].chances
        changes = [P.change_of(base[metric], C.Count(hits, chances), lines.worse_sigmas, lines.better_sigmas)[0]
                   for hits in range(chances + 1)]
        worse = [hits for hits, change in enumerate(changes) if change is P.Change.WORSE]
        better = [hits for hits, change in enumerate(changes) if change is P.Change.BETTER]
        if worse != list(range(len(worse))) or better != list(range(chances + 1 - len(better), chances + 1)):
            raise SystemExit(f"{metric.value} does not turn worse below one count and better above another")
        out[metric.value] = {"chances": chances, "worse_at_most": worse[-1] if worse else None,
                             "better_at_least": better[0] if better else None,
                             "admits": metric in P.QUALITY and name in lines.better_from}
    return out


def main() -> int:
    listed = Path(sys.argv[1])
    plan = P.plan_of(L.as_written(listed.read_bytes(), listed.name))
    lines = L.pinned_lines()
    pass_lines = V.load_pass_lines()
    items = (cast(int, cast(JsonObject, pass_lines["e_synth"])["items"]),
             cast(int, cast(JsonObject, pass_lines["e_real"])["items"]))
    measured = P.measured_runs(lines, plan, items)
    shared = P.shared_call_problem(measured)
    reasons = [] if shared is None else [shared]
    models: JsonObject = {}
    for name, model in lines.models.items():
        runs = plan.get(name, [])
        mine = measured.get(name, [])
        problem = P.baseline_problem(name, model, mine, lines.baseline_template_sha256)
        counted = P.baselines(lines, {name: mine})[name] if problem is None and shared is None else None
        pinned = counted is not None and counted == model.baseline
        if problem is not None:
            reasons.append(problem)
        elif shared is None and not pinned:
            reasons.append(f"the listed {name} runs do not count the baseline prompt_lines.json pins")
        of_model: JsonObject = {
            "model": model.model, "provider": model.provider, "runs_pinned": model.runs,
            "runs_are_the_pinned_ones": pinned, "problem": problem,
            "pinned": None if model.baseline is None else pinned_of(model.baseline),
            "runs": [{"counts": counts_of(m.counts), "synth_rows_sha256": m.synth_rows_sha256,
                      "real_rows_sha256": m.real_rows_sha256, "template_sha256": m.template_sha256,
                      "real_record": asdict(m.real_record), "answered_calls": len(m.answered),
                      "synth_answers": answers_of(run.synth, "synth", lines, model),
                      "real_answers": answers_of(run.real, "real", lines, model),
                      "judged": judged_of(run, sent_as(run.synth, "synth", lines, model)[1])}
                     for run, m in zip(runs, mine, strict=True)],
        }
        if mine:
            of_model["summed"] = counts_of(C.summed(mine))
            of_model["turns"] = turns_of(C.summed(mine), name, lines)
        models[name] = of_model
    out: JsonObject = {
        "prompt_lines": {"pass_lines_sha256": lines.pass_lines_sha256,
                         "baseline_template_sha256": lines.baseline_template_sha256,
                         "files_sha256": dict(lines.files_sha256), "worse_sigmas": lines.worse_sigmas,
                         "better_sigmas": lines.better_sigmas, "better_from": sorted(lines.better_from)},
        "models": models, "problem": shared,
    }
    print(json.dumps(out, ensure_ascii=False, indent=1))
    for reason in reasons:
        print(reason, file=sys.stderr)
    return 1 if reasons else 0


if __name__ == "__main__":
    sys.exit(main())
