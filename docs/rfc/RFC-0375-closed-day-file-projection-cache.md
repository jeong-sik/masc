---
rfc: "0375"
title: "Closed day-file projection cache — stop replaying the ledger per read"
status: Draft
created: 2026-08-13
updated: 2026-08-13
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0372", "0162", "0204"]
implementation_prs: []
---

# RFC-0375 — Closed day-file projection cache

## §0 What this is not

Not a new storage engine, not a database, not an event-sourcing framework. The
mechanism proposed here already exists in this repository, applied to exactly
one projection. This RFC is about generalising it.

`Dated_jsonl.count_entries` is backed by a per-file `(boundary, count)` cache.
Its own documentation states the property that matters:

> closed day-files are never re-read and the growing current-day file only
> re-reads the bytes appended since the previous call, so a call is
> `O(appended bytes)` — exact, no TTL staleness window (the RFC-0162 §3.2 TTL
> layer this replaced traded 10 s of staleness for a bound the incremental
> cache now provides structurally).

That replacement — a TTL cache retired in favour of an exact incremental one —
is the precedent this RFC extends from `count` to arbitrary projections.

## §1 The defect

Every dashboard read that is not a count re-reads and re-decodes its whole
window on every cache miss. The caching that exists is TTL-shaped:

| layer | shape | staleness |
|---|---|---|
| `Dashboard_cache.get_or_compute` | TTL + stale-grace (`ttl * 3`) | up to `4 * ttl` |
| `Dashboard_projection_cache` snapshot | TTL 3 s | 3 s |
| `Dashboard_projection_cache` digest | TTL 5 s | 5 s |
| `Dated_jsonl.count_entries` | incremental, per closed file | **none** |

A TTL cache converts "expensive per request" into "expensive per TTL", which
is the right first move and is why the dashboard is usable at all. It does not
change the cost of the miss, and the miss cost is what scales with the store.
The dashboard refresh interval and the TTLs are close enough that a warm
dashboard pays close to the full replay continuously.

The structural fact the TTL layer does not exploit: **a `Dated_jsonl` store is
append-only and date-partitioned, so every day-file except today's is
immutable.** A fold over a closed day-file is a pure function of that file. Its
result can be cached forever, with no staleness window at all, because the
input cannot change.

## §2 Why this is separate from RFC-0372

RFC-0372 bounds what a single read may *consume*: a per-request budget, a
ceiling on entries materialised, admission control. It makes an expensive read
cheap by making it read less.

This RFC makes a read cheap by not repeating work whose input did not change.
The two compose and neither substitutes for the other:

- 0372 alone: every request still re-derives the same answer from the same
  bytes, just fewer of them.
- 0375 alone: an unbounded request still materialises an unbounded result the
  first time.

0372 is the prerequisite in sequencing terms — a projection cache over an
unbounded read caches an unbounded value.

## §3 Proposal

### Phase 1 — a projection type over closed files

A projection is a fold with an identity, evaluated per day-file:

```ocaml
type ('acc, 'out) projection =
  { name : string          (* cache namespace; changing the fold changes this *)
  ; empty : 'acc
  ; add : 'acc -> Yojson.Safe.t -> 'acc
  ; merge : 'acc -> 'acc -> 'acc
  ; finish : 'acc -> 'out
  }
```

`merge` must be associative with `empty` as identity, because per-file results
are combined in file order. This is the constraint that makes per-file caching
sound, and it is the constraint that decides whether a given surface can use
this at all (see §6).

Evaluation: for each day-file in range, take the cached `'acc` if the file is
closed and its `(path, size, mtime)` boundary matches; otherwise fold it and
cache the result if it is closed. Fold today's file every time — or extend the
incremental suffix read `count_entries` already does.

### Phase 2 — migrate one surface, measured

Pick a surface whose projection is genuinely a monoid and whose window spans
many closed files. Keep the existing path, add the projected path behind a
comparison test that asserts both produce the same JSON on real stores, and
only then delete the old path.

### Phase 3 — current-day incremental suffix

Reuse `count_entries`'s trick for the open file: cache `(offset, 'acc)` and
fold only the bytes appended since. This is what removes the last `O(window)`
term, but it is separable and should not block Phase 2.

## §4 Verification

The gate is not latency. It is **equality plus recomputation count**:

1. **Equality** — for a seeded multi-day store, the projected result equals the
   result of folding every row directly. Property-based over row shape and day
   boundaries, not a fixture.
2. **Closed files are read once** — instrument the reader; a second call over
   an unchanged store must read zero bytes from closed files. This is the
   falsifiable claim; if it does not hold, the cache is not doing anything and
   the RFC has failed regardless of any timing number.
3. **A mutated closed file invalidates** — rewrite a past day-file and assert
   the projection changes. Guards the boundary key. A cache keyed on something
   that does not actually pin the content is worse than no cache: it returns
   confidently wrong data.
4. **No staleness window** — unlike a TTL, there is no interval in which a
   correct answer is knowingly withheld. A test that appends and immediately
   reads must observe the appended row.

RFC-0372 §5's `request_cost_gate.sh` remains the resource gate; this RFC does
not change what a single cold read costs and should not be measured on it.

## §5 What this costs

- **Memory**: one cached `'acc` per closed day-file per projection per store.
  Bounded by retention (day-files are pruned) but multiplied by projection
  count. Needs a ceiling and an eviction order; unbounded growth here would
  reintroduce the problem this is meant to solve, one level up.
- **Correctness surface**: a wrong `merge` is silent. Two surfaces disagreeing
  is a visible bug; a projection that is not associative produces an answer
  that is wrong only when the window happens to span a file boundary, which is
  the hardest kind of bug to see in review.
- **A second way to compute the same thing** during Phase 2, which is exactly
  the state RFC-0372's own history shows going stale. Phase 2 is not done until
  the old path is deleted.

## §6 Scope

Surfaces whose aggregate is a monoid: counts, sums, max/min timestamps,
histograms, top-N by a total order, set unions. `Telemetry_unified`'s
`latest_store_ts` probe is the smallest honest starting point — max over a
window, already isolated, already measured.

Surfaces that are **not** in scope without a reformulation: anything order-
dependent across the whole window (rate-limited logging over rows), anything
needing the newest *k* rows themselves rather than an aggregate of them, and
anything whose result depends on a filter supplied per request (the cache key
would have to include the filter, and the hit rate collapses).

## §7 Open questions

- Where does the cache live? `Dated_jsonl` owns the boundary logic already, but
  a projection is a caller concept and pushing arbitrary folds into the storage
  library inverts the dependency. A separate module over `Dated_jsonl`'s
  boundary primitive is likely correct; that primitive is currently private.
- How is a projection's cache invalidated when its *code* changes? `name`
  carries a version by convention, which is a convention that will be forgotten.
  Deriving it from something the compiler checks would be better; it is not
  obvious what.
- Is `(path, size, mtime)` a sufficient boundary key? `count_entries` already
  bets that it is. Same-second rewrites preserving size are the failure mode;
  whether that is reachable here needs an answer, not an assumption.
- Does any current surface actually span enough closed files to benefit? The
  dashboard's default windows are recent. If most reads are satisfied by
  today's file alone, Phase 3 is the whole value and Phases 1-2 are overhead —
  this should be measured before Phase 1 is written, not after.

## §8 Status

Draft. No implementation. §7's last question is a genuine gate on whether this
RFC should proceed at all, and it is answerable with a day of measurement
against real stores.
