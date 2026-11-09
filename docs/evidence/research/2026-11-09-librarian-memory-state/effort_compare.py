# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Score teacher attempts (effort high) like G3, next to the base model (effort low). Prints numbers only.

    cd <checkout of tinker/librarian-drop-adjudication at 365233db560b>
    PYTHONDONTWRITEBYTECODE=1 uv run <this folder>/effort_compare.py

Teacher: every attempt on the train split with HTTP status 200, scored with
`eval_admission.score_synth`. Base: the rows of its run on the 144 requests
before the label audit, as `eval_admission.py run` wrote them. The two sets
differ: the lines compare efforts, not one set.

- valid: MASC's checks accept a complete reply (HTTP 200, finish_reason stop).
- accuracy: candidates scored correct over all candidates (an answer that is
  not valid is wrong); accuracy_valid_only over the candidates of valid answers.
- stale_recall: planted stale facts dropped over all planted.
- drop_precision: drops of planted stale facts or correction targets over all
  drops of valid answers.
- invalid: by finish_reason, and the checker's first problem for complete replies.
"""

from __future__ import annotations

import json
import statistics
from collections import Counter
from typing import cast

import stored as S

# (score_synth row, valid, completion tokens, wall seconds)
type Scored = tuple[S.JsonObject, bool, int, float]


def line(scored: list[Scored]) -> S.JsonObject:
    def total(key: str, valid_only: bool = False) -> int:
        return sum(cast(int, score[key]) for score, valid, _, _ in scored if valid or not valid_only)

    dropped = total("dropped")
    return {"requests": len(scored), "valid": round(sum(valid for _, valid, _, _ in scored) / len(scored), 3),
            "accuracy": round(total("correct") / total("candidates"), 3),
            "accuracy_valid_only": round(total("correct", True) / total("candidates", True), 3),
            "stale_recall": round(total("planted_dropped") / total("planted"), 3),
            "drop_precision": round(total("dropped_expected") / dropped, 3) if dropped else 1.0,
            "p50_completion_tokens": statistics.median(tokens for _, _, tokens, _ in scored),
            "p50_wall_s": round(statistics.median(wall for _, _, _, wall in scored), 3)}


def main() -> None:
    teacher: list[Scored] = []
    finish: Counter[str] = Counter()
    problems: Counter[str] = Counter()
    for item, call, chk in S.teacher():
        teacher.append((S.V.score_synth(item, chk.answer), chk.answer is not None, call.completion_tokens,
                        call.wall_s))
        if chk.answer is None:
            finish[str(call.finish)] += 1
            if call.answer() is not None:
                problems[chk.problems[0]] += 1
    print(json.dumps({"answers": "teacher effort high, train split attempts", **line(teacher),
                      "invalid_by_finish": dict(sorted(finish.items())),
                      "invalid_complete_replies_first_problem": dict(problems.most_common())}))
    base = [(row, cast(bool, row["valid"]), cast(int, row["completion_tokens"]), cast(float, row["wall_s"]))
            for row in S.rows(S.BASE_SYNTH / "rows.jsonl") if row["target"] == "base"]
    print(json.dumps({"answers": "base effort low, 144 requests before the label audit", **line(base)}))


main()
