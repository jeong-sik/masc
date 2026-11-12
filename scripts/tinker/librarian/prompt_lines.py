# pyright: strict
"""What prompt_lines.json fixes for a prompt comparison (RFC-0517 §2.3), as `prompt_compare.py` reads it.

The file is committed before a draft runs. It fixes the pass lines and the template of the baseline,
the noise widths, the models whose improvement can justify adoption, the sha256 of the files that
compare (`files_sha256`), and for each model how many runs a side takes and its baseline:

    "inkling": {"provider": ..., "model": ..., "runs": 2,
                "baseline": {"provider": ..., "model": ..., "pass_lines_sha256": ..., "template_sha256": ...,
                             "prompt_counts_sha256": ...,
                             "counts": {"synth_valid_rate": [hits, chances], ...},
                             "real_record": [{"agree": ..., "candidates": ..., "dropped_not_in_live": ...}, ...],
                             "synth_rows_sha256": [...], "real_rows_sha256": [...]}}

A baseline is what the model's runs of the pinned template counted, kept as numbers: each metric's
hits over chances summed over the runs and, for each run in order, its E-real record and the sha256
of its E-synth and E-real rows. `prompt_compare.py baseline` prints it. It is null until the model's
runs are counted.

A baseline names what it was counted for and under: the provider and the model, the pass lines, the
template and the prompt_counts.py. When the file names another of them the baseline is stale and the
file is refused. After a change of prompt_counts.py alone, set the baseline to null, count the
model's runs again with `prompt_compare.py baseline`, and pin what it prints. After a change of the
model, the pass lines or the template the old runs are refused as well (`prompt_counts.measure`,
`prompt_compare.baseline_problem`), so the model runs again first.

The file is read as written: a key the comparison does not read, a key written twice in one object,
or a value of another shape is refused.
"""

from __future__ import annotations

import json
import re
import sys
from collections.abc import Mapping
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import cast

import eval_admission as V
from prompt_counts import Count, Metric, RealRecord, sha256_file

type JsonObject = dict[str, object]

HERE = Path(__file__).resolve().parent
PROMPT_LINES = HERE / "prompt_lines.json"
SCHEMA = "masc.tinker.librarian.prompt_lines.v2"
COUNTS = "prompt_counts.py"
# The files prompt_lines.json pins by sha256: what counts a run, what reads the file, what compares.
PINNED_FILES = (COUNTS, "prompt_lines.py", "prompt_compare.py")
SHA256 = re.compile(r"[0-9a-f]{64}")
LINES_KEYS = frozenset({"schema", "pass_lines_sha256", "baseline_template_sha256", "files_sha256", "worse_sigmas",
                        "better_sigmas", "better_from", "models"})
MODEL_KEYS = frozenset({"provider", "model", "runs", "baseline"})
BASELINE_KEYS = frozenset({"provider", "model", "pass_lines_sha256", "template_sha256", "prompt_counts_sha256",
                           "counts", "real_record", "synth_rows_sha256", "real_rows_sha256"})
REAL_RECORD_KEYS = ("agree", "candidates", "dropped_not_in_live")


@dataclass(frozen=True, slots=True)
class Baseline:
    """What a model's runs of the pinned template counted, and what they were counted for and under:
    the provider and the model, the pass lines, the template and the prompt_counts.py, each metric
    summed over the runs, and for each run in order its E-real record and the sha256 of its E-synth
    and E-real rows."""

    provider: str
    model: str
    pass_lines_sha256: str
    template_sha256: str
    prompt_counts_sha256: str
    counts: Mapping[Metric, Count]
    real_record: tuple[RealRecord, ...]
    synth_rows_sha256: tuple[str, ...]
    real_rows_sha256: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class ModelLines:
    provider: str
    model: str
    runs: int
    baseline: Baseline | None  # None until the model's baseline is pinned


@dataclass(frozen=True, slots=True)
class Lines:
    pass_lines_sha256: str
    baseline_template_sha256: str
    files_sha256: Mapping[str, str]
    worse_sigmas: float
    better_sigmas: float
    better_from: frozenset[str]
    models: Mapping[str, ModelLines]


def object_of(raw: object) -> JsonObject | None:
    """`raw` as a JSON object; None when it is anything else."""
    return cast(JsonObject, raw) if isinstance(raw, dict) else None


def name_of(raw: object) -> str | None:
    """`raw` as a name, a string that is not empty; None when it is anything else."""
    return raw if isinstance(raw, str) and raw else None


def ints_of(raw: object, n: int) -> tuple[int, ...] | None:
    """`raw` as a list of `n` integers, none below zero; None when it is anything else."""
    if not isinstance(raw, list):
        return None
    items = cast(list[object], raw)
    if len(items) != n or any(not isinstance(v, int) or isinstance(v, bool) or v < 0 for v in items):
        return None
    return tuple(cast(list[int], items))


def hashes_of(raw: object, n: int) -> tuple[str, ...] | None:
    """`raw` as a list of `n` sha256 digests in lowercase hex; None when it is anything else."""
    if not isinstance(raw, list):
        return None
    items = cast(list[object], raw)
    if len(items) != n or any(not isinstance(v, str) or SHA256.fullmatch(v) is None for v in items):
        return None
    return tuple(cast(list[str], items))


def width_of(raw: JsonObject, key: str) -> float:
    """The noise width prompt_lines.json holds under `key`, a distance in σ. SystemExit unless it is a
    finite number of at least zero."""
    value = raw.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not 0 <= value <= sys.float_info.max:
        raise SystemExit(f"prompt_lines.json: {key} is not a finite number of at least zero")
    return float(value)


def real_record_from(raw: object) -> RealRecord | None:
    """One run's E-real record as prompt_lines.json holds it; None when it is anything else."""
    held = object_of(raw)
    if held is None or set(held) != set(REAL_RECORD_KEYS):
        return None
    values = ints_of([held[k] for k in REAL_RECORD_KEYS], len(REAL_RECORD_KEYS))
    if values is None or values[0] > values[1]:
        return None
    return RealRecord(*values)


def baseline_from(name: str, runs: int, raw: object) -> Baseline:
    """The baseline prompt_lines.json holds for the model `name`, which takes `runs` runs a side.
    SystemExit unless it names what it was counted for and under, counts every metric as hits within
    chances, and holds an E-real record and the sha256 of each set's rows for each run, no rows twice."""

    def refused(why: str) -> SystemExit:
        return SystemExit(f"prompt_lines.json: the {name} baseline {why}")

    held = object_of(raw)
    if held is None or frozenset(held) != BASELINE_KEYS:
        raise refused("does not hold exactly " + ", ".join(sorted(BASELINE_KEYS)))
    provider, model = name_of(held["provider"]), name_of(held["model"])
    if provider is None or model is None:
        raise refused("does not name the provider and the model it was counted for")
    under = hashes_of([held["pass_lines_sha256"], held["template_sha256"], held["prompt_counts_sha256"]], 3)
    if under is None:
        raise refused("does not name by sha256 the pass lines, the template and the prompt_counts.py it was "
                      "counted under")
    raw_counts = object_of(held["counts"])
    if raw_counts is None or set(raw_counts) != {m.value for m in Metric}:
        raise refused("does not hold one count for each metric")
    counts: dict[Metric, Count] = {}
    for metric in Metric:
        pair = ints_of(raw_counts[metric.value], 2)
        if pair is None or pair[0] > pair[1]:
            raise refused(f"does not count {metric.value} as hits within chances")
        counts[metric] = Count(pair[0], pair[1])
    raw_records = held["real_record"]
    records = [real_record_from(r) for r in cast(list[object], raw_records)] if isinstance(raw_records, list) else []
    known = tuple(r for r in records if r is not None)
    synth, real = hashes_of(held["synth_rows_sha256"], runs), hashes_of(held["real_rows_sha256"], runs)
    if len(known) != runs or len(records) != runs or synth is None or real is None:
        raise refused(f"does not hold an E-real record and the sha256 of each set's rows for each of its {runs} runs")
    if len({*synth, *real}) != 2 * runs:
        raise refused("names the rows of one run twice")
    return Baseline(provider, model, under[0], under[1], under[2], counts, known, synth, real)


def baseline_json(baseline: Baseline) -> JsonObject:
    """`baseline` as prompt_lines.json holds it; `baseline_from` reads it back."""
    return {"provider": baseline.provider, "model": baseline.model,
            "pass_lines_sha256": baseline.pass_lines_sha256, "template_sha256": baseline.template_sha256,
            "prompt_counts_sha256": baseline.prompt_counts_sha256,
            "counts": {m.value: [baseline.counts[m].hits, baseline.counts[m].chances] for m in Metric},
            "real_record": [asdict(r) for r in baseline.real_record],
            "synth_rows_sha256": list(baseline.synth_rows_sha256),
            "real_rows_sha256": list(baseline.real_rows_sha256)}


def model_from(name: str, raw: object, under: tuple[str, str, str]) -> ModelLines:
    """What prompt_lines.json holds for the model `name`. `under` is the pass lines, the template and
    the prompt_counts.py the file pins. SystemExit when the model is no object, holds a key the
    comparison does not read, names no provider or no model, takes no run, holds no baseline, or
    holds one that is malformed, was counted for another provider or model, or was counted under
    something else than `under`."""
    held = object_of(raw)
    if held is None:
        raise SystemExit(f"prompt_lines.json: {name} is not an object of a model's lines")
    if not set(held) <= MODEL_KEYS:
        raise SystemExit(f"prompt_lines.json: {name} holds a key the comparison does not read: "
                         + ", ".join(sorted(set(held) - MODEL_KEYS)))
    provider, model = name_of(held.get("provider")), name_of(held.get("model"))
    if provider is None or model is None:
        raise SystemExit(f"prompt_lines.json: {name} names no provider or no model")
    runs = held.get("runs")
    if not isinstance(runs, int) or isinstance(runs, bool) or runs < 1:
        raise SystemExit(f"prompt_lines.json: {name} takes no run")
    if "baseline" not in held:
        raise SystemExit(f"prompt_lines.json: {name} holds no baseline, pinned or null")
    baseline = None if held["baseline"] is None else baseline_from(name, runs, held["baseline"])
    if baseline is not None and (baseline.provider, baseline.model) != (provider, model):
        raise SystemExit(f"prompt_lines.json: the {name} baseline was counted for another provider or model than "
                         f"{name} names")
    if baseline is not None and (baseline.pass_lines_sha256, baseline.template_sha256,
                                 baseline.prompt_counts_sha256) != under:
        raise SystemExit(f"prompt_lines.json: the {name} baseline was counted under other pass lines, another "
                         "template or another prompt_counts.py than the file pins")
    return ModelLines(provider, model, runs, baseline)


def lines_of(raw: object) -> Lines:
    """prompt_lines.json as the comparison reads it. SystemExit when it is of another schema, holds a
    key the comparison does not read, does not name by sha256 the pass lines, the template and exactly
    the pinned files, a width is not a finite number of at least zero, it holds no model or a model
    `model_from` refuses, or `better_from` does not list, each once, models the file holds."""
    held = object_of(raw)
    if held is None or held.get("schema") != SCHEMA:
        raise SystemExit(f"prompt_lines.json is not of schema {SCHEMA}")
    if not set(held) <= LINES_KEYS:
        raise SystemExit("prompt_lines.json holds a key the comparison does not read: "
                         + ", ".join(sorted(set(held) - LINES_KEYS)))
    under = hashes_of([held.get("pass_lines_sha256"), held.get("baseline_template_sha256")], 2)
    if under is None:
        raise SystemExit("prompt_lines.json does not name by sha256 the pass lines and the template of the baseline")
    pass_lines, template = under
    files = object_of(held.get("files_sha256"))
    pinned = None if files is None or set(files) != set(PINNED_FILES) else hashes_of(
        [files[name] for name in PINNED_FILES], len(PINNED_FILES))
    if pinned is None:
        raise SystemExit("prompt_lines.json does not pin by sha256 exactly " + ", ".join(PINNED_FILES))
    files_sha256: dict[str, str] = dict(zip(PINNED_FILES, pinned, strict=True))
    raw_models = object_of(held.get("models"))
    if not raw_models:
        raise SystemExit("prompt_lines.json holds no model")
    models = {name: model_from(name, m, (pass_lines, template, files_sha256[COUNTS])) for name, m in raw_models.items()}
    raw_better = held.get("better_from")
    better = [name_of(v) for v in cast(list[object], raw_better)] if isinstance(raw_better, list) else []
    better_from = frozenset(name for name in better if name is not None)
    if not better or len(better_from) != len(better) or not better_from <= set(models):
        raise SystemExit("prompt_lines.json: better_from does not list, each once, models the file holds")
    return Lines(pass_lines, template, files_sha256, width_of(held, "worse_sigmas"), width_of(held, "better_sigmas"),
                 better_from, models)


def once(pairs: list[tuple[str, object]]) -> JsonObject:
    """A JSON object of `pairs`. SystemExit when a key is written twice: the later value would be the
    one read, and the earlier one would stay in the file unread."""
    held = dict(pairs)
    if len(held) != len(pairs):
        raise SystemExit("prompt_lines.json writes a key twice in one object")
    return held


def pinned_lines() -> Lines:
    """prompt_lines.json, read once it pins the present files of the comparison and was fixed under the
    present pass lines. SystemExit otherwise."""
    lines = lines_of(json.loads(PROMPT_LINES.read_text(encoding="utf-8"), object_pairs_hook=once))
    changed = [name for name, pinned in lines.files_sha256.items() if pinned != sha256_file(HERE / name)]
    if changed:
        raise SystemExit("prompt_lines.json pins another version of " + ", ".join(changed))
    if sha256_file(V.PASS_LINES) != lines.pass_lines_sha256:
        raise SystemExit("prompt_lines.json was fixed under other pass lines")
    return lines


def model_of(lines: Lines, name: str) -> ModelLines:
    model = lines.models.get(name)
    if model is None:
        raise SystemExit(f"prompt_lines.json names no model {name}")
    return model
