# pyright: strict
"""What prompt_lines.json fixes for a prompt comparison (RFC-0517 §2.3), as `prompt_compare.py` reads it.

The file is committed before a draft runs. It fixes the pass lines and the template of the baseline,
the noise widths, the models whose improvement can justify adoption, the sha256 of the files that
compare (`files_sha256`), and for each model how many runs a side takes and its baseline:

    "inkling": {"provider": ..., "model": ..., "runs": 2,
                "baseline": {"pass_lines_sha256": ..., "template_sha256": ..., "prompt_counts_sha256": ...,
                             "counts": {"synth_valid_rate": [hits, chances], ...},
                             "real_record": [{"agree": ..., "candidates": ..., "dropped_not_in_live": ...}, ...],
                             "synth_rows_sha256": [...], "real_rows_sha256": [...]}}

A baseline is what the model's runs of the pinned template counted, kept as numbers: each metric's
hits over chances summed over the runs and, for each run in order, its E-real record and the sha256
of its E-synth and E-real rows. `prompt_compare.py baseline` prints it. It is null until the model's
runs are counted. A baseline names the pass lines, the template and the prompt_counts.py it was
counted under. When the file pins another of them the baseline is stale and the file is refused:
set the baseline to null, count the model's runs again with `prompt_compare.py baseline`, and pin
what it prints.
"""

from __future__ import annotations

import json
import math
import re
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
BASELINE_KEYS = frozenset({"pass_lines_sha256", "template_sha256", "prompt_counts_sha256", "counts", "real_record",
                           "synth_rows_sha256", "real_rows_sha256"})
REAL_RECORD_KEYS = ("agree", "candidates", "dropped_not_in_live")


@dataclass(frozen=True, slots=True)
class Baseline:
    """What a model's runs of the pinned template counted, and what they were counted under: the pass
    lines, the template and the prompt_counts.py, each metric summed over the runs, and for each run
    in order its E-real record and the sha256 of its E-synth and E-real rows."""

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
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not 0 <= value < math.inf:
        raise SystemExit(f"prompt_lines.json: {key} is not a finite number of at least zero")
    return float(value)


def real_record_from(raw: object) -> RealRecord | None:
    """One run's E-real record as prompt_lines.json holds it; None when it is anything else."""
    if not isinstance(raw, dict):
        return None
    held = cast(dict[str, object], raw)
    values = ints_of([held.get(k) for k in REAL_RECORD_KEYS], len(REAL_RECORD_KEYS))
    if values is None or set(held) != set(REAL_RECORD_KEYS) or values[0] > values[1]:
        return None
    return RealRecord(*values)


def baseline_from(name: str, runs: int, raw: object) -> Baseline:
    """The baseline prompt_lines.json holds for the model `name`, which takes `runs` runs a side.
    SystemExit unless it names what it was counted under, counts every metric as hits within chances,
    and holds an E-real record and the sha256 of each set's rows for each run."""

    def refused(why: str) -> SystemExit:
        return SystemExit(f"prompt_lines.json: the {name} baseline {why}")

    if not isinstance(raw, dict) or frozenset(cast(dict[str, object], raw)) != BASELINE_KEYS:
        raise refused("does not hold exactly " + ", ".join(sorted(BASELINE_KEYS)))
    held = cast(dict[str, object], raw)
    under = hashes_of([held["pass_lines_sha256"], held["template_sha256"], held["prompt_counts_sha256"]], 3)
    if under is None:
        raise refused("does not name by sha256 the pass lines, the template and the prompt_counts.py it was "
                      "counted under")
    raw_counts = held["counts"]
    if not isinstance(raw_counts, dict) or set(cast(dict[str, object], raw_counts)) != {m.value for m in Metric}:
        raise refused("does not hold one count for each metric")
    counts: dict[Metric, Count] = {}
    for metric in Metric:
        pair = ints_of(cast(dict[str, object], raw_counts)[metric.value], 2)
        if pair is None or pair[0] > pair[1]:
            raise refused(f"does not count {metric.value} as hits within chances")
        counts[metric] = Count(pair[0], pair[1])
    raw_records = held["real_record"]
    records = [real_record_from(r) for r in cast(list[object], raw_records)] if isinstance(raw_records, list) else []
    known = tuple(r for r in records if r is not None)
    synth, real = hashes_of(held["synth_rows_sha256"], runs), hashes_of(held["real_rows_sha256"], runs)
    if len(known) != runs or len(records) != runs or synth is None or real is None:
        raise refused(f"does not hold an E-real record and the sha256 of each set's rows for each of its {runs} runs")
    return Baseline(under[0], under[1], under[2], counts, known, synth, real)


def baseline_json(baseline: Baseline) -> JsonObject:
    """`baseline` as prompt_lines.json holds it; `baseline_from` reads it back."""
    return {"pass_lines_sha256": baseline.pass_lines_sha256, "template_sha256": baseline.template_sha256,
            "prompt_counts_sha256": baseline.prompt_counts_sha256,
            "counts": {m.value: [baseline.counts[m].hits, baseline.counts[m].chances] for m in Metric},
            "real_record": [asdict(r) for r in baseline.real_record],
            "synth_rows_sha256": list(baseline.synth_rows_sha256),
            "real_rows_sha256": list(baseline.real_rows_sha256)}


def lines_of(raw: JsonObject) -> Lines:
    """prompt_lines.json as the comparison reads it. SystemExit when it is of another schema, does not
    name by sha256 the pass lines, the template and exactly the pinned files, a width is not a finite
    number of at least zero, a model takes no run, a baseline is malformed or was counted under
    something the file no longer pins, the rows of one run are named twice, or `better_from` names a
    model the file does not hold."""
    if raw.get("schema") != SCHEMA:
        raise SystemExit(f"prompt_lines.json is not of schema {SCHEMA}")
    under = hashes_of([raw.get("pass_lines_sha256"), raw.get("baseline_template_sha256")], 2)
    if under is None:
        raise SystemExit("prompt_lines.json does not name by sha256 the pass lines and the template of the baseline")
    pass_lines, template = under
    raw_files = raw.get("files_sha256")
    files = cast(dict[str, object], raw_files) if isinstance(raw_files, dict) else {}
    pinned = hashes_of([files.get(name) for name in PINNED_FILES], len(PINNED_FILES))
    if pinned is None or set(files) != set(PINNED_FILES):
        raise SystemExit("prompt_lines.json does not pin by sha256 exactly " + ", ".join(PINNED_FILES))
    files_sha256: dict[str, str] = dict(zip(PINNED_FILES, pinned, strict=True))
    models: dict[str, ModelLines] = {}
    for name, m in cast(dict[str, JsonObject], raw["models"]).items():
        runs = m.get("runs")
        if not isinstance(runs, int) or isinstance(runs, bool) or runs < 1:
            raise SystemExit(f"prompt_lines.json: {name} takes no run")
        if "baseline" not in m:
            raise SystemExit(f"prompt_lines.json: {name} holds no baseline, pinned or null")
        baseline = None if m["baseline"] is None else baseline_from(name, runs, m["baseline"])
        if baseline is not None and (baseline.pass_lines_sha256, baseline.template_sha256,
                                     baseline.prompt_counts_sha256) != (pass_lines, template, files_sha256[COUNTS]):
            raise SystemExit(f"prompt_lines.json: the {name} baseline was counted under other pass lines, another "
                             "template or another prompt_counts.py than the file pins")
        models[name] = ModelLines(cast(str, m["provider"]), cast(str, m["model"]), runs, baseline)
    rows = [h for m in models.values() if m.baseline is not None
            for h in (*m.baseline.synth_rows_sha256, *m.baseline.real_rows_sha256)]
    if len(set(rows)) != len(rows):
        raise SystemExit("prompt_lines.json names the rows of one run twice")
    better_from = frozenset(cast(list[str], raw["better_from"]))
    if not better_from <= set(models):
        raise SystemExit("prompt_lines.json: better_from names a model the file does not hold")
    return Lines(pass_lines, template, files_sha256, width_of(raw, "worse_sigmas"), width_of(raw, "better_sigmas"),
                 better_from, models)


def pinned_lines() -> Lines:
    """prompt_lines.json, read once it pins the present files of the comparison and was fixed under the
    present pass lines. SystemExit otherwise."""
    lines = lines_of(cast(JsonObject, json.loads(PROMPT_LINES.read_text(encoding="utf-8"))))
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
