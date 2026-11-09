# pyright: strict
"""Render a synthetic request as the admission prompt MASC would send.

The text around the variables is `config/prompts/librarian.md`, read the way
MASC reads it (`admission_request.template_from_markdown`). The variables come
from one `request` object of `synth_generate.py` output. Current facts carry
origin `injected` and candidates `authored`, as in every answered admission
record (6,562 of 6,571 current facts are `injected`). MASC writes first_seen and
last_seen equal, so both render from `seen_at`.
"""

from __future__ import annotations

import functools
from pathlib import Path
from typing import cast

import admission_request as R
import synth_spec as S

TEMPLATE = Path(__file__).resolve().parents[3] / "config" / "prompts" / "librarian.md"
# Every answered admission record shows "max=524288 bytes".
FACTS_MAX_BYTES = 524288

type JsonObject = dict[str, object]


def template_at(path: Path) -> R.AdmissionTemplate:
    """The admission template of the librarian.md at `path`. SystemExit when MASC could not use it."""
    loaded = R.template_from_markdown(path.read_text(encoding="utf-8"))
    if isinstance(loaded, R.TemplateError):
        raise SystemExit(f"{path}: {loaded.detail}")
    return loaded


@functools.cache
def template() -> R.AdmissionTemplate:
    return template_at(TEMPLATE)


def basis(board: object) -> R.Transcript | R.Board:
    if board is None:
        return R.Transcript()
    ref = cast(JsonObject, board)
    return R.Board(cast(str, ref["post_id"]), cast(str | None, ref["comment_id"]))


def prompt_of(request: JsonObject) -> R.AdmissionPrompt:
    keeper = cast(JsonObject, request["keeper"])
    memory = R.CurrentMemory(tuple(
        R.CurrentFact(cast(str, f["claim"]), cast(str, f["category"]), "injected", basis(f["board"]),
                      cast(str, f["seen_at"]), cast(str, f["seen_at"]))
        for f in cast(list[JsonObject], request["facts"])))
    candidates = tuple(
        R.Candidate(cast(str, c["request_id"]), cast(int, c["sequence"]), R.ProposedFact(
            cast(str, c["claim"]), cast(str, c["category"]), cast(float, c["seen_at"]), cast(float, c["seen_at"]),
            R.Origin("authored", cast(str, c["trace_id"])), basis(c["board"])))
        for c in cast(list[JsonObject], request["candidates"]))
    return R.AdmissionPrompt(
        template(), cast(str, keeper["keeper_id"]), cast(str, keeper["role_material"]),
        R.facts_budget_for(FACTS_MAX_BYTES, memory),
        R.memory_limits_for(S.CATEGORY_CAP, S.FACTS_PER_CATEGORY_CAP, memory),
        cast(str, request["goal_context"]), memory, candidates, None)
