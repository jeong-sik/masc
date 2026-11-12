# pyright: strict
"""Print the tables this folder's README shows, from counts.json (what baseline_counts.py printed).

    python3 tables.py counts.json

Prints Markdown tables, each under a line naming it in brackets: the pinned rows, each run's counts,
how each run's answers ended, its E-real record, what the judges said, and the counts at which a
draft with the baseline's chances turns worse or better. Stops when counts.json is the output of a
run baseline_counts.py ended with status 1: a model whose listed runs do not count its pinned
baseline, or runs that are not each its own sample.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import cast

type JsonObject = dict[str, object]

SHA_SHOWN = 12
METRICS = ("synth_valid_rate", "real_valid_rate", "memory_state_accuracy", "stale_drop_recall",
           "judged_merge_recall", "drop_precision", "absorb_precision")
SETS = (("E-synth", "synth_answers"), ("E-real", "real_answers"))
NONE = "—"


def rate(pair: object) -> str:
    hits, chances = cast(list[int], pair)
    return f"{hits}/{chances} = {hits / chances:.3f}" if chances else f"{hits}/{chances}"


def spread(counted: object) -> str:
    """`{"stop": 48, "length": 1}` as `stop 48, length 1`; `없음` for none."""
    parts = [f"{name} {n}" for name, n in cast(dict[str, int], counted).items()]
    return ", ".join(parts) if parts else "없음"


def short(sha: object) -> str:
    return NONE if sha is None else f"`{cast(str, sha)[:SHA_SHOWN]}…`"


def number(value: object) -> str:
    """A median as it is read: `2,193`, `2,016.5`, `23.6`; `—` for none."""
    return NONE if value is None else f"{cast(float, value):,.2f}".rstrip("0").rstrip(".")


def table(head: list[str], rows: list[list[str]]) -> str:
    lines = ["| " + " | ".join(head) + " |", "| " + " | ".join("---" for _ in head) + " |"]
    return "\n".join([*lines, *("| " + " | ".join(row) + " |" for row in rows)])


def pinned_models(counts: JsonObject) -> list[tuple[str, JsonObject]]:
    """(name, model) in the order counts.json holds them. SystemExit unless every model's listed runs
    count its pinned baseline and the runs are each its own sample."""
    models = cast(dict[str, JsonObject], counts["models"])
    unpinned = [name for name, model in models.items() if model["runs_are_the_pinned_ones"] is not True]
    if unpinned or counts["problem"] is not None:
        raise SystemExit("counts.json is not of pinned baselines: "
                         + (cast(str, counts["problem"]) if counts["problem"] is not None else ", ".join(unpinned)))
    return list(models.items())


def runs_of(models: list[tuple[str, JsonObject]]) -> list[tuple[str, JsonObject, JsonObject]]:
    """(label, model, run) for every listed run."""
    return [(f"{name} {n}", model, run) for name, model in models
            for n, run in enumerate(cast(list[JsonObject], model["runs"]), start=1)]


def pins(models: list[tuple[str, JsonObject]]) -> str:
    return table(["실행", "모델", "E-synth `rows.jsonl` sha256", "E-real `rows.jsonl` sha256"],
                 [[label, f"`{model['model']}`", short(run["synth_rows_sha256"]), short(run["real_rows_sha256"])]
                  for label, model, run in runs_of(models)])


def per_run(models: list[tuple[str, JsonObject]]) -> str:
    columns: list[tuple[str, JsonObject]] = []
    for name, model in models:
        listed = cast(list[JsonObject], model["runs"])
        if len(listed) > 1:
            columns += [(f"{name} {n}", cast(JsonObject, run["counts"])) for n, run in enumerate(listed, start=1)]
        columns.append((f"{name} 고정값", cast(JsonObject, cast(JsonObject, model["pinned"])["counts"])))
    return table(["지표", *(label for label, _ in columns)],
                 [[f"`{metric}`", *(rate(column[metric]) for _, column in columns)] for metric in METRICS])


def answers(models: list[tuple[str, JsonObject]]) -> str:
    rows: list[list[str]] = []
    for label, _, run in runs_of(models):
        for shown, key in SETS:
            got = cast(JsonObject, run[key])
            spent = got["run_spent_usd"]
            rows.append([label, shown, f"{got['valid']}/{got['items']}", str(got["answered"]), spread(got["status"]),
                         spread(got["finish"]), spread(got["invalid"]), number(got["completion_tokens_p50"]),
                         number(got["wall_s_p50"]), NONE if spent is None else f"${spent}"])
    return table(["실행", "세트", "유효/요청", "답한 호출", "HTTP", "답한 호출의 finish", "무효 사유", "답 토큰 p50", "초 p50",
                  "실행 전체 비용"], rows)


def real_record(models: list[tuple[str, JsonObject]]) -> str:
    rows: list[list[str]] = []
    for label, _, run in runs_of(models):
        record = cast(dict[str, int], run["real_record"])
        rows.append([label, rate([record["agree"], record["candidates"]]), str(record["dropped_not_in_live"])])
    return table(["실행", "라이브와 같은 판정", "라이브가 남긴 기억을 지운 수"], rows)


def judged(models: list[tuple[str, JsonObject]]) -> str:
    rows: list[list[str]] = []
    for label, _, run in runs_of(models):
        got = cast(JsonObject, run["judged"])
        rows.append([label, spread(got["off_label_drops"]), str(got["memories_left_out"]), spread(got["absorbs"]),
                     short(got["drops_decisions_sha256"]), short(got["merges_decisions_sha256"])])
    return table(["실행", "라벨 밖 지우기의 판정", "채점에서 빠진 기억", "흡수의 판정", "지우기 판정 파일 sha256",
                  "흡수 판정 파일 sha256"], rows)


def turns(models: list[tuple[str, JsonObject]]) -> str:
    rows: list[list[str]] = []
    for name, model in models:
        base = cast(JsonObject, cast(JsonObject, model["pinned"])["counts"])
        for metric in METRICS:
            turn = cast(JsonObject, cast(JsonObject, model["turns"])[metric])
            worse, better = turn["worse_at_most"], turn["better_at_least"]
            if turn["chances"] == 0:
                rows.append([name, f"`{metric}`", rate(base[metric]), "기회 없음", "기회 없음"])
                continue
            rows.append([name, f"`{metric}`", rate(base[metric]), "없음" if worse is None else f"{worse} 이하",
                         NONE if turn["admits"] is not True else "없음" if better is None else f"{better} 이상"])
    return table(["모델", "지표", "기준선", "나빠짐", "채택 근거가 되는 좋아짐"], rows)


def main() -> int:
    counts = cast(JsonObject, json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")))
    models = pinned_models(counts)
    for name, made in (("pins", pins), ("counts", per_run), ("answers", answers), ("real", real_record),
                       ("judged", judged), ("turns", turns)):
        print(f"[{name}]\n{made(models)}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
