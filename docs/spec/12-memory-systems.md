---
status: reference
last_verified: 2026-07-10
code_refs:
  - lib/memory.ml
  - lib/keeper/keeper_memory_bank.ml
  - lib/keeper/keeper_memory_recall.ml
  - lib/keeper/keeper_librarian.ml
  - lib/context_compact_oas.ml
  - lib/institution_eio.ml
  - lib/procedural_memory.ml
---

# Memory Systems

MASC owns durable domain memory. OAS owns the active transcript, checkpoint,
and context reduction. MASC does not create an OAS memory object and neither
side derives memory from a model-authored state envelope.

## Stores

| Store | Owner | Purpose |
|---|---|---|
| OAS checkpoint/context | OAS | active transcript and restartable agent context |
| Keeper memory bank | MASC | explicitly selected durable notes with provenance |
| Institution memory | MASC | shared organizational knowledge and episodes |
| Procedural memory | MASC | verified reusable procedures |
| Tool/history logs | MASC | observable evidence and recall source |

Keeper memory bank path:
`.masc/keepers/<keeper_name>.memory.jsonl`.

## Write Contract

A memory record must come from an explicit memory operation, a typed tool
result selected by the memory policy, or the librarian lane's typed result.
Every durable row carries its Keeper/trace/turn provenance and source kind.

Assistant reply text is never parsed into goal, progress, future work,
questions, constraints, or any other memory category. An ordinary reply may
remain in OAS checkpoint history, but it cannot become durable MASC memory
without an explicit memory boundary.

Write failures return or record an explicit error. The caller must not present
the memory as saved when persistence failed.

## Recall Contract

Recall reads only the requested store and returns provenance alongside the
content. A missing store, malformed row, or unavailable backend is distinct
from an empty successful result.

The runtime may inject selected memory into a future prompt as context. That
context is advisory and cannot mutate task, goal, lifecycle, HITL, connector,
or scheduler state.

## Compaction

OAS reduces active context through its checkpoint/context APIs. MASC may
request a configured strategy and observe the outcome, but must not rewrite
the transcript through domain-specific text parsing.

Keeper memory-bank maintenance preserves provenance and reports malformed or
dropped records. An LLM librarian may classify or summarize candidates when a
semantic judgment is required; deterministic code may validate schemas,
enforce storage bounds, and order records by explicit timestamps.

## Generation and Handoff

A Keeper rollover commits a new OAS checkpoint first, then advances the MASC
generation/trace lineage. Long-term memory remains in its MASC store. There is
no reply-derived short-term cache and no prose replay sidecar.

See:

- [Keeper State Ownership](../KEEPER-STATE-OWNERSHIP.md)
- [OAS/MASC Boundary](../OAS-MASC-BOUNDARY.md)
- [Keeper Continuity Validation](../KEEPER-CONTINUITY-VALIDATION.md)
