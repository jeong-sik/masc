---
rfc: "0372"
title: "Request-scoped resource budget — bound what one read may consume"
status: Draft
created: 2026-08-12
updated: 2026-08-12
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0204", "0138", "0029"]
---

# RFC-0372 — Request-scoped resource budget

> Evidence record: measured 2026-08-12 against `origin/main 7e57a3af79`, M3 Max
> 16-core, via `scripts/harness/perf/request_cost_gate.sh` (Mode C, added in
> PR #28386). Raw artifacts under `logs/perf-request-cost/`. Reproduced
> independently against the live runtime on `:8935` before the harness existed.

## §0 The axis RFC-0204 does not cover

RFC-0204 isolates dashboard *serving* from fleet *compute*: a dedicated pool,
then a dedicated serving domain. Its harness (Mode A) drives 48 in-process
requests plus host hogs; Mode B drives real keeper turns. Both stress
**contention** and answer *where does work run, and who is it queued behind*.

Neither holds concurrency at one. This RFC covers what they cannot see.

**Measured, concurrency = 1**, one `GET /api/v1/dashboard/telemetry?n=0`
against a seeded 125MB store (8 keepers × 20,000 entries = 12 stores):

| axis | measured | gate threshold |
|---|---|---|
| trivial-endpoint p95 while in flight | 1128.0 ms (max 4424.0) | 250 |
| RSS growth from that one request | 1005.5 MB | 512 |
| recovery after the client aborts | 20.4 s | 5 |
| heap growth *after* the client is gone | 315.6 MB | 64 |

On the live runtime (larger store) the same request drove RSS 3.7 GB → 26.4 GB
and left `/health` unanswered for over 60 s.

A read whose cost scales with the store is not fixed by moving it. Under
RFC-0204 Phase 3 the request lands on the dedicated serving domain and kills
*that* lane instead; the dashboard is still down. And the heap it allocates is
**process-global**, so every keeper shares the GC pressure no matter which
domain allocated it. Isolation cannot make a large request small.

Isolation and boundedness are orthogonal. RFC-0204 is necessary and is not
superseded by this RFC; this one is its sibling.

## §1 Root cause — the cap is per-store, not per-request

`telemetry_unified.ml`:

```ocaml
let unbounded_window_scan_cap = 50_000        (* :392 — per STORE *)

let bounded_entries_for_window store ~n ... =
  let effective_n = if n <= 0 then unbounded_window_scan_cap else n in   (* :400 *)

let read_keeper_metrics ~masc_root ... =
  List.concat_map (fun (_name, dir) ->                                  (* :432 *)
    read_fixed_source dir Keeper_metric ~n ...) dirs
```

`read_unified_result` (:621-634) sets `limited = n > 0`; an explicit `n = 0`
makes `per_source = 0`, which every store then reads as `effective_n = 50_000`.

Three consequences:

1. **The bound grows with the data.** 9 sources, three of which fan out per
   keeper. At 8 keepers that is ~30 stores × 50,000 ≈ 1.5M entries for one
   request. Adding a keeper raises the ceiling. A bound that tracks the data it
   is meant to bound is not a bound.
2. **`n = 0` is a reachable unbounded contract.** The default was bounded in
   #20659 (`routes_dashboard_setup.ml:47-56`), but the explicit form was
   deliberately preserved as "all-in-window". It is unauthenticated and
   reachable from any browser tab.
3. **The result is sorted as a list, comparing on re-extracted fields**
   (`:134`, `:685`): `List.sort (fun a b -> Float.compare (extract_ts b)
   (extract_ts a))`. `extract_ts` walks a JSON assoc list per comparison, so a
   1.5M-entry sort performs on the order of 10^8 field lookups, with `List`
   allocation on every `concat_map` / `filter` / `drop` along the way.

None of this yields. Eio fibers are cooperative and a pure computation has no
suspension point, so whichever domain runs it is held for the duration.

## §2 Root cause — no request has a deadline or an owner

`Eio.Time.with_timeout` appears nowhere on the inbound HTTP path (whole-repo
search; the matches in `runtime_*` are outbound LLM idle-caps, and RFC-0129
despite its filename is about the outbound attempt idle-cap).

The dashboard client sends `AbortSignal`
(`dashboard/src/api/dashboard-telemetry.ts:232`). The server does not observe
it. Measured: **+315.6 MB of heap growth after the client was gone**, and 20.4 s
before a trivial probe recovered.

The user-facing consequence is worse than the number suggests. A slow dashboard
invites a reload, and each reload adds a computation while the abandoned one
keeps running. Backing off does not release anything.

## §3 Non-goals

- **Not a replacement for RFC-0204.** Contention is real and separately fixed.
- **No new cache layer.** The per-handler `Dashboard_cache.get_or_compute +
  submit_io_or_inline` retrofit is already flagged as the N-of-M signature
  (RFC-0204 §4). Adding a tier repeats it; cold start and post-invalidation
  remain unbounded either way.
- **Not `submit_cpu` re-weighting.** RFC-0204's Phase 0 assessment stands: Eio
  weight is admission-packing, not priority, and 1.0 makes a heavy job
  monopolise a worker.
- **No retention change here.** Rotation/rollup for `exact-lane-runs` and
  friends is real but separable; a bounded reader must hold regardless of store
  size, which is the whole point.

## §4 Proposal

Ordered by leverage. Each phase is independently shippable and gated by Mode C.

### Phase 1 — delete the unbounded contract

Make "all entries" unrepresentable rather than validated away. `n` is parsed
into a closed type at the boundary:

```ocaml
type read_limit = Limited of int   (* invariant: 1 <= n <= max_entries *)
```

`n = 0` maps to the default, not to "everything". Parse, don't validate: no
downstream reader can then receive a request meaning "unbounded", and the
compiler enforces it at every construction site.

### Phase 2 — a budget that belongs to the request

One budget per request, decremented as stores are consumed, rather than a fresh
allowance per store:

```ocaml
type budget = { mutable entries_left : int; deadline : float }
```

Readers stop when the budget is exhausted and the response reports
`truncated: true` with what was covered. The existing `truncated` field already
carries this contract to the client.

This is the phase that decouples cost from store count: adding a keeper changes
*which* entries are returned, never *how many* are materialised.

### Phase 3 — deadline and cancellation

Wrap inbound handlers in `Eio.Time.with_timeout` and propagate client
disconnect into the compute fiber, so an abandoned request stops allocating.
The typed timeout also converts today's silent 30 s client-side timeout into a
server-side error that can be observed.

Gate: `post_abort_heap_growth_mb` must fall to the noise floor.

### Phase 4 — admission control by cost, not by count

`Rate_limit` (token bucket, burst 150) counts requests. The measured
denial-of-service is one request, which never touches the bucket. Admission
should debit the *estimated* scan, and a bulkhead semaphore should bound
concurrent heavy reads, shedding with `503 + Retry-After` past the queue depth.
Refusing is better than stalling; today the server does neither.

### Later, separable

Decorate-sort-undecorate plus arrays for the sort path; batch reads for the
per-keeper N+1 (`composite_enrich.ml:60-77`, `/tool-stats`); cursor pagination
to retire the `offset` clamp at 5000; ETag on JSON keyed off a store revision
so an unchanged projection skips **compute**, not merely transfer.

## §5 Verification

`scripts/harness/perf/request_cost_gate.sh` (Mode C) is the merge gate. It is
falsifiable in both directions and was verified in all three states before this
RFC was written: RED at scale, GREEN on a small store, ERROR when the baseline
control trips.

Acceptance per phase:

| phase | axis that must move |
|---|---|
| 1 | `rss_peak_delta_mb` for `?n=0` drops to the bounded-default level |
| 2 | doubling `--keepers` leaves `rss_peak_delta_mb` flat |
| 3 | `post_abort_heap_growth_mb` ≤ 64; `cancel_recovery_s` ≤ 5 |
| 4 | a heavy-read burst returns 503 instead of stalling; probe p95 holds |

The Phase 2 criterion is the load-bearing one: it tests the invariant (cost is
independent of store count), not a threshold that a faster machine could pass
by accident.

Runs must satisfy the baseline control (idle p95 ≤ 50 ms) or be discarded. A
contended host makes every number look like a defect — RFC-0204's first
diagnosis was reversed for this reason, and a 4-vs-8-keeper comparison during
this RFC's own measurement was invalidated the same way.

## §6 Scope (files)

`lib/telemetry_unified/telemetry_unified.ml` (limit type, budget threading),
`lib/telemetry_unified_source/` (reader signatures),
`lib/server/server_routes_http_routes_dashboard_setup.ml` (boundary parse),
`lib/http_server_eio.ml` (deadline, disconnect propagation),
`lib/rate_limit.ml` (cost-based admission), plus the other unbounded read
surfaces once the budget type exists (`/dashboard/board`, `/dashboard/proof`,
`/keepers/:name/tool-stats` — all three carry the same retrofit comment).

## §7 Open questions

- Where does the budget live? Threading it explicitly is honest but touches
  every reader signature; a fiber-local is less invasive and less visible.
  Prefer explicit unless the signature churn proves unacceptable.
- What is the right default entry ceiling? It should follow from a target
  response size and heap cost per entry, measured, not chosen.
- Does any caller legitimately need a full-store read? If so it belongs on an
  export path with its own admission, not on the dashboard read path.
- Phase 3 interacts with RFC-0204 §8.4: cancellation crossing a domain boundary
  needs the session-field synchronisation prerequisite. Sequence with that RFC
  rather than duplicating it.
- Should Phase 4 shed by endpoint class or by estimated cost? Cost is more
  faithful but needs an estimator the reader can produce before it starts.
