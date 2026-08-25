---
rfc: "0375"
title: "Closed day-file projection cache — stop replaying the ledger per read"
status: Draft (not recommended as written — see §8)
created: 2026-08-13
updated: 2026-08-13
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0372", "0162", "0204"]
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
closed and its recorded byte boundary still lies within the file; otherwise fold it and
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

## §5.5 Measurement — which readers can benefit

§7's gating question ("does any current surface actually span enough closed
files to benefit?") was measured against a live workspace's stores before
any implementation. It changes the scope below.

Keeper metric stores, 8 of them:

| | value |
|---|---|
| day-files per store | min 1, median 16, max 17 |
| rows in the newest day-file | min 188, median 310, max 619 |
| `default_read_entries` | 100 |
| `latest_ts_probe_rows` | 64 |
| `max_read_entries` | 2 000 |

The tail-bounded readers stop once `n` rows are collected, walking day-files
newest-first. At the default window a store reads 101 rows against a newest
file holding 310, and the probe reads 64 — **neither reaches a closed
day-file at all.** A projection cache over closed files would have a 0 % hit
rate on the default dashboard read. An earlier draft of this RFC proposed
`latest_store_ts` as the smallest honest starting point; the measurement makes
it the worst candidate rather than the best, and §6 is corrected accordingly.

Only at `max_read_entries` (2 000, which a caller must ask for) does a store
span roughly six closed files.

So the premise "every request replays the ledger" is false for `read_recent`
callers: they replay the *tail*, bounded by `n`, and `load_tail_lines` already
reads only the bytes that tail needs.

Where it is true is `Dated_jsonl.read_range`, which has **no row bound at all**:

```ocaml
val read_range : t -> since:string -> until:string -> Yojson.Safe.t list
```

and `dashboard_harness_health.ml:181-183` fills a missing bound with
`"2020-01-01"` / `"2099-12-31"`, so a dashboard request supplying only `since`
scans every day-file in the store with no cap on rows. Six call sites use
`read_range`; two are dashboard surfaces.

That is a different defect from the one RFC-0372 §1 describes — there the bound
existed but scaled with store count; here there is no bound — and it is the
only place a closed-file projection cache would see a hit today.

## §6 Scope

Surfaces whose aggregate is a monoid **and** whose reads reach closed
day-files. After §5.5 that is a much smaller set than it first appeared:

- **In**: the `Dated_jsonl.read_range` callers, which scan a date range with no
  row bound. `dashboard_harness_health` is the surface that matters; the other
  four sites are eval and audit paths.
- **Out**: every `read_recent` caller at its default window, including
  `latest_store_ts` — measured at a 0 % closed-file hit rate. An earlier draft
  of this RFC named `latest_store_ts` as the starting point; the measurement
  says it is the one place this cannot help.

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
- What is the right boundary key? An earlier draft said `(path, size, mtime)`
  and claimed `count_entries` already bets on it. **It does not.** Its cache is
  `{ fc_boundary : int; fc_count : int }` — a byte offset and nothing else —
  and its contract handles change by shrinking rather than by detection: "a
  boundary past the current size (prune/rewrite) falls back to a full rescan,
  so the cached count never drifts". That works because a count over a prefix
  is reusable under append-only; a *projection* over a prefix is reusable the
  same way only if it is a monoid, which §3 already requires. So the boundary
  key question may reduce to the same offset, with no mtime involved. Confirm
  that before designing a richer key — and note that a same-size in-place
  rewrite stays undetected in both schemes, excluded by the append-only
  assumption rather than by the key.
- ~~Does any current surface actually span enough closed files to benefit?~~
  **Answered in §5.5: not the tail-bounded ones.** The remaining question is
  narrower — is `read_range`'s unbounded scan worth a projection cache, or
  worth a row bound? A bound is a smaller change and removes the cost rather
  than caching it. This RFC should not proceed until that is decided, because
  if `read_range` gains a bound the way `read_recent` has one, its callers stop
  reaching closed files too and nothing is left for this mechanism to do.

## §8 Status

Draft, and **not recommended for implementation as written**.

§5.5's measurement removed the motivating case: the tail-bounded readers never
reach a closed day-file at their default window, so the cache proposed here
would have a 0 % hit rate on the path that prompted it. What survives is a
single unbounded reader, `Dated_jsonl.read_range`, and the cheaper fix for that
is a row bound rather than a cache — RFC-0372's Phase 1 applied to the reader
it skipped.

Kept as a Draft rather than withdrawn because the mechanism is sound and
already proven here for `count_entries`; if a future surface does aggregate
across many closed files, this is the shape it should take. Reopening it
requires showing that surface exists first.
