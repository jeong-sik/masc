---
status: reference
last_verified: 2026-07-28
code_refs:
  - lib/keeper/keeper_memory_recall.ml
  - lib/keeper/keeper_librarian.ml
  - lib/keeper/keeper_memory_os_store.ml
---

# Memory Systems

MASC owns durable domain memory. OAS owns the active transcript, checkpoint,
and context reduction. MASC does not create an OAS memory object and neither
side derives memory from a model-authored state envelope.

## Stores

| Store | Owner | Purpose |
|---|---|---|
| OAS checkpoint/context | OAS | active transcript and restartable agent context |
| Memory OS fact store | MASC | durable claims with provenance (librarian + explicit writes) |
| Procedural memory | MASC | verified reusable procedures |
| Tool/history logs | MASC | observable evidence and recall source |

Memory OS fact store path:
`.masc/config/keepers/<keeper_name>.facts.jsonl`.

The legacy per-keeper memory bank (`.masc/keepers/<keeper_name>.memory.jsonl`
and its kind/horizon vocabulary) was removed
(RFC keeper-memory-consolidation Stage 4); keeper purge still deletes a
pre-removal file left on disk.

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

Memory OS fact rewriting is an explicit typed Memory operation. An LLM
librarian returns the keep, rewrite, or forget decisions; deterministic code
only validates their schema and provenance and atomically applies that exact
plan. Storage pressure is observable and may request the operation, but a
threshold, priority score, or capacity rule cannot decide which memories
survive.

## Generation and Handoff

A Keeper rollover commits a new OAS checkpoint first, then advances the MASC
generation/trace lineage. Long-term memory remains in its MASC store. There is
no reply-derived short-term cache and no prose replay sidecar.

See:

- [Keeper State Ownership](../KEEPER-STATE-OWNERSHIP.md)
- [OAS/MASC Boundary](../OAS-MASC-BOUNDARY.md)
- [Keeper Continuity Validation](../KEEPER-CONTINUITY-VALIDATION.md)
