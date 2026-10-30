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
| Memory OS current snapshot | MASC | supported current claims from librarian updates and admitted writes, minus exact retractions |
| Memory OS admission queue & WAL | MASC | durable pending candidates from explicit `keeper_memory_write` operations awaiting Librarian consolidation |
| Shared Wiki (`.masc/wiki/`) | MASC | workspace-wide Markdown pages, revision log, and structural lint surface |
| Workspace Memory Ledger & Briefing (`.masc/workspace-memory/`) | MASC | shared cross-Keeper memory ledger (`ledger.json`) and curator briefing (`briefing.json`) |
| Tool/history logs | MASC | observable evidence and recall source |

Memory OS snapshot path:
`<resolved-config-root>/keepers/<keeper_name>.memory-current.json`.
`Config_dir_resolver.keepers_dir_for_base_path` resolves that directory; the
default is `<base-path>/.masc/config/keepers`, and a configured `MASC_CONFIG_DIR`
changes the config root.
A missing snapshot means fresh empty state. Memory OS does not import, migrate,
or fall back to alternate store layouts. All durable snapshot, WAL, and sidecar
replacements enforce strict file + parent-directory `fsync` and publication
recovery before reporting commit success.

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
lane's typed result. When the Librarian lane is enabled (the default), explicit
`keeper_memory_write` calls do not mutate `memory-current.json` directly: they
append a durable observed candidate to the Librarian admission queue so the
Librarian can deduplicate, absorb, or supersede against current memory before
recall. Direct immediate writes to `memory-current.json` occur only when the
Librarian lane is explicitly disabled or via a superseding/retracting
maintenance boundary. A fact stores its exact claim text, typed category,
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

The Admin batch cleanup boundary additionally requires the exact current
revision and snapshot SHA-256. It writes a prepared plan receipt binding the
prior/target snapshot identities to every exact retraction reason before
replacing the snapshot. HTTP success means the matching journal entry is
durable and the receipt has been cleared. If interruption
or an I/O failure occurs after replacement, the response identifies the
committed revision and hash with `snapshot_committed=true`; the next locked
writer reconciles the exact entry without duplication before another snapshot
change. Whole-Keeper purge removes an unfinished plan receipt with the other
Memory OS sidecars. A successful cleanup returns the newly written revision and
snapshot SHA-256, so a following reviewed plan does not need another inventory
read.

The exact-byte hash has different jobs in the two current stores. Ordinary
Memory has no generation; after a rejected snapshot is quarantined, revision 1
can exist again, so the hash prevents an old revision-1 plan from matching new
bytes. Working Context already changes generation on rebuild; its hash binds an
Admin plan to the exact bytes that were reviewed rather than adding another
lifecycle identity.

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
support. A fact removed because its derivation lost all support is recorded in
`change.invalidated` with its missing premise identities, the same support
fixed point that `keeper_memory_retract` records. There is no per-fact retain
response. Superseded identities must also be dropped; absorbed
identities must not be dropped. Unknown identities, duplicate dispositions,
and invalid schema values reject the answer (`Keeper_librarian`).
`working_contexts` is judged apart from these: when it is missing or fails the
pending-input check, the answer's Memory changes still commit, that pass
organizes nothing, and the run records `answer_missing` or `answer_refused`
as its `context_write`. `working_state` is read only when the pass carries a
continuity range, which requires nonblank text; a Memory pass without one
never reads it.

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

## Committed revision lineage

A declared revision relates a removed memory identity to a target present in
the committed snapshot. Applied Librarian revisions and explicit supersedes
writes record these links in the same recoverable removal transaction as the
snapshot change. The journal records explicit links on actual rewrites; a
no-change observation cannot create a revision transition. An unfinished
journal receipt is an unavailable evidence state until a writer recovers it.

A coherent read exposes the current snapshot and revision evidence after a
requested revision. Missing link metadata is unrecorded, not an inferred
relationship. The separate `Revised` events sidecar remains an observation
surface; its presence alone is not commit proof.

These links establish declared structural succession. They do not establish
that every historical input remains applicable to every successor. Demand
retrieval still needs a scope judgment before using a past observation to
select a revised current claim. Existing candidate consumption receipts stay
unchanged; a revision does not consume those candidates again.

## Admission lookup provenance

Deferred explicit writes judged `incorporated` or `already_represented` retain
an original-input-to-current-claim lookup binding. The original fact, its exact
candidate identity and the selected target identity commit through the same WAL
transaction as candidate consumption. `not_durable` and `deferred` judgments do
not create lookup bindings. A binding records the Librarian's declared relation;
it is not an independent semantic verification of that relation.

Current-memory search can match the original observation while returning the
current target's text and memory identity. `lookup_evidence` labels the original
observation as historical admission evidence, not a separate current claim.
Multiple observations pointing to one target produce one current search result.
These observations are search data, not an additional automatic prompt block.
The snapshot and its eligible bindings are read under the same store lock.

Bindings follow only the exact admitted target. A target's removal invalidates
its old bindings, including if identical text is subsequently re-added. Search
does not automatically transfer a binding to a replacement or split successor.
That transfer requires a future semantic decision about which successor retains
the observation's scope. Retention and recovery inherit the consumption receipt
store's snapshot and journal evidence requirements. Actual revision transitions
are distinguished from unchanged observations; an unchanged observation cannot
fill a missing transition when proving that a target was never retired.
The same holds when a binding commits: if Memory moved after the Librarian
read it, the journal must show every revision written since. A missing line
refuses the commit, and the input stays pending for a decision on current
Memory. Search over the current snapshot is not affected.

## Demand retrieval across revisions

A historical admission observation can locate a current successor through
explicitly committed revision edges. The reader follows chronological snapshot
transitions, including branches and multiple revisions. Missing transition
evidence is unresolved; retirement followed by unrelated identical-text
recreation does not revive a path. Structural candidates are not yet answers.

For a requested query, the successor selector judges whether the current target
addresses the same subject, event and applicable scope as the historical lookup
source. Corrected facts need not repeat the old content. For example, an old
owner-approval observation may locate today's two-approval rule for the same
release. The judgment receives the query, original observation and target,
committed path and current target. Keeper exclusions and the configured Jev
lane apply; the absorption feature switch does not control this retrieval.

The request and response are durably recorded before using a judgment. A second
coherent read must retain the exact candidate witness before publication. Current
result bodies and identities come from current targets, with historical lookup
provenance clearly separated. Multiple observations do not duplicate the same
current target in a result. Model failure, uncertain scope or changed evidence
leave additional retrieval explicitly unresolved while preserving direct matches;
they must not turn into an authoritative no-match answer.

## Shared Wiki System

MASC provides a workspace-shared Wiki under `<base-path>/.masc/wiki/` (`lib/tool_wiki.ml`, `lib/wiki_page.ml`, and `lib/wiki_lint.ml`,
exposed through `masc_wiki_*` and `keeper_wiki_*` tools and `masc://wiki/*`
MCP resources). Pages are Markdown documents with structured frontmatter, slugs,
and revision history (`log.jsonl`).

- **Search**: `masc_wiki_search` / `keeper_wiki_search` support multi-word
  queries and enforce word-boundary matching on short tokens (`<= 2` ASCII
  characters) to prevent noisy substring hits.
- **Resource tail**: `masc://wiki/log` returns a bounded 64 KiB UTF-8-safe tail
  of `log.jsonl` when the revision log exceeds 64 KiB.
- **Structural lint (`masc_wiki_lint`)**: inspects the wiki graph and revision
  log for 9 finding kinds (`broken_link`, `orphan_page`, `missing_summary`,
  `stale_source`, `unlinked_mention`, `empty_section`, `duplicate_title`,
  `unindexed_page`, `revision_log_hole`) and reports `revision_log_hole_suppressed`
  when known historical log gaps are explicitly suppressed.

## Workspace Memory Ledger and Curator Briefing

Beyond per-Keeper Memory OS snapshots, MASC maintains a workspace-level memory
ledger and curator briefing under `<base-path>/.masc/workspace-memory/`:

- `ledger.json`: durable workspace memory claims and cross-Keeper provenance
  managed through `lib/workspace_memory/`.
- `briefing.json`: structured workspace briefing synthesized by the
  installed Workspace Curator Addon’s `briefing` output from current workspace memory, active tasks/goals,
  and recent collaboration state.

Both files use atomic temp-file write + file/parent `fsync` and strict schema
decoding; malformed or missing curator state is reported explicitly rather than
silently fabricating an empty briefing.

## See also

- [Keeper State Ownership](../KEEPER-STATE-OWNERSHIP.md)
- [agent core/MASC Boundary](../AGENT-CORE-BOUNDARY.md)
- [Keeper Continuity Validation](../KEEPER-CONTINUITY-VALIDATION.md)
