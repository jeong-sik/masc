# pyright: strict
"""The `facts_budget` and `memory_limits` texts MASC derives from the current facts.

- `facts_budget_for`: keeper_librarian.ml:368-383 over keeper_memory_os_render.ml:20-37 lines
- `memory_limits_for`: keeper_memory_limits.ml `measure` then `to_json`
- `rfc3339_of_unix`: time_codec.ml:68

Pure: no I/O.
"""

from __future__ import annotations

import math
import time
from typing import assert_never

from prompt_facts import Board, CurrentBasis, CurrentMemory, PremisePaths, Transcript
from yojson_wire import (
    Json,
    JsonObject,
    write,
)


def rfc3339_of_unix(seconds: float) -> str:
    """time_codec.ml:68 `rfc3339_of_unix`: UTC, whole seconds (C cast truncation)."""
    tm = time.gmtime(math.trunc(seconds))
    return (
        f"{tm.tm_year:04d}-{tm.tm_mon:02d}-{tm.tm_mday:02d}T{tm.tm_hour:02d}:{tm.tm_min:02d}:{tm.tm_sec:02d}Z"
    )


def _basis_label(basis: CurrentBasis) -> str:
    match basis:
        case Transcript():
            return "observed"
        case Board(post_id=post_id, comment_id=None):
            return f"observed board={post_id}"
        case Board(post_id=post_id, comment_id=comment_id):
            return f"observed board={post_id} comment={comment_id}"
        case PremisePaths():
            return "derived"
        case _:
            assert_never(basis)


def utf8_length(text: str) -> int:
    """OCaml `String.length`: bytes, with lone surrogates as their 3-byte form."""
    return len(text.encode("utf-8", "surrogatepass"))


def facts_budget_for(facts_max_bytes: int, memory: CurrentMemory | None) -> str:
    """keeper_librarian.ml:368-383 with keeper_memory_os_render.ml:20-37 (no source lines)."""
    current = 0
    if memory is not None:
        lines = (
            f"- [category={fact.category} recorded={fact.first_seen} origin={fact.origin_kind}"
            f" basis={_basis_label(fact.basis)}] {fact.claim}"
            for fact in memory.facts
        )
        current = utf8_length("\n".join(lines))
    return f"max={facts_max_bytes} bytes; current ordinary={current} bytes"


def memory_limits_for(category_cap: int, facts_per_category_cap: int, memory: CurrentMemory | None) -> str:
    """keeper_memory_limits.ml `measure` then `to_json`, categories in byte order."""
    counts: dict[str, int] = {}
    for fact in memory.facts if memory is not None else ():
        counts[fact.category] = counts.get(fact.category, 0) + 1
    ordered = sorted(counts.items(), key=lambda item: item[0].encode("utf-8", "surrogatepass"))
    categories: tuple[Json, ...] = tuple(
        JsonObject(
            (("category", name), ("count", count), ("items_over_cap", max(0, count - facts_per_category_cap)))
        )
        for name, count in ordered
    )
    return write(
        JsonObject(
            (
                ("scope", "ordinary_current"),
                ("enforcement", "advisory"),
                ("category_cap", category_cap),
                ("facts_per_category_cap", facts_per_category_cap),
                ("category_count", len(ordered)),
                ("categories_over_cap", max(0, len(ordered) - category_cap)),
                ("categories", categories),
            )
        )
    )
