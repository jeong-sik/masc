# pyright: basic
"""Judged E-synth counts of the pass-time research runs, set against the pinned baseline. Numbers only.

    uv run --python 3.12 --with openai==3.46.0 time_judged.py \
        --scripts <harness scripts/tinker/librarian> --runs judged-runs.json [--root <runs folder>] \
        [--expect <prompt_lines.json>] [--out judged.json]

<judged-runs.json>: {"baseline": {"<label>": [{"synth": <dir>, "drops": <dir or null>,
"merges": <dir or null>}, ...]}, "drafts": {"<label>": [...]}, "contrasts": [[<draft>, <baseline>], ...]}.
Paths are relative to `--root` (default: the folder the file sits two levels under), or absolute.

`prompt_compare.py compare` cannot read these runs: the research harness copy has its own pass lines
sha256, and a draft here has no finished E-real run for each E-synth run. This script counts the
E-synth half of `prompt_counts.measure` with the same functions (`audit_decisions`, `merge_decisions`,
`synth_counts`) and leaves `real_valid_rate` out. Run on the baseline's own run folders it must print
the counts prompt_lines.json pins for them; `--expect <prompt_lines.json>` checks that and stops
when a count differs.

A contrast prints d and d/σ with σ = sqrt(p(1-p)(1/n1 + 1/n2)), p the pooled rate, the formula of
prompt_compare.py.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Any


def load(scripts: str):
    sys.path.insert(0, scripts)
    import audit_decisions as D  # noqa: PLC0415  # pyright: ignore[reportMissingImports]
    import merge_decisions as MD  # noqa: PLC0415  # pyright: ignore[reportMissingImports]
    import prompt_counts as C  # noqa: PLC0415  # pyright: ignore[reportMissingImports]
    import synth_render  # noqa: PLC0415  # pyright: ignore[reportMissingImports]

    return D, MD, C, synth_render


def synth_half(mods, synth: Path, drops: Path | None, merges: Path | None) -> dict[str, tuple[int, int]]:
    """The E-synth counts of one run, as `prompt_counts.measure` counts them before its E-real half."""
    D, MD, C, synth_render = mods
    summary = C.summary_of(synth)
    names = list(summary.targets)
    if summary.kind != "synth" or summary.stopped is not None or len(names) != 1:
        raise SystemExit(f"{synth} is not a finished E-synth run with one target")
    target = names[0]
    read = C.read_rows(synth, C.synth_row_of)
    shown = [(row, row.for_judges()) for row in read.rows]
    rows = [as_json for _, as_json in shown]
    off = D.off_label(rows)
    if off and drops is None:
        raise SystemExit(f"{synth} has off-label drops and no drop judge's folder")
    judged = D.read_adjudication(drops, off, synth_render.TEMPLATE) if off and drops else D.NO_DROPS
    scored = [(row, as_json) for row, as_json in shown if judged.scored([as_json])]
    mine = [row for row, _ in scored if row.target == target]
    if not mine:
        raise SystemExit(f"the judge's drops leave none of {synth} to score")
    numbers = MD.for_run(rows, merges, synth_render.TEMPLATE, synth).numbers(
        rows, [as_json for _, as_json in scored], target)
    counts = C.synth_counts(mine, judged.wrong_outside(rows).get(target, 0), numbers)
    return {str(metric): (count.hits, count.chances) for metric, count in counts.items()}


def sigma(a: tuple[int, int], b: tuple[int, int]) -> tuple[float, float] | None:
    if not a[1] or not b[1]:
        return None
    d = a[0] / a[1] - b[0] / b[1]
    p = (a[0] + b[0]) / (a[1] + b[1])
    s = math.sqrt(p * (1 - p) * (1 / a[1] + 1 / b[1]))
    return d, (d / s if s else math.inf if d else 0.0)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--scripts", required=True)
    parser.add_argument("--runs", required=True)
    parser.add_argument("--root", default=None)
    parser.add_argument("--expect", default=None)
    parser.add_argument("--out", default=None)
    args = parser.parse_args()
    mods = load(args.scripts)
    config_path = Path(args.runs).resolve()
    root = config_path.parent.parent if args.root is None else Path(args.root).resolve()
    config = json.loads(config_path.read_text(encoding="utf-8"))

    def at(value: str | None) -> Path | None:
        return None if value is None else (Path(value) if Path(value).is_absolute() else root / value)

    sides: dict[str, dict[str, tuple[int, int]]] = {}
    per_run: dict[str, list[dict[str, Any]]] = {}
    for kind in ("baseline", "drafts"):
        for label, runs in config.get(kind, {}).items():
            total: dict[str, tuple[int, int]] = {}
            listed = []
            for run in runs:
                synth = at(run["synth"])
                assert synth is not None
                counts = synth_half(mods, synth, at(run.get("drops")), at(run.get("merges")))
                listed.append({"synth": run["synth"], "counts": counts})
                for name, pair in counts.items():
                    before = total.get(name, (0, 0))
                    total[name] = (before[0] + pair[0], before[1] + pair[1])
            sides[label] = total
            per_run[label] = listed
            print(label, " ".join(f"{name} {pair[0]}/{pair[1]}" for name, pair in total.items()))
    if args.expect is not None:
        pinned = json.loads(Path(args.expect).read_text(encoding="utf-8"))["models"]
        for label, model in config.get("expect", {}).items():
            want = pinned[model]["baseline"]["counts"]
            for name, pair in sides[label].items():
                held = want[name]
                if tuple(held) != pair:
                    raise SystemExit(f"{label} {name}: counted {pair}, pinned {held}")
            print(f"{label}: equals the pinned baseline of {model}")
    contrasts = []
    for draft, base in config.get("contrasts", []):
        parts = []
        line: dict[str, Any] = {"draft": draft, "baseline": base}
        for name, pair in sides[draft].items():
            found = sigma(pair, sides[base][name])
            if found is None:
                continue
            line[name] = {"d": round(found[0], 4), "sigmas": round(found[1], 2), "draft": list(pair),
                          "baseline": list(sides[base][name])}
            parts.append(f"{name} {found[0]:+.3f} ({found[1]:+.1f}σ)")
        contrasts.append(line)
        print(f"{draft} vs {base}: " + ", ".join(parts))
    if args.out is not None:
        Path(args.out).write_text(json.dumps({"runs": per_run, "sides": sides, "contrasts": contrasts},
                                             ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
