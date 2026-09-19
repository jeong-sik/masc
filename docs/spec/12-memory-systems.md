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
| Memory OS current snapshot | MASC | supported current claims from librarian updates and explicit writes, minus exact retractions |
| Procedural memory | MASC | verified reusable procedures |
| Tool/history logs | MASC | observable evidence and recall source |

Memory OS snapshot path:
`<resolved-config-root>/keepers/<keeper_name>.memory-current.json`.
`Config_dir_resolver.keepers_dir_for_base_path` resolves that directory; the
default is `<base-path>/.masc/config/keepers`, and a configured `MASC_CONFIG_DIR`
changes the config root.
A missing snapshot means fresh empty state. Memory OS does not import, migrate,
or fall back to alternate store layouts.

## Write Contract

A memory claim must come from an explicit memory operation or the librarian
lane's typed result. A fact stores its exact claim text, typed category,
`first_seen` and `last_seen` timestamps, writer origin, and observed or derived
basis (`Keeper_memory_os_types.fact`). Its `memory_id` is the SHA-256 digest of the exact claim
bytes and is used for exact write receipts, derivation premises, duplicate
rejection, retraction, recall evidence, and observability. An observed fact has
no premises. A derived fact carries one or more typed derivations, each with an
opaque rule identity and exact premise identities; it remains current while at
least one complete derivation remains supported. The complete snapshot carries
its revision, direct writer trace, and exact added/removed/retained/invalidation
delta.

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
exchange. A changed relationship is two explicit operations: retract the
superseded claim by exact identity with a durable reason, then write the
corrected claim.

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
every supported claim in stored order. It does not rank, trim, or hide claims
behind a byte threshold. A malformed snapshot is reported as unavailable
rather than silently treated as empty memory.

Explicit Memory OS search filters case-insensitive query substrings and preserves snapshot
order. It does not emit a relevance score or reorder facts by timestamp.
It returns exact fact identities and derivation support. The
`keeper_memory_retract` tool accepts one of those ordinary-current identities
plus a non-empty reason, atomically removes it, and records every derived fact
invalidated by the resulting support fixed point. Source-bound facts remain a
separate exact-bytes store and are not accepted by this retraction surface.

Search with `source="absorbed"` reads facts a Librarian combined into another
claim from `<keeper_name>.memory-absorbed.jsonl`. These results carry
`store="absorbed_memory"`, the successor identity `into`, and `into_current`.
An archived fact is not a current derivation premise. An archive row alone does
not prove that the successor snapshot committed; `into_current` is checked
against current memory. `source="all"` includes the stores with those identities
kept distinct.

The runtime may inject selected memory into a future prompt as context. That
context is advisory and cannot mutate task, goal, lifecycle, HITL, connector,
or scheduler state.

## Librarian disposition

The Librarian returns changes: `new_claims`, explicit `dropped` statements,
and `working_contexts`. A new claim may name a `supersedes` identity or
`absorbs` identities. Unmentioned facts are retained subject to derivation
support; there is no per-fact retain response. Superseded identities must also be dropped; absorbed
identities must not be dropped. Unknown identities, duplicate dispositions,
and invalid schema values reject the answer (`Keeper_librarian`).

`Keeper_memory_os_current.apply_disposition` applies the changes to the current
snapshot under its write lock. A fact the Keeper wrote while the model was
answering is preserved unless the answer explicitly retires that identity
or its derivation loses all support;
an already-present new claim is not inserted twice. Absorbed facts are appended
to the archive before replacing the snapshot, and an archive write failure
fails the memory commit. A failed snapshot replacement can therefore leave an
archive row whose successor is not current. Working context has a separate
revision and does not roll back a memory commit. No threshold, priority score,
recency rule, or capacity heuristic decides which memories survive.

## Generation and Handoff

A Keeper rollover commits a new agent core checkpoint first, then advances the MASC
generation/trace lineage. Long-term memory remains in its MASC store. There is
no reply-derived short-term cache and no prose replay sidecar.

See:

- [Keeper State Ownership](../KEEPER-STATE-OWNERSHIP.md)
- [agent core/MASC Boundary](../AGENT-CORE-BOUNDARY.md)
- [Keeper Continuity Validation](../KEEPER-CONTINUITY-VALIDATION.md)
