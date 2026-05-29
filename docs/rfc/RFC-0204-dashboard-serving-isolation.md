---
title: Dashboard Read Serving Isolation from Fleet Compute
rfc: 0204
status: Draft
created: 2026-05-29
author: jeong-sik (with Claude Opus 4.8)
related:
  - RFC-0029 dashboard-fiber-batched-aggregation (Active) — per-keeper fan-out cost
  - RFC-0138 dashboard-snapshot-lock-free-architecture (implemented) — the lock-free cache
  - RFC-0101 fd-accountant-generic-pool / RFC-0107 phase-d-pool-design — pool design
  - RFC-0201 activity-events-wait-free-snapshot
  - RFC-0059 (Withdrawn) — domain/actor bundle; lesson: keeper bodies on pool-worker domains proved unsafe (affinity)
---

# RFC-0204 — Dashboard Read Serving Isolation from Fleet Compute

> Evidence record: measured 2026-05-29 against `main_eio.exe :8935` (base-path `/Users/dancer/me`). Raw curl runs (sequential / parallel-burst / repeat-floor / head-of-line) under `~/me/.tmp/masc-perf-2026-05-29/`.

## 1. Problem

Dashboard HTTP latency is dominated by *waiting*, not handler work.

- Warm-cache handler floors are sub-30ms (config 2ms, governance 3ms, board 13ms, operator 7ms).
- Yet user-observed latency reaches 8–40s; e.g. `tool-quality` true cost 0.09s but measured up to 24s.
- Latency tracks host CPU load monotonically (16-core machine): 1-min load 14.5 → parallel-burst wall-clock 2.76s; load 30–78 → multiple 40s timeouts (including the trivially-cached `provider-logs`); load 178 → 11s. `main_eio` sat at 12–27% CPU throughout — starved, not self-saturating.

Two structural facts (code analysis, file:line) make the server *fragile* under load:

1. **Single main Eio domain** carries HTTP accept + per-connection fibers (synchronous inline handlers) + 5 refresh loops + 24 keeper keepalive fibers, all forked on one `~sw` (`server_bootstrap_http.ml:111-137`, `server_runtime_bootstrap.ml:324,881-885,916`). No `Domain_manager`/`Domain.spawn` in the accept path.
2. **One shared `Executor_pool`** (15 domains on this host) serves *both* dashboard compute and keeper compute with no QoS (`server_runtime_bootstrap.ml:683-693`). Dashboard offload uses `Domain_pool_ref.submit_io_or_inline` (weight 0.05, 43 sites); `submit_cpu` (1.0) is defined but never called. When the pool is saturated by keeper jobs, the `_or_inline` fallback runs dashboard compute **inline on the main domain**, head-of-line-blocking HTTP serving.

The dominant real-world *trigger* is host-load amplification (a separate, code-independent host-hygiene fix stops watchman's ~870 full-tree recrawls of `~/me`). This RFC addresses the *server-side amplifier*: dashboard reads should not contend with, or queue behind, fleet compute, so that the server degrades gracefully instead of going fully unresponsive under host pressure.

## 2. Non-goals / constraint from RFC-0059

RFC-0059 attempted to route keeper keepalive bodies through Domain_pool workers; live recovery proved it **unsafe** (Eio switch/domain affinity — see `keeper_supervisor_launch.ml:71-77`). Therefore this RFC **does not move keeper work across domains**. It isolates *dashboard read serving*, which is stateless and already offloaded, leaving keeper affinity untouched.

## 3. Proposal

### Option A (preferred) — Dedicated dashboard pool
A second small `Executor_pool` (`dashboard_pool`, 2–4 domains) used exclusively by dashboard refresh loops and on-demand read compute. Keeper compute keeps the existing pool. Removes cross-contention; dashboard reads never queue behind keeper jobs.
- Trade-off: domains are finite (15 + N must fit cores). Size `dashboard_pool` small; reads are short.

### Option B — Weighted admission lane in the single pool
Keep one pool; add a priority/reservation so dashboard `submit_io` jobs reserve a slice ahead of keeper jobs. Lower memory, but Eio.Executor_pool has no native priority — needs a wrapper queue. More code, more risk.

### Option C (separate RFC, riskier) — Multi-domain HTTP accept
Distribute the accept loop across domains (`Eio.Domain_manager` + `SO_REUSEPORT`). Highest concurrency ceiling, but touches the dispatch core and must clear the RFC-0059 affinity concerns. Deferred to a follow-up RFC.

### Supporting changes (cheap, measure first — may suffice without a second pool)
- **Fix the offload weight**: heavy CPU handlers (board 936KB JSON build) should use `submit_cpu` (1.0), not `submit_io` (0.05). Wire the dead `submit_cpu*` or delete it (resolves the undocumented dual-weight ambiguity).
- **Proactively pre-warm the 8 slow surfaces** (board/governance/goals/tool-quality/shell/config/operator/execution) like execution/operator already are, so on-demand cold compute never blocks a user request (`Dashboard_cache` SWR serves stale instantly once warm).

## 4. Workaround-bar note (CLAUDE.md)

The per-handler `Dashboard_cache.get_or_compute + submit_io_or_inline` retrofit chain (file comments cite PR #18991/18993/18994/19007/19015/19023 "same fix pattern") is the **N-of-M patch** signature — the same offload applied site-by-site without a shared abstraction. This RFC absorbs that pattern into a single isolation boundary instead of continuing per-site retrofits.

## 5. Verification (harness-first)

Quantitative, reproducible, under *controlled* host load (stop builds, apply the watchman host-hygiene fix first):
- Baseline: `~/me/.tmp/masc-perf-2026-05-29/parallel.sh` at 1-min load < 16, 5 runs → record wall-clock + per-endpoint.
- Target: parallel-burst wall-clock ≈ max(individual floor) (≈ board/operator ~1–2s); fast endpoints stay sub-300ms while a heavy endpoint computes.
- Keeper-burst isolation test: drive keeper compute (reactive concurrency) while probing `provider-logs`/`config`; their latency must stay flat (no queueing behind keeper jobs).
- Regression guard: a test asserting dashboard refresh submits to `dashboard_pool`, not the keeper pool (Option A).

## 6. Scope (files)

`lib/core/domain_pool.ml`, `lib/core/executor_pool_ref.ml` (second pool ref), `lib/server/server_runtime_bootstrap.ml` (pool creation + wiring), `lib/server/server_dashboard_http_runtime_support.ml` (`run_dashboard_compute` target pool), the 43 `submit_io_or_inline` sites (audit which should target `dashboard_pool`).

## 7. Open questions

- Domain budget: 15 (keeper) + N (dashboard) on a 16-core host — does the keeper pool shrink to `recommended-3`?
- Does any dashboard compute legitimately need keeper-pool locality (shared in-process state)? Audit before splitting.
- Is Option A worth it vs. just the cheap supporting changes (inline-fallback fix + pre-warm)? Measure the cheaper changes first; they may remove most contention without a second pool.
