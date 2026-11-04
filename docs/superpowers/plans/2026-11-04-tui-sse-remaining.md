# Remaining TUI SSE Transition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove every remaining periodic TUI data read without making notification-driven reads more expensive than the old two-second cadence.

**Architecture:** Keep authoritative HTTP reads on startup, explicit refresh, reconnect, and change notifications. Cache expensive projections once per workspace/Keeper, update them at real writes, and use the existing observer for freshness. Remove `--refresh` only after all surfaces and spectators have push ownership and retry/reconnect recovery.

**Tech Stack:** OCaml 5.5.1, existing workspace datasets and Lane observations, Alcotest, Python PTY fixtures, targeted remote checks.

**Spec:** `docs/rfc/RFC-0480-tui-reads-when-the-server-says-something-changed.md` §4.1 and `docs/rfc/RFC-machine-spectating-goes-through-lanes.md`.

## Global Constraints

- No polling fallback, new environment variable, full-ledger reread per notification, or screen-wording test.
- SSE remains a freshness signal; authoritative state comes from the existing read paths or existing typed streams.
- Cold caches may read once. Every later update must come from the actual store write, not another full scan.
- Withdrawal, reconnect, failed reads, visibility changes, and pending actions preserve existing ownership and identity.

## Review Focus

- A write for one Keeper/instance must not recompute or reread every Keeper/instance (each task's scoped test).
- Cold and warm reads must produce the same values and preserve unavailable/error distinctions (each task's cache comparison).
- A notification burst must create one trailing read, not unbounded requests (each task's single-flight test).
- Observer gaps must trigger full revalidation because pre-buffer failures are invisible to cursors (shared observer epoch coverage and final PTY).
- Removal of `--refresh` must leave login expiry, stream reconnect, and display-only age animation intact (final lifecycle tests).

---

### Task 1: Incremental Memory health

**Files:**
- Modify: `lib/server/server_dashboard_http_keeper_memory_health.ml`
- Modify: `lib/server/server_dashboard_http_keeper_memory_health.mli`
- Create: `lib/server/server_memory_health_runtime.ml`
- Create: `lib/server/server_memory_health_runtime.mli`
- Modify: relevant memory/continuity/progress store observer registrations
- Test: `test/test_server_dashboard_http_keeper_memory_health.ml`
- Test: `test/test_tui_observer.ml`
- Test: `test/test_tui_memory_push.py`

**Interfaces:**
- Produces: `Memory_health of { keeper : string }` and cold-once/per-Keeper cached health reads.
- Consumes: existing `keeper_health ~config ~keepers_dir` and real memory-store writes.

- [ ] Write failing tests: two warm health reads do not reload every journal; a write for Keeper A updates only A and announces only A; observer decoding rejects missing/blank Keeper.
- [ ] Verify RED: current warm reads rescan, no scoped announcement exists.
- [ ] Implement one cold read per Keeper, write-time replacement, dataset publication, and visible-row owed reads with retry/reconnect.
- [ ] Verify GREEN and measure the same live Memory surface before/after, including a Keeper with no Librarian commit whose old path read the whole journal.
- [ ] Commit: `feat(memory): maintain Keeper health on writes`.

### Task 2: Incremental Skill usage aggregation

**Files:**
- Modify: `lib/keeper/keeper_skill_activation_ledger.ml`
- Modify: `lib/keeper/keeper_skill_activation_ledger.mli`
- Create: `lib/server/server_skill_usage_runtime.ml`
- Create: `lib/server/server_skill_usage_runtime.mli`
- Modify: `lib/server/server_routes_http_routes_activity.ml`
- Test: `test/test_keeper_skill_activation_ledger.ml`
- Test: `test/test_dashboard_http_core.ml`
- Test: `test/test_tui_observer.ml`

**Interfaces:**
- Produces: cold-once/per-session usage cache and write-time `Skill_activations` replacement.
- Consumes: existing ledger `load`, `usage_for_reference`, and committed writer results.

- [ ] Write failing tests: a second `/api/v1/skills` projection does not reload every ledger; a committed activation changes only its session's counts; idempotent re-observation changes nothing.
- [ ] Verify RED: current route reloads all ledgers each time.
- [ ] Register commit observers, retain the latest ledger per session, and project usage from that cache. Cold sessions retain metadata-unavailable distinctions.
- [ ] Verify GREEN and compare allocation and response time for repeated reads on the same workspace.
- [ ] Commit: `perf(skills): aggregate activation usage on writes`.

### Task 3: Browser and machine observation streams

**Files:**
- Modify: `lib/lane_addon/lane_addon_runtime.ml`
- Modify: browser/machine observation routes and stream modules
- Modify: `bin/masc_tui.ml`
- Modify: `bin/masc_tui_types.ml`
- Test: browser/Lane observation protocol suites and `test/test_tui_observer.ml`
- Test: `test/test_tui_spectator_push.py`

**Interfaces:**
- Produces: observation sequence/freshness for the visible browser client, tab, viewport, and machine incarnation; no periodic `cadence_operation`, live route, or machine tick reads.
- Consumes: existing observation commit and `seq`, Browser `Screenshot`/`Scene`, and machine live projections.

- [x] Write failing request tests: a changed observation updates only its matching client/tab/machine; unchanged observations emit no read; pointer gestures retain their original ownership.
- [x] Verify RED: current TUI polls these paths every 0.3/2 seconds.
- [x] Implement server-side changed-observation notification plus the existing read/stream path, single-flight trailing reads, and reconnect revalidation. Do not put large image bytes in `workspace_dataset_changed`.
- [ ] Verify GREEN and measure request counts, PTY frame cadence, and screenshot/incarnation continuity.
- [ ] Commit: `feat(tui): stream browser and machine observation changes`.

### Task 4: Remove the shared refresh cadence

**Files:**
- Modify: `bin/masc_tui.ml`
- Modify: `bin/masc_tui_types.ml`
- Modify: `docs/rfc/RFC-0480-tui-reads-when-the-server-says-something-changed.md`
- Test: observer/reconnect, identity expiry, Lanes, Memory, browser, and spectator suites

**Interfaces:**
- Consumes: all earlier push/read ownership and the existing contact retry.
- Produces: no periodic data-read block and no `--refresh` option; explicit `r`, startup, reconnect, and display-only animation remain.

- [ ] Write failing lifecycle tests for every remaining read owner, reconnect, consent deadline, and explicit refresh.
- [ ] Verify RED on any surface that still reads periodically or loses recovery.
- [ ] Remove the shared cadence block, option, and dead intent only after every preceding task passes. Preserve contact retry and non-data timers.
- [ ] Verify GREEN and record a fixed idle interval with no periodic data request, then one request per visible change and one reconnect revalidation.
- [ ] Commit: `refactor(tui): remove the shared refresh cadence`.
