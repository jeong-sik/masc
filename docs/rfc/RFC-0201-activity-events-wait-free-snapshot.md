---
RFC: 0201
Title: Activity events wait-free snapshot (RFC-0138 extension, file-base preserved)
Status: Draft
Author: Vincent (yousleepwhen)
Created: 2026-05-27
Depends on: RFC-0138
---

# RFC-0201 — Activity Events Wait-Free Snapshot

## 1. Problem (Measurement Surface)

Live measurement against running server (2026-05-27):

| Endpoint | Cold | Warm |
|---|---|---|
| `/api/v1/activity/events?limit=50` | 7.88 s | 8.52 s |
| `/api/v1/activity/graph` | 8.47 s | 4.75 s |
| `/api/v1/activity/swimlane` | 7.13 s | 6.03 s |
| `/api/v1/dashboard/namespace-truth` (RFC-0138) | 0.057 s | 0.057 s |
| `/api/v1/dashboard/shell` (RFC-0138) | 0.048 s | 0.048 s |

Cache state after measurement (`/api/v1/dashboard/cache-stats`):

- `hit_ratio: 0.428` (42.8 %)
- `fresh: 3 / entries: 78` — almost every entry expired or stale
- `activity:events:::*` keys absent — TTL 2 s expired before next poll

PR #19150 wrapped `events_http_json` / `graph_http_json` / `swimlane_http_json` in
`Dashboard_cache.get_or_compute ~ttl:2.0` + `Domain_pool_ref.submit_io_or_inline`.
The wrap works (build, code review pass), but TTL 2 s is shorter than the
underlying compute (7–8 s), so each panel poll re-enters a cold miss and the
HTTP fiber blocks on the compute.

## 2. Why the cache wrap (PR #19150) is mitigation, not root fix

`Activity_graph.json_response` calls `Activity_graph.list_events_with_meta`
which calls `read_all_events`:

```ocaml
let read_all_events config =
  collect_event_files config        (* ALL JSONL files in activity-events/YYYY-MM/ *)
  |> List.fold_left
       (fun acc path ->
         let content = repair_event_file_utf8_once config path in
         let lines = String.split_on_char '\n' content in
         let rows = List.filter_map parse_event_line lines in
         List.rev_append rows acc)
       []
  |> List.sort (fun a b -> Int.compare a.seq b.seq)
```

Each call:

1. Enumerates *every* `activity-events/YYYY-MM/DD.jsonl` file on disk.
2. Reads every file fully (no `mtime`/`since` filter at file level).
3. Splits, parses, and concatenates into a single in-memory list.
4. Sorts the full list by `seq`.

Concrete sizes today (`~/.masc/activity-events/2026-05/`):

```
01.jsonl  1.0 MB
03.jsonl  78 KB
14.jsonl  ...
18.jsonl  6.6 MB
25.jsonl  1.7 MB
27.jsonl  759 KB
```

Total ~15–20 MB of text per call. The `limit` parameter is applied *after*
the sort, so it does not reduce read cost. `since_ms` is an in-memory
post-filter, also after the read.

**File size + protocol are not the bottleneck.** Response payload is ~30 KB.
The HTTP/JSON layer is fine. The root is the read pattern in
`Activity_graph`.

This is the same root pattern RFC-0138 §2 identified for `/shell`, `/tools`,
`/namespace-truth`: handler-driven full recompute on every cache miss, with
a `Dashboard_cache` wrap that does not collapse the cost when concurrency
or TTL expiry exceeds the compute budget.

## 3. Constraint: file-base storage preserved

The activity event store is a **file-base append-only JSONL log**
(`activity-events/YYYY-MM/DD.jsonl`). This is intentional design:

- Append-only files are robust under crash (no DB recovery).
- JSONL rows are operator-readable and tail-able from a shell.
- One file per day keeps each immutable once the day rolls over.

This RFC **does not** propose:

- An in-memory event store replacing JSONL.
- A SQL/key-value database backing.
- Any new serialisation format.

The file layout stays as-is. What changes is *where* the read cost is paid.

## 4. Root Fix Proposal

Two cooperating changes. Each is independently mergeable; together they
deliver `< 50 ms` warm read latency at the same staleness budget as
existing RFC-0138 snapshot endpoints.

### 4.1 Phase A — Add activity to `Dashboard_snapshot`

Extend the existing `Dashboard_snapshot.t` record (RFC-0138 Phase 3) with a
new field carrying the default-params activity projection:

```ocaml
type t = {
  generated_at : float;
  generation : int;
  shell : Yojson.Safe.t;
  tools : Yojson.Safe.t;
  namespace_truth : Yojson.Safe.t;
  telemetry_summary : Yojson.Safe.t;
  activity_events_default : Yojson.Safe.t;  (* NEW *)
}
```

- `bootstrap ~config` and `refresh_loop` compute
  `Activity_graph.json_response ~kinds:[] ~after_seq:0 ~limit:200 ()`
  exactly the same way they compute `shell`/`tools` today.
- HTTP `events_http_json` checks: if `kinds = []` and `after_seq = 0` and
  `limit ∈ [50, 200]`, slice the snapshot's `activity_events_default`
  events list to the requested `limit` and return. This is the
  dashboard panel's actual query (no cursor, kind-less, limit 50).
- Non-default queries (cursor, kinds filter, `since`) fall through to the
  existing compute path. They are rare and operator-driven; paying
  inline cost is acceptable.

The snapshot publishes every `refresh_interval_sec` (currently 2 s). So:

- Worst-case staleness: 2 s + RTT.
- Worst-case HTTP latency: one `Atomic.get` + JSON slice + Yojson
  serialisation (~30 KB payload). Sub-millisecond expectation, matching
  `namespace-truth` observed 57 ms.

This handles `events_http_json` first. `graph_http_json` and
`swimlane_http_json` follow the same pattern; their `limit` knobs are
also bounded (50–2000 / 1–2000) so a single snapshot payload at the
max-limit value satisfies all in-bound requests via slicing.

### 4.2 Phase B — Incremental tail in `read_all_events` (optional, file-level)

Even with Phase A, the *refresh fiber* still runs `read_all_events` every
2 s. With 20 MB of historic JSONL this costs 7–8 s in the background; the
fiber will sometimes be one cycle behind, growing staleness from 2 s to
~10 s. Acceptable for v1, but addressable.

Phase B adds a file-level optimisation that respects the file-base
constraint:

1. **Past-day files are immutable.** Once the calendar day rolls over,
   `2026-05-18.jsonl` never gets more rows appended. Cache the parsed
   `event list` per past-day file in a process-local
   `(path, mtime, parsed) Hashtbl`. On each refresh, look up by
   `(path, mtime)`. If `mtime` matches, reuse the parsed list; only
   reparse the current-day file plus any new past-day files appearing.

2. **`collect_event_files` honours `since_ms`** at the file level: if
   `since_ms = Some now - 7d`, drop files whose `mtime` is older than
   that boundary. This narrows the *first-bootstrap* cost and matches
   the `?since` query semantics already exposed by `/activity/graph`.

This is a pure optimisation of an existing function. No new module, no
API change. Estimated 30–50 LoC in `activity_graph.ml`.

### 4.3 Why this is the right shape

| Property | RFC-0138 (shell, tools, …) | Activity (proposed) |
|---|---|---|
| Read path | `Atomic.get slot` + JSON projection | Same |
| Compute owner | One refresh fiber, every 2 s | Same |
| Storage | In-memory caches + Eio refs | **JSONL on disk (unchanged)** |
| Staleness budget | 2 s + poll RTT | 2 s + poll RTT |
| Concurrent readers | Wait-free, unbounded | Wait-free, unbounded |

The compute *source* differs (file vs. in-memory ref), but the *publication
shape* matches. File-base storage is preserved; the read cost is paid
once per snapshot interval, not once per HTTP request.

## 5. Migration sequence (do NOT batch)

| Step | What | Acceptance | PR |
|---|---|---|---|
| 1 | Extend `Dashboard_snapshot.t` with `activity_events_default` field; bootstrap and refresh fiber populate it; `events_http_json` reads from snapshot when query is default-shaped; non-default queries fall through. | Live cold/warm `events_http_json?limit=50` < 100 ms. | TBD |
| 2 | Extend snapshot with `activity_graph_default` and wire `graph_http_json` (same default-detection logic). | Live cold/warm `graph_http_json?limit=500` < 100 ms. | TBD |
| 3 | Extend snapshot with `activity_swimlane_default` and wire `swimlane_http_json`. | Live cold/warm `swimlane_http_json?limit=500` < 100 ms. | TBD |
| 4 | Phase B incremental tail: `read_all_events` caches past-day parsed lists by `(path, mtime)`. Only current-day file is re-parsed every refresh. | Refresh fiber single-cycle wall time < 500 ms with 15 MB historic data. | TBD |
| 5 | (Optional) Retire `Dashboard_cache` wrap from PR #19150 sites once snapshot read is observed in `cache-stats` for both default and non-default paths. | `cache-stats` shows zero `activity:events:::*` cache entries. | TBD |

Step 1 alone delivers the user-visible win (dashboard panel poll). Steps 2–3
extend the same pattern. Step 4 is internal optimisation. Step 5 is cleanup.

## 6. Trade-offs

| | Snapshot (proposed) | PR #19150 cache (status quo) |
|---|---|---|
| Read latency p99 | < 100 ms (Atomic.get + slice) | 7–8 s (cold) every TTL expiry |
| Compute frequency | 1 × every 2 s, one fiber | 1 × per cache miss × N clients |
| Default-query staleness | ≤ 2 s + RTT | undefined (depends on TTL vs poll cadence) |
| Non-default queries | Inline compute (unchanged) | Inline compute (unchanged) |
| Code surface | Snapshot record + handler branch | Cache wrap (already in tree) |

### Risks

1. **Refresh fiber takes 7–8 s on cold start.** During the first 7–8 s of
   server life, `bootstrap` runs synchronously on the first request fiber.
   This is identical to the current cold-start cost and not a regression.
   Phase B mitigates the *steady-state* refresh cost (past-day file parses
   become free on cache hit).

2. **`limit` mismatch between snapshot size and request.** Snapshot
   computes at `limit:200` (the dashboard's max useful page). If a
   request asks for `limit=500`, slicing returns only 200 — wrong answer.
   Mitigation: snapshot publishes at `limit:1000` (the API ceiling) and
   slicing trims down. Memory: ~120 KB per snapshot (1000 events × ~120 B).
   Cheaper than the 7 s compute it replaces.

3. **`after_seq` cursor requests bypass snapshot.** Cursor-bearing
   requests are rare (IDE replay, debug tooling) and re-running the
   full compute on each is acceptable.

4. **Snapshot stale during heavy event writes.** If keepers write 100
   events/s, snapshot is up to 2 s behind = 200 events behind. Dashboard
   already shows "last N events", so the visible delta is one frame. The
   `generated_at` field exposes the staleness so the UI can render a
   spinner if the operator drags it past a threshold.

## 7. Workaround Rejection Bar self-check

- [x] §1 counter-as-fix: NOT violated. This *replaces* the cache-miss
      latency with a measurable wait-free read; no new counter introduced.
- [x] §2 substring classifier: not used.
- [x] §3 N-of-M: each step migrates one endpoint (events / graph /
      swimlane) end-to-end. No partial fix.
- [x] catch-all `_ ->`: not added.
- [x] cap / cooldown / dedup: snapshot is a publication primitive, not a
      throttle.
- [x] test backdoor: any `*_for_test` helpers live behind a separate
      module and never on the production read path.
- [x] Same-typo-N-sites: the change pattern is captured in this RFC and
      executed via the migration table; no codemod needed because the
      shape is recorded explicitly.

## 8. Open Questions

1. **Snapshot `limit` ceiling?** API allows up to 1000 (events) / 2000
   (graph / swimlane). Choose snapshot ceiling = API max so slicing
   always succeeds. Memory cost negligible at 120–500 KB per field.

2. **Granularity of `kinds` filter in snapshot?** The current default
   query has `kinds = []` (no filter). Snapshot publishes the unfiltered
   stream; in-memory `List.filter` runs per request when a `kinds`
   query is present. Cheap (≤ 1000 events × `List.mem`). Acceptable as
   v1; revisit if profiling shows this dominates the HTTP fiber budget.

3. **`refresh_interval_sec` for activity vs. other RFC-0138 fields?**
   Currently single interval for the whole snapshot. If activity refresh
   cost dominates, consider per-field intervals (more complex). v1 keeps
   one interval.

4. **Phase B cache key on past-day files: `(path, mtime)` vs `(path,
   size, mtime)`?** `mtime` alone is sufficient on macOS/Linux for
   append-only files. Add `size` if any environment is known to backdate
   timestamps. v1 uses `(path, mtime)`.

## 9. Acceptance Criteria

The RFC is *complete* when:

- [ ] All three `/api/v1/activity/{events, graph, swimlane}` endpoints
      observe p99 latency < 100 ms (warm) / < 200 ms (cold) under sustained
      dashboard polling.
- [ ] `cache-stats` shows zero `activity:events:*` / `activity:graph:*` /
      `activity:swimlane:*` entries on the default-query read path.
- [ ] `Dashboard_snapshot.t` contains the three new fields and the
      refresh fiber publishes them every interval.
- [ ] Refresh-fiber single-cycle wall time < 500 ms with the current
      ~15 MB historic JSONL on disk (Phase B done).
- [ ] PR #19150's `Dashboard_cache` wrap is either retired or documented
      as non-default-query fallback only (Step 5).

## 10. Out of Scope (Future RFCs)

- **Streaming SSE for activity events.** Snapshot architecture is a
  prerequisite (single source of truth) but the streaming protocol
  design is separate.
- **Per-day sealed index files.** A future RFC may add `YYYY-MM/DD.idx`
  sidecar files (seq → byte offset) to allow byte-seek by sequence
  number. Useful only if cursor-bearing requests become hot; out of
  scope here.
- **Multi-process activity coordination.** Single-process is enough at
  current scale.
- **Schema migration of JSONL rows.** This RFC preserves the existing
  row schema.

## 11. References

- RFC-0138 (Dashboard Snapshot lock-free architecture, Phase 3 closeout
  2026-05-20).
- PR #19150 (cache+offload wrap on activity endpoints, merged 2026-05-27).
- Live measurement transcript:
  `~/.masc/activity-events/2026-05/{01,03,18,25,27}.jsonl` sizes
  + curl timing 2026-05-27 ~21:30 KST.
- `lib/activity_graph/activity_graph.ml:203 read_all_events`,
  `lib/dashboard/dashboard_snapshot.ml:9 type t`.
- sw-dev §AI 안티패턴 §1 (Scattered Hardcoded Defaults) — not violated
  here (refresh interval is single SSOT).
- sw-dev §워크어라운드 거부 §1 (cap/cooldown spiral) — PR #19150
  retroactively classified as "cache wrap survives TTL underflow"; this
  RFC promotes it to a real publication primitive.
