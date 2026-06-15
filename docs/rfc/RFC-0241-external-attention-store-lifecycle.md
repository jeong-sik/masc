---
rfc: "0241"
title: "external-attention store lifecycle: read-side bound, retention, and typed tail-dedup"
status: Draft
created: 2026-06-15
updated: 2026-06-15
author: vincent
supersedes: []
superseded_by: null
related: ["0232"]
implementation_prs: []
---

# RFC-0241 — external-attention store lifecycle

## §1 Problem (evidence-grounded, measured)

`Keeper_external_attention` persists an append-only JSONL event log per
keeper at `<base_path>/.masc/external_attention/<sanitized-keeper>.jsonl`
(`lib/keeper/keeper_external_attention.ml:11`). Every inbound connector
message becomes a `Recorded` event; the keeper turn lifecycle later
appends `Claimed_for_turn`, `Resolved`, or `Ignored` events for the same
`event_id` (`lib/keeper/keeper_external_attention.ml:92-109`). The
projection in `pending_for_keeper` folds those events into a per-event
state and returns the pending set (`lib/keeper/keeper_external_attention.ml:541-587`).

A 2026-06-13 merge audit (F943) flagged two things on this store:
*unbounded growth* and a *tail-dedup correctness gap*. This RFC verifies
both premises against the code and the live store before proposing
anything, because the prior store-size RFC in this series (RFC-0238)
asserted a "1.4 GB unrotated grower" that turned out to be a
directory-total misattribution. Every size claim below is a per-file
`du -h` reading, not a directory total.

### 1.1 Growth premise — confirmed unbounded by construction, currently small

The four mutators only ever append; there is no rotation, prune,
truncate, retention, or compaction anywhere in the module:

```
$ rg -n "rotate|rotation|prune|max_bytes|max_size|truncate|compact" \
    lib/keeper/keeper_external_attention.ml lib/keeper/keeper_external_attention.mli
(no matches)
```

`record` appends `Recorded` (`:486`), `claim_for_turn` / `mark_resolved`
/ `mark_ignored` append via `append_many` (`:494-534`). A `Resolved` or
`Ignored` event marks an `event_id` terminal in the in-memory projection
(`:554-555`) but the bytes are never removed from disk. The store grows
monotonically with inbound connector traffic and never shrinks, even for
keepers whose every event is resolved.

This is not an inference about intent — PR #21124's own commit message
states it directly: *"The store still grows unbounded (no
prune/retention) — that is a separate retention-policy decision,
deliberately out of scope here."* (`git show 1d757c1dd`). The `.mli`
documents it too: *"The store is append-only and unbounded"*
(`lib/keeper/keeper_external_attention.mli:131-134`).

Measured live store (the only one present on this host, base path
`/Users/dancer/me` from the running `main_eio.exe --base-path=/Users/dancer/me`):

```
$ du -h /Users/dancer/me/.masc/external_attention/sangsu.jsonl
 12K	/Users/dancer/me/.masc/external_attention/sangsu.jsonl

$ wc -c < .../sangsu.jsonl     # 11146   (apparent bytes)
$ wc -l < .../sangsu.jsonl     # 17      (lines)
$ rg -o '"event":"[a-z_]+"' .../sangsu.jsonl | sort | uniq -c
  11 "event":"recorded"
   6 "event":"resolved"
```

Derived growth rate for this single keeper / single Discord connector
(`received_at` span 1781191592 → 1781438452 = 246,859 s ≈ 2.86 days):

| metric | value |
|---|---|
| non-blank lines | 17 |
| non-blank bytes | 11,129 |
| mean line size | ~654 B |
| recorded events | 11 |
| bytes/recorded-event (incl. its resolve) | ~1,012 B |
| bytes/day | ~3,895 B |
| days to fill the 64 KiB dedup window | ~16.8 |
| days to reach 1 MB | ~269 |

**Judgment.** The premise is *correct in direction* (the store is
structurally unbounded — no rotation exists) but *not* in magnitude: at
the observed single-keeper traffic this is ~3.9 KB/day, three orders of
magnitude below the RFC-0238-style "GB grower" framing. The risk is real
but it scales with deployment shape, not with wall-clock alone:

- **per-keeper file** — N keepers ⇒ N files growing in parallel.
- **connector fan-in** — a busy Slack/Discord channel set raises the
  recorded-events/day by the channel message rate, not by keeper count.
- **no terminal GC** — resolved/ignored events are dead weight that
  `pending_for_keeper` re-parses forever (§1.3).

So this RFC does *not* claim an active outage. It proposes bounding a
store that is unbounded by construction before it matters, and fixing the
two correctness/cost gaps that are independent of size.

### 1.2 tail-dedup correctness gap (file:line)

`record` dedups against only the last `dedup_window_bytes = 64 * 1024`
of the file, by design (`lib/keeper/keeper_external_attention.ml:31`,
`:481-488`). `load_recent_events` reads that tail slice and parses only
the bytes strictly between the first and last newline
(`lib/keeper/keeper_external_attention.ml:458-479`). Two distinct gaps
follow:

1. **Window-escape duplicate.** A redelivery of an `event_id` whose
   `Recorded` line is older than the 64 KiB tail is not found, so it is
   re-appended (`:483-488`). The module documents this as "rare,
   harmless" (`:137-141`). It is harmless for *Discord RESUME redelivery*
   (always recent) but the dedup contract is silently weaker than
   "dedup by `event_id`": it is "dedup by `event_id` *within the last
   64 KiB*". At ~3,895 B/day that window is ~16.8 days; a connector that
   redelivers older than that (manual replay, a backfill, a connector
   other than Discord with different replay semantics) produces a
   duplicate `Recorded` for the same `event_id`.

2. **Sparse-window false-accept.** When the 64 KiB slice contains fewer
   than two newlines, `load_recent_events` returns `[]`
   (`lib/keeper/keeper_external_attention.ml:475-479`) — no dedup at all,
   so the incoming record is always accepted. This is reachable whenever
   a single serialized event line is ≥ ~64 KiB (a large
   `content_preview`; the gateway puts the raw message `content` into
   `content_preview`, `lib/server/server_discord_in_process_gateway.ml:183`).
   One oversized line disables dedup for the next record.

Both gaps share a root: dedup is expressed as a **byte-window substring
scan over the serialized log**, not as a decision over a typed key set.
The window size is a performance knob that has leaked into the
correctness contract. The downstream effect of a duplicate `Recorded` is
bounded — `project_pending` keys by `event_id` and a second `Recorded`
for an already-`Terminal` id is ignored (`:545-549`) — but a duplicate
recorded *before* the first resolve produces a second pending projection
of the same external message, i.e. the keeper can be asked to attend to
one Discord message twice.

### 1.3 read-side cost gap (`pending_for_keeper` still O(file))

PR #21124 bounded the read on the *write* path (`record` →
`load_recent_events`, O(window)). It did **not** touch the read path:
`pending_for_keeper` calls `load_events`
(`lib/keeper/keeper_external_attention.ml:584`), which folds the entire
file via `fold_appended_lines ~from:0`
(`lib/keeper/keeper_external_attention.ml:401-416`). `pending_for_keeper`
runs on keeper turn admission, so a fully-resolved keeper still re-parses
every historical `Recorded`/`Resolved` line on every turn. Unbounded
growth therefore turns into unbounded *per-turn parse cost*, even when
the pending set is empty. This is the cost that actually bites first,
before disk size does, and it is the strongest argument for bounding the
store: an alarm (the read-drop counter) and a perf bound on `record`
exist, but the read-side O(file) re-parse does not.

## §2 Boundary (deterministic / heuristic / declarative split)

In scope (this RFC's spec surface):

- **Retention**: a bounded, deterministic on-disk size for the store.
- **read-side bound**: `pending_for_keeper` must not be O(total file)
  for a store dominated by terminal events.
- **typed tail-dedup**: replace the byte-window substring contract with
  an explicit, testable dedup decision.

Out of scope:

- The `Surface_ref` / `urgency` / `actor` vocabularies (RFC-0232 P5,
  unchanged).
- Adapter policy (which connector events become attention). The store is
  policy-neutral; this RFC keeps it so.
- The persistence read-drop counter and OTel surface
  (`lib/keeper/keeper_external_attention.ml:375-382`) — kept as-is; this
  RFC does not add a counter as a fix.
- No credential / identity / sandbox / operator-control surface is
  touched; RFC discovery gate is satisfied by relation to RFC-0232 only.

The store sits on a **protocol boundary** (connector ingress → durable
log → keeper projection). The lifecycle rules below validate at write
time and keep the read a deterministic fold of a bounded input.

## §3 Proposal

The three gaps are independent; each can ship as its own PR. They are
ordered by value: §3.1 (read bound) removes the cost that bites first,
§3.2 (retention) bounds the disk, §3.3 (typed dedup) closes the
correctness contract.

### 3.1 Compaction-on-read: bound the projection input to live events

`pending_for_keeper` does not need terminal events. After the projection
folds the log, every `event_id` that reached `Terminal` (Resolved /
Ignored) contributes nothing to any future pending result — a later
`Recorded` for a terminal id is ignored (`:545-549`), and there is no
"un-resolve" event. So terminal ids are permanently dead for the
projection.

Proposal: a deterministic, in-place **log compaction** keyed on the
projection's own terminal set, run opportunistically (e.g. when the file
exceeds a configured `compact_after_bytes`, checked at append time):

1. fold the full log once into the existing `projected_state` table
   (`lib/keeper/keeper_external_attention.ml:541-556`);
2. retain only events whose `event_id` is **not** `Terminal`, preserving
   on-disk order;
3. write the retained events to a temp file and atomically rename over
   the store (`Fs_compat` already provides atomic save primitives).

This is not a "cap on a symptom": the dropped bytes are provably
unreachable by the read model, so compaction is *semantics-preserving for
`pending_for_keeper`*. It bounds the store to "live (non-terminal)
events + events recorded since the last compaction", which is the working
set the projection actually consumes.

Trade-off: compaction loses the historical audit trail of resolved
attention from this file. If that trail has downstream consumers
(dashboard history, forensic replay), compaction must be gated behind a
retention window (§3.2) rather than dropping terminals immediately. The
choice between "drop terminals" and "keep a window" is the one real
design decision in this RFC and is called out for the owner in §6, not
silently picked.

### 3.2 Retention: a deterministic, configured on-disk bound

For the audit-trail case (and as a hard ceiling regardless of §3.1), add
a single declarative retention bound in `runtime.toml`, e.g.:

```toml
[keeper.external_attention]
# Compact the per-keeper log when it exceeds this many bytes. 0 disables.
compact_after_bytes = 1048576   # 1 MiB
# Keep terminal (resolved/ignored) events younger than this for audit.
# 0 = drop all terminals on compaction (no audit window).
retain_terminal_after_s = 604800   # 7 days
```

Both values are config (SSOT, no hardcoded literal in OCaml), `fail-fast`
on a malformed value, and named constants for the defaults. The bound is
*deterministic*: the same log + same config + same clock yields the same
post-compaction file. At the measured ~3,895 B/day a 1 MiB ceiling is
~269 days of single-keeper traffic, so compaction is rare in practice and
the cost is amortized.

This is the explicit answer to "unbounded growth": the store stays
append-only between compactions (cheap writes), and compaction enforces
an upper bound. It is a backpressure-free retention policy, not a
log-dedup/demote workaround.

### 3.3 Typed tail-dedup: replace the byte-window with an explicit decision

The current contract — "dedup by `event_id` within the last 64 KiB
substring" — couples a perf knob to correctness and has the
sparse-window false-accept (§1.2 gap 2). Replace it with a decision that
does not depend on serialized byte layout:

- Define dedup explicitly as: *suppress a `Recorded` whose `event_id`
  appears among the live (non-terminal) `event_id`s of this keeper's
  store.* This is the actual intent — a redelivery of an already-pending
  message — and it is independent of file size.
- After §3.1 compaction bounds the store to its live working set,
  `load_events` over the compacted file is O(working set), and dedup can
  scan the *full* compacted log instead of a byte window. The 64 KiB
  window and `load_recent_events`' first/last-newline slicing
  (`lib/keeper/keeper_external_attention.ml:458-479`) are then deletable:
  the bound moves from "scan a byte window of an unbounded file" to "scan
  a bounded file". This removes the sparse-window `[]` branch entirely
  (no false-accept) and the window-escape duplicate (no 16.8-day blind
  spot), because the dedup set is the live id set, not a tail of bytes.
- `dedupe_key` → `event_id` is already a pure function
  (`event_id_of_dedupe_key`, `:117-118`, SHA-256). Dedup stays a decision
  over typed keys (`string` `event_id`s held in a `Hashtbl`/`Set`), never
  a substring match over a JSON blob. This keeps it within the "no
  string/substring classifier" bar.

If §3.1 is *not* adopted (terminals kept forever), the window cannot be
removed without reintroducing O(file) dedup; in that case the minimum
correctness fix is to make the sparse-window branch fail-closed — when
the window yields no complete line, fall back to a full `load_events`
scan for that one record rather than silently accepting (`:475-479`).
This is a strict improvement (no false-accept) at the cost of an
occasional O(file) record. The owner should pick §3.1+full-scan dedup
(preferred) over window+fallback (minimal) in §6.

## §4 What this RFC deliberately does **not** do

Per CLAUDE.md §워크어라운드 거부 기준, the following are explicitly
rejected as non-fixes:

- **A drop/skip counter as the fix.** The read-drop counter already
  exists (`:375-382`); adding a "store-size" gauge would make growth
  *visible* without bounding it. Retention (§3.2) bounds it.
- **A string/substring tweak to the dedup scan** (e.g. widening the
  window to 128 KiB). That moves the blind spot, it does not remove it.
  §3.3 removes the byte-window contract.
- **A periodic external cron that `truncate`s the file.** That races the
  append path and can drop a live pending event. Compaction (§3.1) is
  in-process, atomic-rename, and semantics-preserving.

## §5 Validation

The lifecycle is deterministic (pure projection + bounded fold), so it is
property-testable without a live connector.

1. **Compaction preserves the pending set (§3.1).** Property: for any
   generated event sequence, `pending_for_keeper` over the raw log equals
   `pending_for_keeper` over the compacted log, for all `now` /
   `claim_stale_after`. This is the semantics-preserving claim made
   precise; a counterexample falsifies §3.1.
2. **Retention bound holds (§3.2).** After compaction the file size is
   ≤ `compact_after_bytes` + one max-line, and every retained terminal
   event is younger than `retain_terminal_after_s`. Property over random
   sequences + clocks.
3. **Dedup is size-independent (§3.3).** Property: recording the same
   `event_id` twice yields exactly one live projection, regardless of how
   many bytes separate the two records (including > 64 KiB apart and
   including an oversized intervening line — directly exercising the two
   §1.2 gaps). The existing `dedup_window_bytes` is exposed for tests
   (`:130-134`); the new test sizes input past it and asserts a single
   pending item, where today's code produces two.
4. **No terminal resurrection.** Property: once an `event_id` is
   `Resolved`/`Ignored`, no later `Recorded` for that id appears in
   `pending_for_keeper` (already true at `:545-549`; the test guards that
   compaction does not regress it).
5. **Build gates.** `dune build --root . @check` and `dune build
   --root .` exit 0. The dedup-window removal in §3.3 is compiler-checked:
   deleting `load_recent_events` / `dedup_window_bytes` fails the build at
   every caller until they route through the bounded `load_events`,
   proving full coverage (the same N-of-M-avoidance discipline as
   RFC-0237 §5).

A TLA+ model is *not* warranted here: the store is single-writer per
keeper file (append + atomic-rename compaction), with no multi-actor
concurrency protocol to model. The property tests above cover the safety
claims.

## §6 Owner decisions (called out, not silently picked)

1. **Audit trail vs. drop-terminals.** §3.1 can drop terminal events
   immediately (smallest store, no resolved-attention history in this
   file) or keep them for `retain_terminal_after_s` (audit window, larger
   store). Pick one; it determines whether §3.3 can delete the byte
   window outright or must keep a full-scan fallback.
2. **Default bounds.** `compact_after_bytes` (proposed 1 MiB ≈ 269
   single-keeper-days at measured rate) and `retain_terminal_after_s`
   (proposed 7 days). Owner sets the SSOT defaults.
3. **Ship order.** §3.1 (read bound) is the highest-value standalone PR
   and is safe on its own; §3.2 and §3.3 can follow. Confirm this order
   or reprioritize.

## §7 Alternatives considered

- **Do nothing (rely on #21124).** Rejected: #21124 bounded only the
  write path; `pending_for_keeper` is still O(file) (§1.3) and the store
  still grows without bound. The audit (F943) flagged exactly the part
  #21124 left open.
- **Widen the dedup window.** Rejected: §1.2 — moves the blind spot,
  keeps the sparse-window false-accept.
- **Switch the per-keeper JSONL to SQLite.** Rejected as over-scope: a
  storage-engine swap is a much larger change than bounding the existing
  log, and the projection is small enough that a bounded JSONL fold is
  adequate. Reconsider only if measured per-turn parse cost stays a
  bottleneck after §3.1.
- **Per-keeper external_attention dir rotation (`.1`, `.2` files).**
  Rejected: file rotation keeps terminals around in cold files and still
  requires reading them for dedup, reintroducing the O(history) problem
  compaction (§3.1) avoids.

## §8 Ledger note (non-blocking)

`docs/rfc/.next-number` is `0238` and RFC-0238/0239/0240 are not present
on disk. This RFC takes `0241` to match its pre-created branch
(`rfc/0241-external-attention-store-lifecycle`); the same commit advances
the ledger to `0242` so the allocator's `CURRENT > MAX_EXISTING`
invariant (`scripts/rfc-allocate-next.sh:49-52`) holds. The 0238-0240 gap
is intentional and monotonic (README §정책 permits gaps). The pre-existing
duplicate-number hygiene for RFC-0235/0236 (noted in RFC-0237 §8) is
unrelated and not addressed here.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
