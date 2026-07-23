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
>
> Update 2026-05-29 (§8–§9, WS/refresh scheduling): re-measured at 1-min load 36 (16-core), with the host carrying two kidsnote node dev servers (126% + 98% CPU), `fseventsd` (111%), `Mail.app` (85%), `watchman` (35%), and several `claude` sessions; `main_eio` got 14.7% CPU. `GET /dashboard/shell?light=true` cold-miss 2.44s → warm 12–19ms (60s cache); `GET /dashboard/shell` (wait-free snapshot) cold 0.46s → warm 17ms. The browser-observed 30–40s was during the load-100–220 peak, not this state. Confirms host CPU contention is the dominant trigger; the server change makes degradation graceful but cannot manufacture CPU. WS-dispatch + refresh-loop facts in §8 verified against the same checkout. Root-cause design produced by a 5-agent analysis workflow (`~/me/.tmp/masc-perf-2026-05-29/rootfix-design.workflow.js`).

> **Implementation status (verified 2026-06-23, code-grounded — front-matter is still `Draft`):**
>
> - **Phase 1 — LANDED** (more robustly than this RFC's literal §8.4 text). The two mutable session fields (`dashboard_authenticated`/`dashboard_agent`) were replaced by a single `dashboard_auth : dashboard_auth_state Atomic.t` (`server_mcp_transport_ws.ml:39-41,82,483`; one `Atomic.set` writer, all readers `Atomic.get` including the SSE-forward gates). The `with_sessions_rw` prescription was deliberately not taken — `Eio.Mutex` is single-domain and gives no cross-domain protection, so `Atomic` is the correct (stronger) lever for the Phase 3 boundary.
> - **Phase 2 — PARTIAL.** Publisher-offload landed (`dashboard_snapshot.ml:274` offloads compute before the sleep; the §8.2.3 inline-compute defect is fixed). The dedicated dashboard pool (Option A) did **not** land — one shared `Domain_pool.create` (`server_runtime_bootstrap.ml:865`) serves dashboard + keeper compute, so refresh still queues behind keeper jobs. Per §8.4 Option A is necessary-but-insufficient anyway; Phase 3 must not assume a `dashboard_pool` exists.
> - **Phase 0 — NOT landed.** The board handler (`server_dashboard_http.ml:69`) still uses `submit_io_or_inline` (weight 0.05); board/Gate/tool-quality/config are not pre-warmed. Caveat: the §3 "wire `submit_cpu` (weight 1.0) for board" change was separately assessed as a harmful workaround (Eio weight is admission-packing, not priority; 1.0 makes the heavy job monopolise a worker, pushing the other read sites behind it) — measure it under a harness before landing, do not land on faith.
> - **§9 empirical gate update:** a controlled-load harness (`scripts/harness/perf/scheduler_starvation_gate.sh`) reproduces serving-concurrency RED at negligible host load (48 in-process requests + 1 host hog → `/health` p95 ~80×), answering §9's open "is it just host pileup?" with **no** — the starvation is serving-concurrency-dominant. Two per-request micro-offloads (turn-records parse; json serialize+compress) were harness-falsified, leaving the dedicated serving domain (Phase 3) as the remaining lever.
> - **Phase 3 feasibility:** hybrid-routing only (not a clean split). The wait-free read path (`/dashboard/shell` → `Dashboard_snapshot.current()` `Atomic.get`) is safe to move, but ~15 keeper-owned `Eio.Mutex`es plus `sessions_mutex` are reachable from serving handlers (SSE keeper_stream, WS subscribe, Gate journal reads, keeper-mutation REST) and must stay on main. Open blockers before Phase 3: the keeper-burst isolation regression test (§5/§7 merge gate) does not yet exist (authored next), the per-handler audit is not yet exhaustive, and the `sessions_mutex` cross-domain design (the WS upgrade fiber and main-domain MCP dispatch both acquire it) is unresolved.

## 1. Problem

Dashboard HTTP latency is dominated by *waiting*, not handler work.

- Warm-cache handler floors are sub-30ms (config 2ms, Gate 3ms, board 13ms, operator 7ms).
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
- **Proactively pre-warm the 8 slow surfaces** (board/Gate/goals/tool-quality/shell/config/operator/execution) like execution/operator already are, so on-demand cold compute never blocks a user request (`Dashboard_cache` SWR serves stale instantly once warm).

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
- (Phase 3) Does any REST handler reachable from the accept loop touch mutable keeper-owned state guarded by `Eio.Mutex`? If yes those paths must stay on the main domain (hybrid routing) — needs a per-handler call-graph audit before moving accept to the serving domain.
- (Phase 3) `Eio.Domain_manager.run` vs a long-lived spawned domain: the serving domain must persist for process lifetime and own its switch without the parent switch tearing it down — confirm the Eio idiom before implementing.
- The keeper-burst isolation regression test (§5) is the proposed Phase 3 merge gate but does not yet exist — it must be authored first.

## 8. Extension — WS dispatch & refresh-loop scheduling (the scheduling-capacity root)

§1–§3 isolate dashboard *compute*. They do not address the two paths the browser actually fails on first: the WebSocket `dashboard/hello` RPC (30s client timeout) and the snapshot publisher that feeds wait-free reads. Both starve on the single main domain regardless of compute isolation, because the work that starves is *scheduling*, not CPU on a worker.

### 8.1 The decisive Eio fact

`Eio.Executor_pool.submit`/`submit_exn` **block the calling fiber** until the worker finishes (eio `executor_pool.mli`). So offloading dashboard compute to a pool (Option A) does not rescue the WS-hello or refresh paths: the fiber that submitted still has to be *re-scheduled on the main domain* to resume after the worker returns. Under main-domain CPU starvation that continuation never runs. The root for these two paths is therefore **scheduling capacity for the dispatch/await fibers**, not compute capacity for the worker. Option A is necessary for compute QoS but insufficient for WS-hello/refresh starvation.

### 8.2 New code facts (verified against `5cfd0b914`)

1. **WS message dispatch double-forks onto the main switch.** `server_runtime_bootstrap.ml:772-776`: `~on_message:(fun ws_session_id body_str -> Eio.Fiber.fork ~sw (fun () -> … Mcp_eio.handle_request ~clock ~sw …))`. The httpun-ws frame callback already runs on a per-connection fiber forked on `~sw`; `on_message` forks a *second* fiber onto the same `~sw` to do the RPC. Both land on the one main-domain OS thread, behind the 24 keeper keepalive fibers (`keeper_supervisor_launch.ml:104`, `~sw:ctx.sw` = bootstrap `~sw`) and the 5 refresh loops.
2. **`dashboard/hello` work is trivial.** `server_mcp_transport_ws.ml:335-351`: `find_session` (one `Eio.Mutex` acquire), `verify_dashboard_token` (mtime/TTL-cached `Auth.load_auth_config`, `:311-333`), two field writes, JSON build. No I/O, no clock, no provider stream, no fork. A 30s timeout means the forked fiber was never scheduled to completion — not that the handler is slow.
3. **The unified snapshot publisher computes inline on the main domain.** `dashboard_snapshot.ml:122` `refresh_loop` calls `Server_dashboard_http_core.dashboard_shell_payload_json config` directly at `:140` (and tools/telemetry/activity projections) with **no `submit_io`**, then `Eio.Time.sleep clock interval_sec` at `:217`. Unlike the per-surface loops (which offload via `run_dashboard_compute ~mode:Offloaded_readonly`), this publisher’s compute runs on the starved main thread, so `snap.shell` ages under load and the wait-free read serves stale data.
4. **`shell?light=true` bypasses the wait-free snapshot.** `server_dashboard_snapshot_select.ml:12-15`: when `light`, it always calls `dashboard_shell_http_json` (`Dashboard_cache.get_or_compute_with_timeout`, server ceiling) and never reads `Dashboard_snapshot.current()`; the non-light branch reads `snap.shell` wait-free (`Atomic.get`).

### 8.3 Verdict on "make `light` read the published snapshot" (option A from the perf thread)

**Mitigation, not a root fix — and harmful if shipped alone.** `light=true` bypasses the snapshot today *precisely because* the publisher (8.2.3) is unreliable under load. Flipping `light` to read `Dashboard_snapshot.current()` while the publisher still computes inline trades a visible 35s timeout for **silent staleness** (old data, no signal). It becomes a legitimate part of the root fix only **after** the publisher is made reliable (offloaded + on a non-contended lane, Phase 2): then one fresh snapshot serves both `light` and non-light wait-free and the recompute path is deleted. Do not ship the `light`→snapshot change before Phase 2.

### 8.4 Session-field race — prerequisite before any off-domain move

`dashboard_hello` (`server_mcp_transport_ws.ml:335-351`) writes `session.dashboard_authenticated <- true; session.dashboard_agent <- agent` at `:344-345` **outside** `sessions_mutex` — `find_session` (`:288-289`) releases the mutex before the writes. Readers are also unlocked: `:275/:277` (session result), `:378/:409/:430/:445` (auth gates), `:661/:708` (SSE forward gate). Today single-domain cooperative scheduling serializes these (the writes have no suspension point), so there is **no live race and no behavior change** — but moving WS dispatch to another domain (Phase 3) turns this into a real cross-domain data race. The writes must be put under `with_sessions_rw`, and the hot-path readers (notably the SSE gate at `:661/:708`) audited, *before* the off-domain move. `Eio.Mutex` is single-domain (`workspace_utils_backend_setup.ml:135-138`); any session field shared across the domain boundary needs `Eio.Mutex`-under-both-sides or `Atomic`.

### 8.5 RFC-0059 safety of the serving-domain direction

The root fix is the **inverse** of withdrawn RFC-0059. RFC-0059 moved keeper keepalive *bodies* (switch-bound, cancellation-scoped, provider-streaming) onto worker domains and tore keepers down at boot by touching `ctx.sw` cross-domain (`keeper_supervisor_launch.ml:71-77`). This direction keeps every keeper fiber and the keeper switch on the main domain untouched, and moves only the **stateless dashboard serving** (which already crosses domains via `submit_io_or_inline` and reads wait-free `Atomic` snapshots) onto its own domain with its own switch. It would violate RFC-0059 only if it moved keeper bodies, forked the keepalive/watchdog onto the serving domain, or shared the keeper switch — it does none of these. Residual hazard is symmetric: serving-domain fibers must own their switch (per-domain `Eio.Switch.run`), never fork onto or cancel through `ctx.sw`, and never touch `Eio.Mutex`-guarded keeper state cross-domain (gated by the §9 Phase 3 per-handler audit).

## 9. Phased plan (each independently shippable + measured against the harness)

Ordered by leverage and risk. **Empirical gate: re-measure after Phase 0 at controlled load < 16. If WS-hello no longer times out, Phases 2–3 are deferrable** — do not build the domain split on the peak-pileup symptom alone.

| Phase | Change | Risk | Verifies |
|---|---|---|---|
| **0 — host hygiene + cheap server** | Operational: reduce the concurrent build/dev-server pileup (the dominant trigger; watchman recrawl already fixed in `~/.watchmanconfig`). In-server: wire the dead `submit_cpu` (weight 1.0) for the heavy board/JSON handlers; verify the 8-surface pre-warm actually populates `Dashboard_cache`. | Low (operational, reversible; pool-admission accounting only) | Whether WS-hello times out purely from host pressure. Sets the controlled-load baseline. |
| **1 — session-field synchronization** | Put the `dashboard_authenticated`/`dashboard_agent` writes (`server_mcp_transport_ws.ml:344-345`) under `with_sessions_rw`; audit the unlocked readers (`:275/:378/:409/:430/:445/:661/:708`). | Low; no behavior change under current single-domain serialization | Prerequisite gate for Phase 3. A latent-race removal on its own. |
| **2 — RFC-0204 Option A pool + publisher offload** | Add the dedicated dashboard `Executor_pool`; route `Dashboard_snapshot.refresh_loop` compute (`dashboard_snapshot.ml:137-203`) through it like the per-surface loops. Makes the publisher reliable → enables `light`→snapshot (§8.3) as a real fix, not staleness. | Low-med (domain budget, §7) | Dashboard refresh + light-shell never queue behind keeper compute. |
| **3 — ROOT: dedicated serving domain** | Spawn one serving domain with its own switch; move WS transport start (`server_runtime_bootstrap.ml:771`), the 5 refresh publishers + full-health (`:886-916`), and the HTTP accept loop onto it. Keepers stay on `ctx.sw` = main. | Med (Eio domain/switch affinity — the §8.5 hazard); env-flag gated, per-handler shared-state audit, keeper-burst regression test as merge gate | WS `dashboard/hello` + provider-logs latency stay flat while keeper reactive concurrency is driven to saturation (§5 keeper-burst test). The only phase that proves the root. |

Mitigations worth doing alongside (none replace Phase 3): a server-side `Eio.Time.with_timeout` around the `dashboard/hello` branch (surfaces starvation as a typed error instead of a silent 30s client timeout — observability, not a fix); deploy the already-merged SSE `/mcp` observer auth fix (#19401) so the 3-tier fallback has a working middle layer. **Do not** raise `DASHBOARD_WS_RPC_TIMEOUT_MS` (`dashboard/src/config/constants.ts`, 30_000) — symptom suppression (CLAUDE.md cap/cooldown bar); the queue still grows.
