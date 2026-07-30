---
status: reference
last_verified: 2026-07-30
code_refs:
  - lib/keeper/keeper_librarian.ml
  - lib/keeper/keeper_memory_os_current.ml
  - lib/keeper/keeper_memory_os_recall.ml
---

# Memory Systems

MASC owns durable domain memory. OAS owns the active transcript, checkpoint,
and context reduction. MASC does not create an OAS memory object and neither
side derives memory from a model-authored state envelope.

## Stores

| Store | Owner | Purpose |
|---|---|---|
| OAS checkpoint/context | OAS | active transcript and restartable agent context |
| Memory OS current snapshot | MASC | current claims selected by the librarian plus explicit writes |
| Procedural memory | MASC | verified reusable procedures |
| Tool/history logs | MASC | observable evidence and recall source |

Memory OS snapshot path:
`<base-path>/.masc/keepers/<keeper_name>.memory.json`.
A missing snapshot means fresh empty state. Memory OS does not import, migrate,
or fall back to alternate store layouts.

## Write Contract

A memory claim must come from an explicit memory operation or the librarian
lane's typed result. Every claim carries exact trace/turn provenance and, when
the cited message contains one, its exact tool-call identity. The librarian
parser rejects provenance outside the supplied message slice. The complete
snapshot carries its revision, source trace/generation, and exact
added/removed/retained delta.

Assistant reply text is never parsed into goal, progress, future work,
questions, constraints, or any other memory category. An ordinary reply may
remain in OAS checkpoint history, but it cannot become durable MASC memory
without an explicit memory boundary.

Write failures return or record an explicit error. The caller must not present
the memory as saved when persistence failed.

The snapshot reader is current-shape strict. A malformed or unknown field makes
that Keeper's Memory OS projection unavailable; it is never decoded as an empty
or partial store. The affected Keeper may continue other work, while recall,
health, and dashboard surfaces report the read failure explicitly.

## Recall Contract

Recall reads the same current snapshot projected by the dashboard and injects
every claim in stored order; it does not rank, trim, or apply a count/byte
budget. A malformed snapshot is reported as recall unavailable rather than
silently treated as empty memory.

The runtime may inject selected memory into a future prompt as context. That
context is advisory and cannot mutate task, goal, lifecycle, HITL, connector,
or scheduler state.

## Compaction

OAS reduces active context through its checkpoint/context APIs. MASC may
request a configured strategy and observe the outcome, but must not rewrite
the transcript through domain-specific text parsing.

The librarian LLM returns retained current claim IDs and new claims. Omission
removes a current claim. Deterministic code validates the exact schema and
claim identities, then atomically replaces the snapshot only if its observed
revision still matches. No threshold, priority score, recency rule, or
capacity heuristic decides which memories survive.

## Generation and Handoff

A Keeper rollover commits a new OAS checkpoint first, then advances the MASC
generation/trace lineage. Long-term memory remains in its MASC store. There is
no reply-derived short-term cache and no prose replay sidecar.

See:

- [Keeper State Ownership](../KEEPER-STATE-OWNERSHIP.md)
- [OAS/MASC Boundary](../OAS-MASC-BOUNDARY.md)
- [Keeper Continuity Validation](../KEEPER-CONTINUITY-VALIDATION.md)
