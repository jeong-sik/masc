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
| Memory OS current snapshot | MASC | supported current claims from librarian updates and direct writes, minus exact retractions |
| Shared Wiki (`.masc/wiki/`) | MASC | workspace-wide Markdown pages, revision log, and structural lint surface |
| Workspace Memory Ledger & Briefing (`.masc/workspace-memory/`) | MASC | shared cross-Keeper memory ledger (`ledger.json`) and curator briefing (`briefing.json`) |
| Tool/history logs | MASC | observable evidence and recall source |

Memory OS snapshot path:
`<resolved-config-root>/keepers/<keeper_name>.memory-current.json`.
`Config_dir_resolver.keepers_dir_for_base_path` resolves that directory; the
default is `<base-path>/.masc/config/keepers`, and a configured `MASC_CONFIG_DIR`
changes the config root.
A missing snapshot means fresh empty state. Memory OS does not import, migrate,
or fall back to alternate store layouts. A commit is on disk when its line is
appended to `<keeper_name>.memory-log.jsonl`. The snapshot is written after the
line and from it, so it is at most one line behind, and the next boot writes it
again from that line (`Librarian_store`).

## Context delivery evidence

World observations are rendered as typed layers by `Keeper_context_layers`.
The renderer keeps an immutable text value with ordered raw UTF-8 spans and
SHA-256 digests. The world-frame prefix, direct-turn context, unprojected input,
and appended host workspace recall are explicitly unattributed; a heading or
similar sentence does not assign them to a world layer. Each layer is rendered
once for that value. Projection for the actual offered tools produces a new
value instead of reusing the preliminary observation's partition.

The `masc.logical-context-partition.v2` assembly receipt can attach a
`masc.dynamic-context-partition.v1` subpartition to the Dynamic_context block
only when its exact text matches the renderer-issued value. Missing or stale
subpartitions are unavailable, not measured zero-byte layers. Raw UTF-8 offsets
are relative to their source text, distinct from encoded message and IPC JSON
offsets.

These receipts alone describe source assembly. Codex's completed input-slot
binding joins the selected source spans to the actual submitted slot. A
Dynamic_context span inside an omitted-held carrier describes locally omitted
input, not bytes delivered on that request. Tool history, server acceptance,
remote retention and remote ejection are outside this proof. The partition
does not change layer relevance or independently omit individual world layers.

## Write Contract

A memory claim must come from an explicit memory operation or the librarian
lane's typed result. An explicit `keeper_memory_write` without `source_path`,
or a `keeper_memory_retract`, is a direct write to the Keeper's Memory writer:
no model is asked, and the outcome is a pure function of current Memory and
the write (`Librarian_direct`). A write with `source_path` goes to the
source-bound store (`Keeper_memory_source_current`).

A fact stores its exact claim text, typed category,
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

Speaker provenance reaches the Librarian through the rows of the
producer-owned durable stores that a turn-log unit names
(`Librarian_unit_content`). Direct user rows come from `Keeper_chat_store`;
connector input also
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

Recall reads the same current snapshot projected by the dashboard and injects
it as a digest compiled by `Keeper_memory_digest`: derived facts first, then
category and `memory_id` order, bounded to 8 KiB
(`default_max_rendered_bytes`). Facts beyond the bound are summarized with a
pointer to `keeper_memory_search`. The digest bytes stay identical until the
snapshot revision advances. A malformed snapshot is reported as unavailable
rather than silently treated as empty memory.

Explicit Memory OS search answers in two tiers. First come the claims that
hold the whole query as one run of text, in store order. Then come the claims
that hold any query term, ordered by the BM25 score of a SQLite FTS5 trigram
index (`Keeper_memory_search_index`); when the index cannot be built, that
tier keeps store order. It does not reorder facts by timestamp.
It returns exact fact identities and derivation support. The
`keeper_memory_retract` tool accepts one of those ordinary-current identities
plus a non-empty reason, atomically removes it, and records every derived fact
invalidated by the resulting support fixed point. Source-bound facts remain a
separate exact-bytes store and are not accepted by this retraction surface.

The Admin batch cleanup boundary
(`POST /api/v1/keepers/:name/memory/retractions`) accepts exactly `plan_id` and
non-empty `retractions: [{memory_id, reason}]`. Each retraction is one direct
write to the Keeper's Memory writer on the trace `plan_id`, in request order.
The answer lists each one as `retracted` or `not_current`. The first
retraction the writer does not take ends the request with
`code=memory_unwritable`; the retractions answered before it stay committed.

The Working Context cleanup boundary
(`POST /api/v1/keepers/:name/working-context/source-retractions`) additionally
requires `expected_generation`, `expected_revision`, and
`expected_snapshot_sha256`. The hash binds an Admin plan to the exact bytes
that were reviewed.

Search with `source="absorbed"` or `source="dropped"` reads historical
removals from `<keeper_name>.memory-log.jsonl` (and compacted cold archive
`<keeper_name>.memory-archive.jsonl`) via `Keeper_memory_left`. Absorbed
results carry `store="absorbed_memory"`, the successor identity `into`, and
`into_current` checked against current memory. `source="all"` combines current
facts, absorbed/dropped rows, and history with identities kept distinct.

The runtime may inject selected memory into a future prompt as context. That
context is advisory and cannot mutate task, goal, lifecycle, HITL, connector,
or scheduler state.

## Librarian disposition

Each Keeper has a single Memory writer (`Librarian_writer` / `Librarian_store`)
owning `<keeper_name>.memory-log.jsonl` and `<keeper_name>.memory-current.json`
(RFC `librarian-call-only-proposes-and-one-writer-per-keeper-commits-in-one-line`).
Model calls propose structured operations (`Librarian_answer`); the writer
validates and applies them deterministically, appends one commit line to
`<keeper_name>.memory-log.jsonl`, and atomically rewrites the current snapshot.
Direct writes (`keeper_memory_write`, `keeper_memory_retract`, and operator
cleanup) go through the same single writer. Unmentioned facts are retained
subject to derivation support; derived facts whose premises disappear are
removed as `Support_lost` and recorded in `change.invalidated`. No priority
score, recency rule, or silent eviction heuristic decides which memories
survive; structural growth triggers proactive `Molt_and_synthesize` rounds.

## Committed revision lineage

Applied `Revised_into`, `Superseded_by`, `Merged_into`, and `Retracted` effects
are recorded directly on each committed line in
`<keeper_name>.memory-log.jsonl`. Read-only dashboard and TUI surfaces
(`Keeper_memory_activity`, `memory-facts`, `memory-journal`, and TUI v2
`/api/v1/memory/diff`) project lineage directly from the commit log.

## Shared Wiki System

MASC provides a workspace-shared Wiki under `<base-path>/.masc/wiki/` (`lib/tool_wiki.ml`, `lib/wiki_page.ml`, and `lib/wiki_lint.ml`,
exposed through `masc_wiki_*` and `keeper_wiki_*` tools and `masc://wiki/*`
MCP resources). Pages are Markdown documents with structured frontmatter, slugs,
and revision history (`log.md`).

- **Search**: `masc_wiki_search` / `keeper_wiki_search` support multi-word
  queries and enforce word-boundary matching on short tokens (`<= 2` ASCII
  characters) to prevent noisy substring hits.
- **Resource tail**: `masc://wiki/log` returns the last 64 KiB of `log.md`,
  starting at a line boundary, when the revision log exceeds 64 KiB.
- **Structural lint (`masc_wiki_lint`)**: inspects the wiki graph and revision
  log for 9 finding kinds (`broken_link`, `unsupported_link`, `orphan`,
  `orphan_unconfirmed`, `missing_sources`, `hearsay_only`, `unreadable_page`,
  `revision_log_gap`, `revision_log_hole`) and reports `revision_log_hole_suppressed`
  when known historical log gaps are explicitly suppressed.

## Workspace Memory Ledger and Curator Briefing

Beyond per-Keeper Memory OS snapshots, MASC maintains a workspace-level memory
ledger and curator briefing under `<base-path>/.masc/workspace-memory/`:

- `ledger.json`: durable workspace memory claims and cross-Keeper provenance
  managed through `lib/workspace_memory/`.
- `briefing.json`: structured workspace briefing synthesized by the in-process
  Workspace Memory Curator (`lib/server/server_workspace_memory_curator.ml`)
  from the ledger's claims and conflicts.

Both files use strict atomic replacement and strict schema decoding. Malformed
state is an error; a missing file reads as empty.

## See also

- [Keeper State Ownership](../KEEPER-STATE-OWNERSHIP.md)
- [agent core/MASC Boundary](../AGENT-CORE-BOUNDARY.md)
