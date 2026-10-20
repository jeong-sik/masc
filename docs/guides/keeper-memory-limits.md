# Keeper memory category and item limits

Configure the ordinary current working set in
`<resolved-config-root>/runtime.toml`:

```toml
[memory]
category_cap = 30
facts_per_category_cap = 30
```

Both values are positive integers. Built-in and custom categories share the
category limit. Only occupied categories count; each current fact is one item,
regardless of its sentence or token count. Source-bound facts have no category
and are outside these two counts. Archived originals and conversation history
are also outside the current working set.

The Librarian receives the limits, each category's count and its excess. It
chooses what to retain, merge with lineage, correct, or remove with a reason.
An excess is a request to make room, not permission to silently delete facts.
If safe consolidation is unavailable, the excess stays visible. Rare constraints
and personal knowledge have no age-based eviction rule.

`keeper_context_status.memory_limits` exposes the same report. During this
rollout, `enforcement=advisory` means the store accepts temporary excess; these
two settings do not reject writes. The existing aggregate rendered-byte commit
boundary is separate. There is no new token injection budget.

The existing Librarian lane checks for count overflow after boot catch-up,
post-turn and intake wakes. It can review current memory even with no unread
conversation. A successful decision on the same facts, current Goal context,
Keeper instructions, limits and prompt is not repeated on every wake; failures
remain retryable on the next wake.
Restart clears that observation and rechecks persisted Keepers, including ones
that did not launch. A committed partial consolidation requests another pass on
the same serialized lane when it reduces category excess or total per-category
item excess without increasing the other. Sleeping Keepers therefore continue
making room without needing another turn. Unchanged counts, mere rewrites and
failed decisions wait for a later wake; they do not trigger repeated cleanup.
The cleanup uses the regular disposition and absorption checks; it leaves
working contexts and history cursors untouched.

The settings registry seeds these keys at process startup. Restart after editing
this TOML; saving the file alone does not reload these values.
`MASC_KEEPER_MEMORY_CATEGORY_CAP` and
`MASC_KEEPER_MEMORY_FACTS_PER_CATEGORY_CAP` explicitly override TOML.

The current memory recall path already supplies a discovery notice and on-demand
retrieval, rather than injecting all stored facts. Lower counts can reduce the
memory presented to the Librarian; they do not by themselves prove fewer model
tokens. Measure actual inputs and recall quality before claiming a saving.

Historical lookup uses `keeper_memory_search(source="dropped")` for journaled
removals, or `source="absorbed"` for originals merged into newer claims.
`source="all"` includes both. Dropped results carry their original basis,
removal time, source and reason and are explicitly non-current. Retrieval does
not promote them. Revalidate original evidence before an explicit memory write;
the normal write path retains identity deduplication and truth maintenance.

The dropped corpus is derived from the complete removal journal, with latest
mentions and current membership excluding re-added facts. A broken journal
produces a retrieval failure (or partial-read metadata alongside other `all`
results), not a clean miss. A removal with an explicit reason prepares a recovery
receipt before replacing the current snapshot. If journal finalization fails,
the receipt retains the reason and the snapshot retains the complete original.
Later writers must finish that journal entry before replacing this evidence.
Search reports the pending archive explicitly until a writer recovers it.
All journal appenders and interrupted-tail recovery share a stable lock, so
recovery cannot truncate another process's live append. If a snapshot cannot
be decoded and is quarantined, its pending removal receipt moves aside first;
both files retain their original bytes while subsequent writes can start fresh.
This also covers explicit retractions and supersessions. Older missing journal
entries are not reconstructed; absence is still not proof that a fact never
existed. Entries without reason-bearing removals remain best-effort observations.

## Explicit memory writes

`keeper_memory_write` first saves the fact to the Keeper's pending admission
queue (`<keeper>.memory-admission.json`) and answers
`persisted_pending_admission`. The Librarian then judges pending rows against
current Memory and commits them. Each committed row leaves a receipt naming its
queue generation, sequence and payload digest, and acknowledgement removes
exactly the rows a receipt names. Nothing else removes a row, so a sequence
that has left the queue is committed history.

- Losing the receipt of such a sequence (for example in a receipt schema cut)
  does not hold back the rows that remain.
- A pending row whose receipt is lost is judged again against current Memory.
  Committing the same claim again refreshes the fact Memory already holds.
- While a committed receipt names a snapshot that is missing, undecodable or
  has other bytes, admission stops before judgment. Losing the snapshot loses
  the facts it held. Once an ordinary Librarian read reconciles the receipts
  against no snapshot, the remaining explicit writes start the new Memory, as
  durable and continuity input do. That read first copies every receipt it
  drops for lacking snapshot proof to `<keeper>.librarian-range-commit.json.rejected-<time>` with its
  reason; nothing reads or removes that file, so it stays until the operator
  deletes it. If the disk is full the copy cannot be written: the read fails,
  the receipts stay where they are, and explicit admission stays stopped until
  space is freed. The operator accepted this transition on 2026-10-20 (#44144).
