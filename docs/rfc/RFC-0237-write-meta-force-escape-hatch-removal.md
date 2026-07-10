---
rfc: "0237"
title: "Eliminate the write_meta ~force escape hatch (route snapshot writes through CAS+merge)"
status: Draft
created: 2026-06-14
updated: 2026-06-14
author: vincent
supersedes: []
related: ["RFC-0225"]
---

# RFC-0237 — Eliminate the `write_meta ~force` escape hatch

## §1 Problem (evidence-grounded)

`Keeper_meta_store.write_meta` carries an optional `?force` parameter
(`lib/keeper/keeper_meta_store.ml:290`). With `~force:true` the write skips the
`meta_version` CAS entirely — it bumps the version and persists the caller's
snapshot verbatim:

```ocaml
let write_meta ?(force = false) config (m : ...) : (unit, string) result =
  let path = keeper_meta_path config m.name in
  if force
  then (
    let persisted = { m with meta_version = m.meta_version + 1 } in
    persist_meta config path persisted)   (* (A) last-writer-wins, no CAS *)
  else (
    (* Version CAS: reject writes whose version doesn't match disk. *)
    ...)
```

Branch (A) is a last-writer-wins write. If a concurrent keeper turn advanced the
cumulative usage counters (`total_turns`, `total_*_tokens`, `total_cost_usd`)
between the caller's snapshot read and this write, those increments are silently
rewound. This is the exact shape of the documented `total_turns` 385→370
regression (2026-06-10) that RFC-0225 §3.2 and
`Keeper_meta_merge.monotonic_usage_counters` (`lib/keeper/keeper_meta_merge.ml:13`)
were written to prevent.

PR #21116 removed the four **dashboard-HTTP** force-writes by routing them
through `write_meta_with_merge` (`lib/keeper/keeper_meta_store.ml:330`). It
deliberately left three **keeper-internal** force-writes untouched and escalated
them here, because they edit runtime identity/timestamp fields or sit on
hot paths and warranted per-site analysis rather than a blanket swap.

As long as `?force` exists on the signature, any future call site — written by a
human or an AI agent learning from the codebase — can reintroduce a counter
rewind by passing `~force:true`. The counter is a cumulative invariant; the
escape hatch makes that invariant violable from anywhere. This is an
"Unknown → Permissive Default" surface (CLAUDE.md §AI 코드 생성 안티패턴 #2).

## §2 The three remaining `~force:true` sites

All three were located by `rg -U 'write_meta[^)]*?~force:true' lib/` (exactly three
matches; no `~force:false` explicit callers exist, so the default `force=false`
CAS path is the only other shape).

| # | site | edits (non-counter) | concurrency | counter-rewind hazard |
|---|------|--------------------|-------------|----------------------|
| 1 | `lib/keeper/keeper_tool_surface_ops.ml:136` | `agent_name`, `trace_id`, `trace_history`, `generation` (identity reseed on agent mismatch) | reseed vs live turn | yes |
| 2 | `lib/keeper/keeper_keepalive.ml:311` | `usage.last_turn_ts=bootstrap_ts`, optional identity repair (`bootstrap_live_keeper_meta`) | server bootstrap, effectively single-writer | low (no live turn at bootstrap) |
| 3 | `lib/keeper/keeper_heartbeat_loop_presence.ml:82` | `agent_name`, `trace_id`, `trace_history`, `generation` (identity drift repair) | **heartbeat loop runs concurrently with turns** | yes (highest) |

Key observation: **none of the three legitimately needs to rewind cumulative
counters.** Each edits identity/timestamp fields and only uses
`~force` to avoid a CAS conflict. The counter rewind is an unwanted side effect,
not the intent.

## §3 Proposal

### 3.1 Route all three through CAS + monotonic merge

`monotonic_usage_counters` (`lib/keeper/keeper_meta_merge.ml:13`) takes the
caller as the base — so the caller's identity/timestamp edits survive — and
takes `max(caller, latest)` for the five cumulative counters, so they never
regress. It is the correct merge for all three sites.

Before / after (site 3, the hottest):

```ocaml
(* before *)
(match write_meta ~force:true ctx.config repaired with ...)

(* after *)
(match
   write_meta_with_merge
     ~merge:Keeper_meta_merge.monotonic_usage_counters
     ctx.config repaired
 with ...)
```

In the common case there is no concurrent writer, the first CAS attempt
succeeds, and `merge` is never invoked — so this is behaviour-preserving except
that a lost race now absorbs (rather than rewinds) the counter increment.

### 3.2 Remove the `?force` parameter (type-level elimination)

After 3.1 there are zero `~force:true` callers. Delete `?force` from
`write_meta` so CAS is the only write path. `write_meta_with_merge` already
calls `write_meta config caller` with no force (`lib/keeper/keeper_meta_store.ml:339`),
so it is unaffected. The initial-write case is still handled by the CAS path's
`Ok None` branch (`lib/keeper/keeper_meta_store.ml:311`).

This removes the escape hatch at the type level: a future `~force:true` becomes
a compile error, not a silent counter rewind. This is the structural root fix —
the alternative (leave `?force`, fix only the three sites) is an N-of-M patch that
lets the next caller reintroduce the hazard.

### 3.3 Bootstrap behavioural delta (site 2)

Converting site 2 introduces one new failure mode: `write_meta_with_merge` can
return `Error` after `max_retries` CAS conflicts, whereas `~force:true` never
failed on conflict. At server bootstrap there is no concurrent turn writer, so a
3-deep CAS conflict is not reachable in practice; the existing
`WriteMetaFailures{phase=bootstrap}` error path already handles a failed write.
This delta is accepted and called out for review rather than hidden.

## §4 Boundary

In scope: the three `~force:true` call sites, the `write_meta` signature, and
their characterization tests. Out of scope: the `write_meta_with_merge` retry
count / backoff (unchanged), and the dashboard-HTTP sites (already done in
#21116).

## §5 Validation

- The escape hatch is closed by construction: removing `?force` makes
  `write_meta` CAS-only, so a stale write that would rewind a concurrent turn's
  counters is rejected. The former force-hazard characterization in
  `test_keeper_meta_cas_retry` (`test_force_write_rewinds_usage_counters`, which
  demonstrated the rewind a force path produced) is replaced by
  `test_stale_write_conflicts_without_force`: it asserts a stale-snapshot plain
  write now returns a version conflict and the advanced disk counter survives.
  The three sites share one merge function, so this single invariant plus
  compiler-verified routing covers them — per-site copies would add no signal.
- `test_monotonic_usage_counters_on_cas_retry` (existing) already proves the
  merge keeps the larger disk value on retry; the converted sites use that same
  `monotonic_usage_counters` merge.
- `dune build --root . @check` and `dune build --root .` exit 0; the removal of
  `?force` is verified by the compiler — every caller (including three test
  seed-writes) failed to build until converted, proving full coverage.

## §6 Alternatives considered

- **Leave `?force`, fix only the three sites.** Rejected: N-of-M patch; the next
  caller (human or AI) reintroduces the hazard. The whole point is to make the
  illegal write unrepresentable.
- **Keep `~force` but rename to `~i_accept_counter_rewind`.** Rejected: a scary
  name does not stop an agent from passing it; only removal does.
- **A typed `Force_reason.t` variant gate.** Rejected as over-engineering: there
  is no legitimate counter-rewinding use case among the call sites, so the parameter
  should not exist at all rather than be gated.

## §7 RFC-0225 alignment

RFC-0225 §3.2 established that cumulative usage counters never regress on a CAS
retry. This RFC closes the remaining hole in that invariant: the `~force` path
that bypasses CAS (and therefore the merge) entirely. No security/credential
surface is touched.

## §8 Ledger note (non-blocking)

`docs/rfc/` currently has duplicate numbers for `RFC-0235` (stale-base-revert vs
voice-output-browser-transport) and `RFC-0236` (keeper-git-credential-helper vs
voice-input-browser-transport), plus ~14 older collisions. This RFC takes `0237`
(the ledger `.next-number`, unused on disk). The duplicate-number hygiene is a
separate cleanup, flagged here so it is recorded.
