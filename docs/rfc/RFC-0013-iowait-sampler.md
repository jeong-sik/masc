# RFC 0013 — IO-wait Sampler (PR-0.2.E, deferred)

- Status: Draft (deferred — see "Prerequisites")
- Author: Vincent (vincent.dev@kidsnote.com)
- Date: 2026-04-29
- Parent plan:
  `knowledge/research/2026-04-masc-ide-strategy/IMPLEMENTATION-PLAN.md` PR-0.2
- Related code:
  `lib/core/masc_runtime_events.ml`,
  `lib/core/masc_runtime_events.mli`,
  `scripts/perf-baseline.sh`
- Related OCaml docs:
  `https://ocaml.org/manual/5.4/api/Runtime_events.html`,
  `https://ocaml.org/p/eio/latest`

## Problem

PR-0.2 (perf baseline measurement infrastructure) collects GC pause,
RSS, fiber count, MCP latency, and cache hit ratio. It does not yet
expose an *IO-wait ratio* — the fraction of wall-clock time the
process spends parked on syscalls (network read/write, file IO,
pipe drain) versus running OCaml code.

Without this signal, a regression where a keeper turn becomes IO-bound
(slow local LLM, congested provider, blocked unix domain socket) is
indistinguishable from a CPU-bound regression by the existing
gauges. The PR-0.2 baseline therefore cannot answer "is the process
starved on syscalls?" — only "is wall time worse?".

This RFC scopes a sampler module that would expose
`masc_io_wait_ratio` as a Prometheus gauge derived from OCaml 5
`Runtime_events` `Io` entries.

## Why this is a separate, deferred sub-PR

The parent IMPLEMENTATION-PLAN.md PR-0.2 entry already lists
`olly opt-in (OLLY_TRACE=1)` as scope. That uses the same
`Runtime_events` ring buffer this RFC would consume in-process.
Two questions must be answered before code lands:

1. **Eio scheduler interaction**: `Runtime_events.read_poll` reads
   the per-domain ring buffer. The masc-mcp server runs under a
   single `Eio_main.run` with cooperatively scheduled fibers; a
   sampler fiber that polls every 30s must not block long enough
   to starve other fibers, and the read path must be safe to call
   from a non-main domain if domains are introduced later.
   Verification target: a 60-minute soak where the sampler fiber
   coexists with `worker_oas` + `keeper_agent_run` (both already
   call `emit_turn_start`/`emit_turn_end`).
2. **Ring buffer overflow**: `Runtime_events.start ()` uses a
   fixed-size ring per domain (default 64 KiB). Under high turn
   throughput plus stock GC events plus user `Turn` spans, the
   ring can wrap. A sampler that reads only every 30s may miss
   `Io` spans entirely during bursts. Mitigation options
   (increase ring size, reduce poll interval, drop and accept
   rate as a metric) need empirical sizing.

Until both questions are answered with measured evidence, the
sampler does not ship.

## Trade-offs of three implementation paths

| Path | Adds | Risk | When |
|------|------|------|------|
| A. Full `Runtime_events`-based sampler | `lib/iowait_sampler.ml`, 30s polling fiber, `masc_io_wait_ratio` gauge | Eio scheduler starvation if `read_poll` blocks; ring overflow under load; Eio + Runtime_events integration unverified | After soak test confirms (1) and (2) above |
| B. `Unix.gettimeofday` uptime gauge + best-effort event-loop lag | `masc_uptime_seconds` gauge, optionally `masc_event_loop_lag_seconds` | Low. Adds wall-clock signal only. Lag measurement needs scheduler-level hook that Eio does not expose today | Useful as a separate trivial PR; does not substitute for IO-wait |
| C. Defer (this RFC only) | RFC document, no code | None. Honest deferred state | Now — until prerequisites land |

This RFC takes path C. Paths A and B are recorded so the next
session does not re-derive the trade-off.

## Prerequisites (must be measured before path A is attempted)

1. **Eio + Runtime_events soak**: 60 min server run with
   `OLLY_TRACE=1` and a parallel `Runtime_events.Callbacks`
   consumer registered in-process. Confirm:
   - No fiber stalls > 100 ms attributable to the consumer.
   - Ring buffer wrap count over the run (use
     `Runtime_events.lost_events` if available).
2. **Sizing**: pick `read_poll` interval and ring size such that
   `Io` span coverage > 95 % under simulated keeper load
   (`benchmarks/quick-bench.sh` lanes).
3. **Cancellation**: confirm sampler fiber respects switch
   cancellation in the standard masc-mcp shutdown path.

## Non-goals

- No new Prometheus dependency.
- No change to existing `Runtime_events` registrations
  (`lib/core/masc_runtime_events.ml`).
- No change to `scripts/perf-baseline.sh` until path A or B is
  approved as a follow-up.

## Open questions

- Does `Runtime_events.Type.Io` distinguish read vs write
  syscalls? If not, the gauge is a single ratio rather than
  separate read/write ratios.
- Should the gauge be per-domain when domains are introduced, or
  process-wide? Process-wide for now; revisit when domains land.

## Status

Deferred. This RFC is recorded so that the PR-0.2 baseline work
ships without an unverified sampler, and so that a future session
can pick up the prerequisites without re-discovering the
trade-offs.
