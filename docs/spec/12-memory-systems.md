---
status: reference
---

# Memory Systems

MASC owns durable domain memory. agent core owns the active transcript, checkpoint,
and context reduction. MASC does not create an agent core memory object and neither
side derives memory from a model-authored state envelope.

## Stores

| Store | Owner | Purpose |
|---|---|---|
| agent core checkpoint/context | agent core | active transcript and restartable agent context |
| Memory OS current snapshot | MASC | current claims selected by the librarian plus explicit writes |
| Procedural memory | MASC | verified reusable procedures |
| Tool/history logs | MASC | observable evidence and recall source |

Memory OS snapshot path:
`<base-path>/.masc/keepers/<keeper_name>.memory-current.json`.
A missing snapshot means fresh empty state. Memory OS does not import, migrate,
or fall back to alternate store layouts.

## Write Contract

A memory claim must come from an explicit memory operation or the librarian
lane's typed result. A claim stores only its exact text, typed category, and
insertion timestamp. Its `memory_id` is the SHA-256 digest of the exact claim
bytes and is used only for retention references, duplicate rejection, recall
evidence, and observability. The complete snapshot carries its revision,
direct writer trace/generation, and exact added/removed/retained delta.

The same claim store owns durable counterpart and relationship knowledge. It
does not add a parallel people graph or a `person` category: the existing
category describes what kind of knowledge the sentence carries, while the
claim text keeps the stable actor reference and the Keeper-relative fact. An
external actor is anchored by the connector-authored
`channel + workspace_id + user_id` tuple; a display name is only a mutable
label. The authenticated owner/operator is a role when no external actor
identity exists. The librarian may retain an explicitly stated preference,
stable responsibility, ongoing commitment, or jointly validated history, but
must not infer a personality, sensitive trait, or motive from an isolated
exchange. A changed relationship is ordinary explicit replacement: drop the
superseded claim with a reason and add the corrected claim.

Speaker provenance reaches the Librarian through bounded recent projections of
the producer-owned durable stores, not by parsing the AGENT_CORE checkpoint
envelope. Direct user rows come from `Keeper_chat_store`; connector input also
comes from `Keeper_external_attention`, so a best-effort ambient chat append
failure cannot erase the original actor evidence. Duplicate connector/chat
projections are collapsed only by exact conversation and external-message IDs.
Each observation keeps host-authored `channel`, `workspace_id`, `user_id`,
`user_name`, and `authority` fields beside the untrusted `content`. This covers
ambient connector messages (which enter the Keeper turn as ephemeral world
context) and official-client turns (which return no AGENT_CORE checkpoint)
without persisting the whole world-observation frame as a user message.
Prompt-like text inside `content` cannot replace those typed fields and is
never an instruction to the Librarian. A direct message may also appear in
conversation history; its typed observation is the same evidence with
provenance attached, not a second occurrence supporting a repeated pattern.

The Librarian provider and the admin-only exact-run registry receive the same
raw bounded observations. This preserves the registry's exact-input contract,
but means the recent execution record is a second durable copy of counterpart
text and identifiers, just as it is for conversation history. Reducing that
copy requires a registry-wide retention or encrypted-reference design; this
feature does not introduce a Librarian-only exception to exact observability.

Current Memory OS recall is still Keeper-wide. Actor scoping is a semantic
Librarian/response contract, not a new audience filter or authorization gate:
one external actor's preference must not affect or be disclosed to another,
and no remembered relationship grants effect authority. A future typed
per-actor recall filter requires evidence of actual cross-actor leakage; this
change does not silently introduce one.

`Keeper_person_notes` remains a deliberate, keeper-authored annotation for the
surface roster (RFC-0229), not an automatic semantic-memory writer and not a
second Memory OS authority. There is no automatic migration or synchronization
between that UI annotation and current-memory claims.

Assistant reply text is never parsed into goal, progress, future work,
questions, constraints, or any other memory category. An ordinary reply may
remain in agent core checkpoint history, but it cannot become durable MASC memory
without an explicit memory boundary.

Write failures return or record an explicit error. The caller must not present
the memory as saved when persistence failed.

The snapshot reader is current-shape strict. A malformed or unknown field makes
that Keeper's Memory OS projection unavailable; it is never decoded as an empty
or partial store. The affected Keeper may continue other work, while recall,
health, and dashboard surfaces report the read failure explicitly.

## Recall Contract

Recall reads the same current snapshot projected by the dashboard and renders
every claim in stored order. It does not rank or trim individual claims. A
malformed snapshot is reported as unavailable rather than silently treated as
empty memory.

Explicit Memory OS search filters exact query substrings and preserves snapshot
order. It does not emit a relevance score or reorder facts by timestamp.

The runtime may inject selected memory into a future prompt as context. That
context is advisory and cannot mutate task, goal, lifecycle, HITL, connector,
or scheduler state.

## Compaction

agent core reduces active context through its checkpoint/context APIs. MASC may
request a configured strategy and observe the outcome, but must not rewrite
the transcript through domain-specific text parsing.

The librarian LLM returns exactly one retain/drop disposition for every current
memory ID plus any new claims. Missing or duplicate dispositions invalidate the
result. Deterministic code validates the exact schema and claim identities,
then atomically replaces the snapshot only if its observed revision still
matches. No threshold, priority score, recency rule, or capacity heuristic
decides which memories survive.

## Generation and Handoff

A Keeper rollover commits a new agent core checkpoint first, then advances the MASC
generation/trace lineage. Long-term memory remains in its MASC store. There is
no reply-derived short-term cache and no prose replay sidecar.

See:

- [Keeper State Ownership](../KEEPER-STATE-OWNERSHIP.md)
- [agent core/MASC Boundary](../AGENT-CORE-BOUNDARY.md)
- [Keeper Continuity Validation](../KEEPER-CONTINUITY-VALIDATION.md)
