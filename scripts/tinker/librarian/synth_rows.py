# pyright: strict
"""A synthetic request as one row of requests.jsonl, written and read back.

`row_of` writes a request the way `synth_generate.py` stores it. `parts_of` reads
a row's facts and candidates back into `synth_spec` types, and `label_of_row`
gives the row's label: `synth_spec.labeled` over those parts. A row stores no
label of its own, so its label cannot disagree with its request.

`parts_of` reads only rows the generator can write. Memory IDs, claims and
request IDs are unique. A correction, complement or paraphrase targets one fact
that is neither planted stale nor one of a duplicate pair, and no two candidates
share a target; the other kinds target nothing. A planted duplicate restates
another durable fact that is not a duplicate itself, and no other duplicate
restates that fact.
"""

from __future__ import annotations

from dataclasses import asdict
from typing import cast

import synth_spec as S

type JsonObject = dict[str, object]
type Parts = tuple[tuple[S.MemoryFact, ...], tuple[S.Candidate, ...]]

FACT_FIELDS = frozenset({"memory_id", "claim", "category", "board", "seen_at", "planted_stale", "duplicate_of"})
CANDIDATE_FIELDS = frozenset({"request_id", "sequence", "claim", "category", "seen_at", "board", "trace_id", "kind",
                              "target_memory_id"})
BOARD_FIELDS = frozenset({"post_id", "comment_id"})
KINDS = {kind.value: kind for kind in S.CandidateKind}
TARGETED = frozenset({S.CandidateKind.CORRECTION, S.CandidateKind.COMPLEMENT, S.CandidateKind.PARAPHRASE})


def board_row(board: S.BoardRef | None) -> JsonObject | None:
    return None if board is None else {"post_id": board.post_id, "comment_id": board.comment_id}


def row_of(request: S.SynthRequest) -> JsonObject:
    """The request as requests.jsonl stores it. The goal is stored as the goal_context text MASC shows."""
    return {
        "item_id": request.item_id, "keeper": asdict(request.keeper),
        "facts": [{"memory_id": f.memory_id, "claim": f.claim, "category": f.category, "board": board_row(f.board),
                   "seen_at": f.seen_at, "planted_stale": f.planted_stale, "duplicate_of": f.duplicate_of}
                  for f in request.facts],
        "candidates": [{"request_id": c.request_id, "sequence": c.sequence, "claim": c.claim, "category": c.category,
                        "seen_at": c.seen_at, "board": board_row(c.board), "trace_id": c.trace_id,
                        "kind": c.kind.value, "target_memory_id": c.target_memory_id}
                       for c in request.candidates],
        "goal_context": S.goal_json(request.goal)}


def fields(value: object, names: frozenset[str]) -> JsonObject | None:
    """The object when it has exactly the fields `names`."""
    if isinstance(value, dict) and frozenset(cast(JsonObject, value)) == names:
        return cast(JsonObject, value)
    return None


def board_of(value: object) -> S.BoardRef | None:
    """A board reference as `board_row` writes it, or None when the value is not one."""
    obj = fields(value, BOARD_FIELDS)
    if obj is None:
        return None
    post, comment = obj["post_id"], obj["comment_id"]
    return S.BoardRef(post, comment) if isinstance(post, str) and (comment is None or isinstance(comment, str)) else None


def fact_of(value: object) -> S.MemoryFact | None:
    obj = fields(value, FACT_FIELDS)
    if obj is None:
        return None
    mid, claim, category, seen = obj["memory_id"], obj["claim"], obj["category"], obj["seen_at"]
    raw_board, stale, restates = obj["board"], obj["planted_stale"], obj["duplicate_of"]
    board = board_of(raw_board)
    if (isinstance(mid, str) and isinstance(claim, str) and isinstance(category, str) and isinstance(seen, str)
            and isinstance(stale, bool) and (restates is None or isinstance(restates, str))
            and (raw_board is None or board is not None)):
        return S.MemoryFact(mid, claim, category, board, seen, stale, restates)
    return None


def candidate_of(value: object) -> S.Candidate | None:
    obj = fields(value, CANDIDATE_FIELDS)
    if obj is None:
        return None
    rid, sequence, claim, category = obj["request_id"], obj["sequence"], obj["claim"], obj["category"]
    seen, raw_board, trace, target = obj["seen_at"], obj["board"], obj["trace_id"], obj["target_memory_id"]
    kind = KINDS.get(obj["kind"]) if isinstance(obj["kind"], str) else None
    board = board_of(raw_board)
    if (isinstance(rid, str) and isinstance(sequence, int) and not isinstance(sequence, bool)
            and isinstance(claim, str) and isinstance(category, str) and isinstance(seen, float)
            and isinstance(trace, str) and kind is not None and (target is None or isinstance(target, str))
            and (raw_board is None or board is not None)):
        return S.Candidate(rid, sequence, claim, category, seen, board, trace, kind, target)
    return None


def holds(facts: tuple[S.MemoryFact, ...], candidates: tuple[S.Candidate, ...]) -> bool:
    """Whether facts and candidates have the shape the generator writes (see the module docstring)."""
    by_id = {f.memory_id: f for f in facts}
    restated = [f.duplicate_of for f in facts if f.duplicate_of is not None]
    paired = set(restated) | {f.memory_id for f in facts if f.duplicate_of is not None}
    targets = [c.target_memory_id for c in candidates if c.target_memory_id is not None]

    def restates_durable(fact: S.MemoryFact, original: str) -> bool:
        source = by_id.get(original)
        return (source is not None and not fact.planted_stale
                and not source.planted_stale and source.duplicate_of is None)
    return (len(by_id) == len(facts) and len({f.claim for f in facts}) == len(facts)
            and len({c.request_id for c in candidates}) == len(candidates)
            and len(set(restated)) == len(restated)
            and all(restates_durable(f, f.duplicate_of) for f in facts if f.duplicate_of is not None)
            and all((c.target_memory_id is not None) == (c.kind in TARGETED) for c in candidates)
            and len(set(targets)) == len(targets)
            and all(t in by_id and not by_id[t].planted_stale and t not in paired for t in targets))


def parts_of(request: object) -> Parts | None:
    """The facts and candidates of a request row, or None unless the generator can write the row."""
    if not isinstance(request, dict):
        return None
    obj = cast(JsonObject, request)
    raw_facts, raw_candidates = obj.get("facts"), obj.get("candidates")
    if not (isinstance(raw_facts, list) and isinstance(raw_candidates, list)):
        return None
    read_facts = [fact_of(f) for f in cast(list[object], raw_facts)]
    read_candidates = [candidate_of(c) for c in cast(list[object], raw_candidates)]
    facts = tuple(f for f in read_facts if f is not None)
    candidates = tuple(c for c in read_candidates if c is not None)
    if len(facts) != len(read_facts) or len(candidates) != len(read_candidates) or not holds(facts, candidates):
        return None
    return facts, candidates


def label_of_row(request: object) -> S.RequestLabel | None:
    """The label of a request row, or None unless the generator can write the row."""
    parts = parts_of(request)
    return S.labeled(*parts) if parts is not None else None
