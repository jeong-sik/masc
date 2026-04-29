# Changelog


## [0.18.13] - 2026-04-30

Aggregate of 389 commits since v0.18.9 (147 feat / 74 chore / 54 fix / 26 docs / 25 test / 20 refactor / 8 spec / 3 ci, plus filename-scoped surface pins). No breaking API changes.

This is a release-truth catch-up for the 0.18.10-0.18.13 stabilization train. The headline thread is keeper/OAS boundary hardening after budget-loop and local Ollama timeout failures, plus dashboard/runtime visibility cleanup and CI/release hygiene.

### Added

- OAS provider error variant contract, metric export, and dashboard telemetry samples for provider/cascade diagnosis.
- Resolved-goal verification evidence and expanded dashboard/runtime surfaces for operator truth.
- Performance and reliability instrumentation, including dashboard WS load harness, cache hit/miss counters, GC quick-stat sampling, and cold/warm tool-call labels.

### Fixed

- Keeper OAS timeout behavior: fallback budget reservation, repeated `oas_timeout_budget` auto-pause, hard-quota fail-fast handling, and local Ollama token-cap tuning.
- Docker-backed keeper execution: `HOME=/tmp` coverage for run/exec/shell paths and runtime contract visibility fixes.
- Dashboard CI/typecheck stability, provider cascade clarity, fleet idle recovery false positives, and stale TLA/spec-line references.

### Changed

- OAS pin metadata refreshed through the reachable `0.184.0` SDK line and downstream version truth synced to `0.18.13`.
- Keeper tool preset UI compatibility removed after the runtime-facing preset model moved to typed gate decisions.
- TLA deadlock checking narrowed for `AutonomousLoop` terminal-state behavior so CI tracks the intended invariant surface.

### Deprecated

- None.

## [0.18.9] - 2026-04-28 — patch: spec ↔ code bidirectional identity infrastructure (Cycle 24-44 autonomous series) + 234 operational commits

Aggregate of 254 commits since v0.18.8 (109 feat / 33 fix / 37 docs+spec / 36 chore / 34 refactor / 3 test / 1 quality / 1 ci). No breaking API changes. Patch bump (per #11388 narrow-scope precedent); a minor bump (`0.19.0`) is also defensible given the 109 `feat` commits and is a release-manager call.

The headline thread for this release is the autonomous **Cycle 24-44 spec ↔ code identity series** (20 PRs, all spec/docs only, behavior-change 0). The series closes the discoverability gap users observed as "lifecycle 30-40% black-box": OCaml subsystems whose specs already cited them but had no reverse anchor. Two patterns:

1. **Anchor addition** (Cycle 24-39, 16 PRs) — adds a `(* Spec navigation (OCaml -> TLA+) ... *)` block plus inline anchors to OCaml modules so code search lands on the authoritative spec module.
2. **Citation refresh** (Cycle 40-43, 4 PRs) — verifies and corrects stale OCaml line citations in 5 specs (`KeeperTurnCycle`, `KeeperCascadeLifecycle`, `KeeperDecisionPipeline`, `KeeperHeartbeat`, `KeeperSocialModelMagenticLedger`, `KeeperEmptyToolUniverse`) and adds a forward-stability disclaimer ("function names are stable identifiers; lines drift across edits") that converts future drift into metadata-only refreshes.

### Added (spec ↔ code navigation infrastructure — autonomous Cycle 24-44)

- `#11565` derive_phase navigation block (`keeper_state_machine.ml`) — Tier C1 Phase 0 anchor with 4-way Drift/Refinement classification per priority branch.
- `#11583` `specs/keeper-state-machine/KeeperLaunchPending.tla` — new 3-phase pre-launch spec (Offline/Running/Dead) with `FiberStartedWithoutClearing` bug action; resolves the previous "Note A drift candidate" entry in derive_phase navigation block (#11584).
- `#11596` `keeper_keepalive.ml` — Heartbeat anchor (B1, 3 transitions: WakeupSignal/HeartbeatTick/MissedWakeup).
- `#11597` `keeper_unified_turn.ml` — TaskAcquisition anchor (B2, AssignTask/EmptyQueueSleep/TaskRejected).
- `#11599` `keeper_approval_queue.ml` — ApprovalQueue anchor (B3, Submit/Resolve/ExpireAndForceResolve + BoundedSuspension invariant).
- `#11608` `keeper_failure_circuit_breaker.ml` — CircuitBreaker anchor with Refinement classification (5 OCaml classes vs 3 spec abstract classes, by-design).
- `#11612` `keeper_rollover.ml`, `#11614` `keeper_post_turn.ml`, `#11615` `keeper_types.mli` — KeeperGenerationLineage 3/3 closure.
- `#11617` `keeper_memory_policy.ml`, `#11622` `keeper_memory_bank.ml` — KeeperMemoryLifecycle 2/2.
- `#11618` `keeper_execution_receipt.ml` — multi-spec anchor first (ReceiptOutcomeSet + OperatorPauseBroadcast).
- `#11625` `keeper_stale_watchdog.ml` — OperatorPauseBroadcast 2/2 with module-relocation drift correction.
- `#11626` `keeper_social_model_magentic_ledger_fsm.ml` — SocialModelMagenticLedger anchor with issue #8949 topology drift record.
- `#11634` `keeper_guards.ml` — KeeperTurnCycle anchor (single-action `GateRejected` ownership).

### Changed (spec citation refresh — autonomous Cycle 40-43)

- `#11641` `KeeperTurnCycle.tla` — 22 stale line citations across 4 OCaml files refreshed to current main; forward-stability disclaimer added.
- `#11645` `KeeperCascadeLifecycle.tla` + `KeeperDecisionPipeline.tla` — sibling refresh of the same `keeper_registry.ml` setter family (`mark_turn_started` 386→493, `mark_turn_finished` 472→614, etc.; 8 setters total).
- `#11647` `KeeperHeartbeat.tla` — 3 stale `keeper_keepalive.ml` citations refreshed (uniform +13 drift; matches Cycle 27 anchor's inline drift note).
- `#11649` `KeeperSocialModelMagenticLedger.tla` + `KeeperEmptyToolUniverse.tla` — narrow batch (2 specs, 1 line each + adjacent anchors).

### Other operational changes (234 commits)

This release also rolls up substantial operational and infrastructure work merged since v0.18.8 — see `git log bff6a28b..HEAD` for the full set. Notable themes (without exhaustive PR-by-PR enumeration):

- **PPX `tla_derive`** (`#11377`, `#11384`, `#11430`, `#11450`) — PPX deriver scaffold + `keeper_turn_fsm.mli` first application + `module type TLA_STATE_MACHINE` + `[@fsm_guard]` runtime injection (Tier I1/I2/I3 of the Kimi keeper FSM review plan).
- **Receipt outcome quad-state** (`#11360`, `#11491`, `#11499`, `#11500`) — `outcome_kind = [`Ok | `Error | `Cancelled | `Skipped]` polymorphic variant + outer Cancel handler producer + spec parity (Tier S1 + Cycle 1b A/i/ii/iv).
- **`AuthIdentityFSM.tla` integration** (`#11391`) — `specs/auth/` directory + clean+buggy cfg (Tier S2).
- **Receipt append failure escalation** (`#11398`) — silent `Log.warn` → `Result.Error \`Receipt_lost` (Tier A2).
- **Path leak removal** (`#11403`) — relative paths or hashes in `keeper_alerting_path.ml` error strings (Tier A3).
- **Heartbeat / TaskAcquisition / ApprovalQueue specs** (`#11408`, `#11412`, `#11417`) — 3 new spec modules with bug-action contracts (Tier B1/B2/B3).
- **`tools/tlc_test_gen/`** (`#11525`, `#11539`, `#11553`, `#11563`) — TLC counterexample → OCaml regression test scaffold + nested record fixture + PPX-free test runner + multi-spec self-validation (Tier C2).
- **234 other operational commits** across feat/fix/refactor/chore — feature work in cascade routing, dashboard, MCP transport, design-system token migration, PPX adoption, type SSOT extractions, OAS pin bumps, etc.

### Notes

- The autonomous Cycle 24-44 series is documented in `~/me/planning/claude-plans/30m-users-dancer-downloads-kimi-agent-ke-wobbly-shell.md` §19.
- All 20 spec/docs PRs in the Cycle 24-44 series are behavior-change 0; they affect only TLA+ and OCaml comments. The release boundary is largely a marker for the broader 254-commit corpus.

## [0.18.8] - 2026-04-28 — patch: keeper fleet reliability (goal repair + auto-task-start + preset coordination)

Aggregate of 8 commits since v0.18.7 (3 feat / 2 fix / 2 test / 1 chore). No breaking API changes.

Keeper fleet reliability release: empty `active_goal_ids` now auto-repairs via persona audit (PR1 #11351), claimed tasks auto-start immediately (PR2 #11364), and social/dispatch presets gained coordination tool access (PR3 #11345).

### Added (keeper reliability)

- **keeper_goal_repair**: detect and repair keepers with empty `active_goal_ids` by creating goals from persona purpose statements. New module `Keeper_goal_repair` with dry-run and execute modes.
- **auto-task-start**: `keeper_task_claim` now automatically calls `masc_transition(action=start)` after successful claim, eliminating the claim-without-start pattern that caused task abandonment.
- **preset coordination tools**: social and dispatch tool presets now include `masc.coordination` group, granting access to `masc_transition`, `masc_claim_next` and related coordination tools.

### Fixed

- Keeper audit now reports `empty_active_goal_ids` as an actionable issue with repair guidance.
- Keeper meta reconciliation detects goal-less keepers and surfaces them in audit output.

### Changed

- `scripts/ocaml-structure-baseline.json` updated: `keeper_mli_missing: 21`, `lib_dune_lines: 954`.


## [0.18.7] - 2026-04-27 — patch: keeper contract fix (require_tool_use stay_silent) + dashboard KpiStrip canonical sweep + observability + auth fail-closed

Aggregate of 17 commits since v0.18.6 (11 feat / 4 fix / 1 test / 1 chore). No breaking API changes.

Operational keeper-contract correctness release: `require_tool_use` contract now accepts `keeper_stay_silent` as a satisfied turn (decisive no-op), eliminating a contract-vs-prompt mismatch that rejected ~40% of post-cascade-fix turns. Plus dashboard StatCard retirement (3-sweep migration into KpiStrip) and observability surface emissions for substrate visibility.

### Added (observability + structural)
- `#11125` observability — emit `[substrate:tool_surface]` log + SSE on TurnReady (per-turn tool surface visibility)
- `#11133` observability — emit `[substrate:system_prompt]` per keeper turn (operator visibility into per-turn prompt content)
- `#11121` keeper — high-priority `.mli` files for keeper modules (interface contract surfacing)
- `#11120` test — cross-FSM joint behavior tests mirroring TLA+ SafetyInvariant
- `#11126` specs — AuthIdentityFSM bug-model for silent identity fallback

### Changed (dashboard KpiStrip canonical sweep)
- `#11135` retire StatCard, migrate 27 callsites to KpiStrip+KpiCell (sweep #3)
- `#11130` migrate feature-health overview into KpiStrip (sweep #2)
- `#11128` migrate overview funnel into KpiStrip (sweep #1)
- `#11122` add KpiStrip composite (cb-group-a SPEC alignment)
- `#11118` adopt KpiCell in feature-health overview (apply cycle 2)
- `#11116` adopt KpiCell in overview funnel (apply cycle 1)
- `#11131` design-system — add 4 raw tokens + migrate bonsai flame_*

### Fixed (keeper contract correctness)
- `#11124` keeper — classify `keeper_stay_silent` as `Completion` to satisfy `require_tool_use` contract (decisive no-op recognition; abuse defence retained via `keeper_stay_silent_loop_detector`)
- `#11132` server-auth — fail-closed on `Ok None` instead of silent dashboard rewrite (security hardening)
- `#11117` scripts — resolve log path via lsof on running server, eliminate $HOME drift
- `#11123` keeper — raise compact_ratio default 0.5 → 0.85 (#11111 follow-up, fewer premature compactions)

### Removed
- `#11119` mcp — drop deprecated prompt stubs (`execution_session_proof`, `command_truth`)

## [0.18.6] - 2026-04-27 — patch: keeper resilience (retry guard + watchdog auto-pause) + design-system token wave continuation + i18n rounds 95-101

Aggregate of 37 commits since v0.18.5 (15 fix / 13 feat / 7 i18n / 1 perf / 1 chore). No breaking API changes.

Operational hardening release: keeper recovery surfaces (oas_timeout retry guard relax, watchdog auto-pause on stale termination storm, zombie detection seed, cascade-filter dedup) plus continuation of canonical SPEC token wave (status/border/bg-hover/bg-surface/accent-soft/CSS-files) and 7 localization rounds.

### Added
- `#11070` dashboard — Heartbeat + LifelineBar primitives (cb-group-a)
- `#11066` dashboard — KpiCell primitive (cb-group-a, Stage A)
- `#11088` dashboard — TickerItem + TickerStrip primitives (cb-group-a)
- `#11075` transport — P1 failure-path counters for SSE broadcast
- `#11068` coord — extract local git op timeout to env (SSOT, #10426)

### Changed (design-system canonical SPEC tokens)
- `#11095` adopt canonical SPEC tokens in handwritten CSS files
- `#11087` canonical SPEC §3.5 status tokens (10-file sweep)
- `#11085` canonical accent-soft token in 5 remaining files (CS105)
- `#11076` canonical accent-soft token in 5 files
- `#11073` canonical SPEC border tokens (`--border-slate-N` sweep)
- `#11067` canonical bg-hover token (`--bg-panel-hover` sweep)
- `#11065` SPEC fs scale for arbitrary `text-[10px]/text-[11px]`
- `#11064` canonical SPEC bg-surface in 5 files (`--card → --color-bg-surface`)

### Fixed (keeper resilience)
- `#11057` keeper — relax `oas_timeout` retry guard 30→15 (cycle6 band-aid)
- `#11055` keeper-watchdog — Phase 2 auto-pause on stale termination storm (closes #10765)
- `#11062` keeper — seed `last_turn_ts` to bootstrap time so watchdog can detect zombies
- `#11084` cascade-filter — dedupe `all-providers-rejected` WARN, promote first to ERROR (#11060)
- `#11080` keeper — stop leaking host playground paths to LLM tool responses
- `#11099` keeper — surface 5 P2 silent failures (telemetry gaps)
- `#11074` keeper — surface 2 P1 silent failures in registry
- `#11077` keeper — resolve `unknown_toml_keys` and tidy provider match errors

### Fixed (build / types / dashboard)
- `#11092` main — restore green build broken by #11077 + #11078
- `#11093` coord — Eio 1.0+ types in `coord_utils_backend_setup.mli`
- `#11078` coord — add missing `.mli` files for coord_utils and worktree
- `#11094` dashboard — surface 6 P2 silent failures (telemetry gaps)
- `#11072` auth — add token hash prefix to dashboard fallback warn
- `#11041` server-auth — decompose dashboard fallback `err_kind` beyond `[other]`
- `#11061` a11y — add ARIA attributes to connector-config-form

### i18n
- `#11098` localize 4 fallback error literals (round-101)
- `#11091` localize 10 api/ thrown Error payloads (round-100)
- `#11086` localize 3 keeper API thrown errors (round-99)
- `#11082` finish fsm-hub-lane-analysis (round-98)
- `#11071` localize turn/decision/cascade/compaction lane meanings (round-97)
- `#11069` localize 9 'phase' lane meaning fields (round-96)
- `#11063` localize 'vs env' delta suffix (round-95)

### Performance
- `#11090` hoist per-call `Re.compile` to module-level bindings

### CI / chore
- `#11089` naturalize L1a baseline 27→28 to match main

## [0.18.5] - 2026-04-27 — patch: design-system canonical SPEC token wave + i18n round 90-92 + env SSOT extractions

Aggregate of 19 commits since v0.18.4 (10 feat-design-system / 4 fix / 3 i18n / 1 feat-typography / 1 feat-sidecar). No breaking API changes.

Continuation of the design-system unification wave — converts 10 dashboard surfaces to canonical SPEC color/accent/fg tokens (CS89 onward) and finalizes localization rounds 90-92. New env-driven SSOT extraction surface for sidecar subprocess timeouts.

### Added
- `#11039` dashboard — SPEC §3 typography & spacing scale (Phase G Step 2)
- `#11049` sidecar — extract subprocess timeouts to env (SSOT)

### Changed (design-system canonical SPEC tokens)
- `#11050` server-config fg token
- `#11053` accent token sweep across 6 files
- `#11048` accent token in 3 remaining files
- `#11042` color tokens in feature-health & transport-beacon
- `#11035` color tokens in prometheus-metrics
- `#11033` color tokens in keeper-detail-shell
- `#11031` color tokens in autoresearch
- `#11028` color tokens in keeper-config-panel
- `#11027` color tokens in telemetry-unified
- `#11023` cascade-config-panel tokens (CS89)

### Fixed
- `#11056` dashboard — update test assertions for i18n localized strings
- `#11038` dashboard — surface 3 P1 silent failures
- `#11037` oas-worker-exec-transport — remove unreachable catch-all in transport_for_provider
- `#11032` mcp/join-guard — resolve rotation alias to canonical join entry (#10699 Family A)

### i18n
- `#11034` localize 4 operator-actions extractApiError fallbacks (round-92)
- `#11030` localize 4 user-facing strings outside components/ (round-91)
- `#11026` localize transport-beacon + keeper-detail-shell tooltips (round-90)


## [0.18.4] - 2026-04-27 — patch: a11y completion + worktree cleanup extension + log severity ratchet

Aggregate of 29 commits since v0.18.3 (12 fix / 7 i18n / 4 feat / 3 refactor / 2 a11y / 1 perf / 1 ci, includes 10 commits landed during release CI window). No breaking API changes.

Follow-up patch that closes the dashboard a11y round (#10930 focus trap + aria-expanded landed), extends worktree auto-cleanup to Cancel/Release transitions building on the v0.18.3 leak root fix, and introduces the log severity anti-pattern detector ratchet baseline.

### Fixed
- `#10930` dashboard a11y — focus trap, aria-expanded, readability (final round-6 landing after rebase cycle)
- `#11001` coord/task — extend worktree auto-cleanup to Cancel and Release transitions (continuation of v0.18.3 #10956 root fix)
- `#10999` keeper-watchdog — emit fleet batch-termination ERROR when ≥3 keepers stop in 30s (#10765 follow-up)
- `#11008` build — drop 5 redundant catch-all arms after provider_kind exhaustive sweep
- `#11019` provider — exhaust provider_kind matches for lint (broader sweep)
- `#11022` session — bound registry + mcp-store mailboxes (was max_int)
- `#11024` keeper — include unknown_toml_keys in merge_overlay
- `#11025` keeper — warn once when sandbox GH_TOKEN unavailable
- `#11012` keeper-supervisor — surface persona drift at registration (#10993)
- `#11004` admission — inline fd-growth rate in admission rejection log (#10745)
- `#10995` approval-queue — skip Critical risk in expire_stale to break re-enqueue cycle
- `#10992` contract — harden public tool sweep and runtime guard edges

### Added
- `#11013` dashboard — extend SPEC §3 color alias bridge in variables.css (CS87)
- `#11011` keeper — capture unknown TOML keys on profile_defaults
- `#10997` dashboard — adopt KeeperBadge in ConnectorKeeperMatrix row label

### a11y
- `#11017` dashboard — agent-detail role=log/region/progressbar
- `#11021` dashboard — auth-status aria-expanded/haspopup

### Performance
- `#11002` dashboard — isolate fsm-hub render scope from 5 s tick

### Changed
- `#11016` server-bootstrap — demote 5 recoverable cleanup Errors → Warn (§ 3.3)
- `#10994` design-system — swap connector restart button to ActionButton ok (PR-CS83)
- `#10981` design-system — swap activity-stream FilterBar to ActionButton ghost (PR-CS81)

### CI
- `#11000` log severity anti-pattern detector — Phase 1 ratchet baselines

### i18n
- `#10990` `#10996` `#10998` localize nextExpectedStep return strings (rounds 83–85)
- `#11003` localize 7 detail field strings (round-86)
- `#11005` finish fsm-hub-invariant-analysis (round-87)
- `#11006` localize "Tool telemetry unavailable" fallback (round-88)
- `#11014` localize 2 short matrix tooltip titles (round-89)


## [0.18.3] - 2026-04-27 — patch: leak root fixes + keeper observability + design-system progress

Aggregate of 30 commits since v0.18.2 (9 feat / 6 refactor / 6 fix / 4 i18n / 3 docs / 2 perf). No breaking API changes.

Follow-up to v0.18.2 stability hardening. This release closes two long-standing leak issues at the source (autoresearch + keeper-playground worktree cleanup) and continues design-system swap wave + KeeperBadge primitive adoption. All `feat` entries are additive.

### Fixed (leak root cause)
- `autoresearch`: auto-cleanup managed worktree on terminal transition (#10892, #10968) — `Switch.on_release` pattern, prevents per-job dir accumulation (~91 MB / job pre-fix).
- `coord/task`: auto-cleanup playground worktree on task done (#10899, #10956) — `Coord_hooks` task_done pattern, closes contract gap when keeper crashes mid-task / watchdog stale-termination / SP-suppression / LLM forgets to call `masc_worktree_remove`.

### Fixed (keeper / fleet hot path)
- `server`: wire `approval_janitor` fork to break HITL death-spiral (#10973).
- `mcp/call_tool`: demote policy/workflow rejections from ERROR to WARN (#10975, #10978).
- `keeper/sp`: probe escape valve every 10 same-cohort suppressions (#10887, #10948).

### Added (keeper observability)
- `keeper`: surface deliberate-skip reasons on stale watchdog kill (#10962).
- `coord/task`: Prometheus counter + warn log for `task_claim_next` implicit auto-release (#10421, #10977).
- `masc_oas_bridge`: cancel reason bucket + inner exception (#10954) — surfaces OAS cancellation provenance.

### Added (dev tooling / SSOT)
- `keeper-bootstrap`: extract autoboot polling/settle intervals to env (SSOT) (#10957).
- `dashboard`: `ErrorRecoverable` + `ErrorFatal` 2-tier error states (#10965).
- `dashboard`: `KeeperBadge` primitive + adoption in safe-autonomy `FindingsList`/`KeeperCard`/`TimelineList` (#10955, #10970, #10983).
- `docs/spec`: log severity taxonomy SSOT — anti-pattern catalog + lint rule scaffold (#10963).

### Refactor
- `dashboard`: extract `createSharedTicker` factory + dedup boilerplate (#10971) — shared ticker helper for periodic re-render across panels.
- `design-system swap wave`: PR-CS75 ~ PR-CS82 (#10966, #10974, #10979, #10980, #10987 + others) — ActionButton variants (warn / ghost), TextArea swaps.

### Perf
- `dashboard`: migrate fsm-hub timeline + pipeline children to `nowSecondsSignal` (#10961, #10969).

### i18n
- `dashboard`: localize Idle snapshot headline (round-71), substring-safe headlines (round-73), keeper directory error panel (round-78), composite-fsm-flowchart, sectionLabel for fleet-health/safe-autonomy (#10939 / #10943 / #10964 / #10984 / #10976).

### Docs
- `docs/coord`: add `coord_gc.mli` + `coord_git.mli` (#10751 batch — #10958 / #10960).
- `scripts`: add `cleanup-autoresearch.sh` interim TTL quarantine + help-text polish (#10913 / #10967).

### Bumps
- dune-project version 0.18.2 → 0.18.3
- masc_mcp.opam version 0.18.2 → 0.18.3
- CHANGELOG.md: v0.18.3 entry added (0.18.2 history preserved)
- ROADMAP.md / docs/PRODUCT-OPERATING-PLAN.md / docs/spec/SPEC-INDEX.md: version refs synced

### Out of scope (deferred)
- 4 stale `sangsu-task-*` orphan worktrees from before #10956 land (Apr 22, dirty 1-line `network_mode` config) — operator manual sweep recommended in #10899 follow-up comment.
- #10930 / #10871 user a11y stack PRs (`a11y-006` / `a11y-007`) — most patches already upstream via #10874; recommended cherry-pick novel only or close + restart.


## [0.18.2] - 2026-04-27 — patch: keeper stability hardening + observability + dev tooling

Aggregate of 66 commits since v0.18.1 (18 fix / 8 feat / 14 refactor / 6 perf / 9 i18n / 8 squash / 2 chore / 1 test). No breaking API changes.

Follow-up to v0.18.1 ProviderTerminal rescue. This release collects a wave of keeper-watchdog / cascade rotation / autoboot / sandbox-docker fixes that landed after a focused diagnostic cycle, plus dashboard-side observability and dev-tooling SSOT cleanup. All `feat` entries are additive (env knobs, lint detector, telemetry semantic refinement, dev scripts, design-system sync) — no behavioural defaults changed for runtime keepers.

### Fixed (keeper / fleet hot path)
- `keeper-watchdog`: suppress idle-stale events during an active turn; add a separate turn-timeout (default 600s) so watchdog stops misclassifying mid-turn LLM waits as stalls (#10940).
- `keeper`: cap cascade rotation at 1 for `required_tool_contract_violation` so a single proactive contract miss can't cycle through every provider (#10851).
- `coord/task`: emit warn when a task crosses the 5-cycle oscillation threshold so operators see escalation candidates (#10719, #10920).
- `server/autoboot`: per-task boot guard so a single hung lazy task can't block keeper boot — restore_sessions now degrades gracefully instead of hanging the boot pipeline (#10857).
- `boot`: start `Oas_worker_cascade` actor consumer fiber that was dropped in a refactor and left the cascade actor without a reader (#10895).
- `cascade-filter`: per-provider rejection diagnostics for #10681 so cascade-skip reasons are visible per provider, not aggregate (#10852).
- `keeper-shell-docker`: detect `gh --repo X api Y` LLM-hallucinated form and self-correct (108 events / day pre-fix, #10855, #10900).
- `keeper-shell-docker`: replace `List.hd` with pattern match (Health ratchet, #10905).
- `auth`: stop classifying `keeper-<id>-agent` as a transient alias so per-keeper credentials don't churn (#10867).
- `auth`: surface `error_kind` + `actor_hint` in `dashboard_actor_fallback` warn payload for easier triage (#10933).
- `post_verifier`: add Korean filler phrases (filler detector previously English-only, #10882, #10938).
- `coord/config`: memoize `default_config` to drop 1745 redundant inits / 2 days (#10919, #10937).

### Fixed (dashboard / health / hygiene)
- `health`: replace `List.hd` with pattern match in `keepers_directory` (#10926).
- `dashboard`: a11y restore `role=status`/`role=alert` on loading/error indicators (#10874).
- `dashboard`: update test expectations for i18n-localized flag tooltips (#10929).
- `coord/backend`: demote per-call backend init logs to DEBUG (1745 events / 2d, #10919, #10928).
- `keeper/watchdog`: demote all-default tick log to DEBUG (1638 events / 2d, 92% all-healthy, #10908, #10910).
- `ws-transport`: downgrade per-session lifecycle log to DEBUG (4029 events / 31min, #10875, #10881).

### Added (feat — additive, env-gated where applicable)
- `dashboard`: extract mission/shell/render timeouts to env (SSOT, #10880).
- `dashboard`: extract execution-surface timeouts to env (SSOT, #10886).
- `process`: consolidate 11 hardcoded subprocess timeout defaults to env (SSOT, #10889).
- `lint`: detect Eio actor consumer fibers that are never wired up (covers the #10895 class of bugs at the lint layer, #10904).
- `scripts`: add `cleanup-autoresearch.sh` — TTL-based quarantine for stale autoresearch dirs (#10913).
- `telemetry`: mark `Goal_event` as `optional_when_missing` — show `not_yet` instead of `missing` for keepers that haven't emitted yet (#10921).
- `design-system`: sync v0.4.3 — extract `semantic.css` + 6 preview pages (#10898).
- `dashboard`: localize Cascade profile tooltip + reveal aria (round-52, #10811).

### Changed (perf — dashboard re-render reduction)
- `dashboard/fsm-hub`: drop 1 Hz tick to 5 s for re-render reduction (#10894).
- `dashboard/fsm-hub`: drop self-triggering `pollTick` from interval deps (#10914).
- `dashboard`: hoist 5 s wall-clock tick to a shared module signal (#10918).
- `dashboard`: hide `sourceMappingURL` to stop browser map auto-fetch (#10907).
- `dashboard`: add opt-in bundle visualizer (`BUNDLE_REPORT=1`, #10897).
- `transport`: label `sse_broadcast_events_total` by `target` for per-target broadcast attribution (#10916).

### Changed (refactor / i18n / squash)
- 14 refactor PRs (design-system migration across multiple panels, dashboard utility consolidation).
- 9 i18n rounds (rounds 52, 68, 69, 70, 72, 74) covering ~25 chips/labels/empty-state strings.
- 8 squash merges (autocoder dedup + small-PR rollups).

### Notes
- Diagnostic chain that drove this batch: `#10474` cascade dead → `#10745` fd leak (separate fix wave, partially captured) → `#10765` keeper stale watchdog terminating fleet → `#10872`/`#10940` keeper-watchdog suppress + turn timeout. Diagnostic comments → autocoder fix loop closed end-to-end within 6 hours.
- Out of scope (deferred to follow-up release): `#10828` no process-level supervisor (awaiting operator policy decision; conflicts with `<launchd>` guidance), `#10887` keeper self_preservation `ratio=1.00` permanent lock (FSM circuit-breaker design review needed), `#10719` task-049 cycle=20 hard-stop escalation (this release adds the warn signal at threshold 5; threshold ≥15 hard-stop is a separate proposal).

## [0.18.1] - 2026-04-26 — patch: rescue v0.18.0 release (ProviderTerminal partial-match fix-forward)

Aggregate of 37 commits since v0.18.0 (14 feat / 10 fix / 9 refactor / 2 chore / 2 diag). No breaking API changes.

The v0.18.0 tag exists but its GitHub release workflow failed: the OAS pin bump to SHA `162940fd` (#10667) added a `ProviderTerminal` variant that broke 6 partial-match sites. This patch ships the fix-forward (#10713 + #10721) plus a batch of dashboard localisation, design-system migration, and keeper hardening work that accumulated on `main`.

### Fixed (rescue path)
- OAS boundary: close `ProviderTerminal` partial-match in `Oas_compat` + add `error_message` helper (#10721).
- OAS bridge: add `ProviderTerminal` arm at 3 partial-match sites (#10713).

### Fixed
- Watchdog: extract to standalone module, cover autoboot path (#10698).
- Coord: resolve `git_clone` policy at canonical `.masc/config/` path (#10693).
- Keeper: auto-pause on `cascade_exhausted` to break supervisor restart loop (task-074, #10691).
- Keeper: use container path for `default_cwd` / `private_workspace_root` in `masc_keeper_status` (#10650, #10686).
- Deploy: build dashboard SPA in Dockerfile multi-stage build (#10684).
- Dune: exclude misplaced `worktrees/` (no-dot) from dune scan (#10688).
- TLA+: add `Recycle` action to clear `OperatorPauseBroadcast` deadlock (#10678).
- Fleet: use sandbox arguments in `keeper_context_status` instead of host paths (#10677).

### Added (feat)
- Dashboard localisation rounds 31–41: 70+ chips/labels/headings/aria-labels across many components (#10685, #10689, #10690, #10695, #10697, #10700, #10703, #10708, #10712, #10714, #10723).
- Audit: keeper credential UUID layout integrity detector (#10718) and dual-identity drift detector (#10706).
- Design system: `ActionButton` `pressed` prop + tool-picker tier filter swap (PR-CS4, #10679).

### Changed (refactor)
- Design system PR-CS5 → PR-CS12: ActionButton/Select migration across runtime-monitor (#10722), connector-quick-bind (#10717), governance-monitor (#10715), agent-profile (#10705), memory-post-detail (#10702), tool-picker (#10694), error-panel (#10687), autoresearch (#10683).
- Rename `Oas_sse_bridge` → `Oas_event_bridge` (transport-agnostic, #10711).

### Chore
- OAS pin: bump SHA to `97b8a603` (OAS #1201 TurnReady event, #10704, #10709).

### Diagnostics
- Prometheus: capture EDEADLK backtrace on `metrics_mutex` (#10682, #10707).
- Keeper-tools-oas: capture backtrace on EDEADLK to identify mutex site (#10682, #10696).

## [0.18.0] - 2026-04-26

Aggregate of 50 commits since v0.17.0 (18 feat / 11 fix / 9 refactor / 5 perf / 3 docs / 3 chore / 1 diag). No breaking API changes. Headline: dashboard localisation continues (rounds 24–28, 50+ chips/labels), keeper stability gains noop-cycle classifier fix unblocking 8x cooldown trap (#10672) and `/workspace` LLM hallucination negative anchor (#10647), RFC-0008 PR-1 introduces `Credential_provider` trait + `Host_config_provider` (#10660).

### Added (feat)
- Dashboard localisation rounds 24–28: 50+ chips/labels/headings across multiple components (#10644 round-24, #10651 round-25, #10653 round-26, #10655 round-27, #10666 round-28); WS-only cutover dev default + transport beacon (#10657).
- Keeper architecture: RFC-0008 PR-1 — `Credential_provider` trait + `Host_config_provider` (#10660).
- Config SSOT: `Pr_review_post` caller (30s) + migrate `gh pr review` write site (#10626); `Git_meta` + `Shell_probe` callers added to `exec_timeout` SSOT (#10603).

### Changed (refactor)
- Common: `auth_dir` / `agents_dir` helpers hoisted to break P2 cycle (#10658); orphaned `Error` module + its coverage test dropped (#10659).
- Dashboard: `bg-0` / `bg-1` / `bg-2` migrated to semantic aliases (#10638); inline buttons replaced with `ActionButton` in transport-health (PR-CS1, #10646) and autoresearch (PR-CS2, #10656).
- Alerting: default 15→20s + `gh-issue-create` site migration (#10622).

### Fixed
- Keeper proactive scheduler: `Claim_context` excluded from noop cycle (#10672) — unblocks 8x cooldown trap that was pinning `ollama-local` and `qa-king` keepers.
- Keeper sandbox prompt: `/workspace` negative anchor + `workspace` word replaced (#10647) — addresses LLM training-time prior hallucination.
- Keeper concurrency: `Stdlib.Mutex` migrated to `Eio.Mutex` in single-domain hot paths (#10649).
- Cascade: judge profiles ordered gemini-first to skip codex 30s timeout cycle (#10642).
- Observability: `[max_turns]` / `[hard_quota]` class label prepended to cascade-fallback log (#10641, addresses #10629).
- Dashboard tests: `successClass` / `statusChipClass` aligned with semantic aliases (#10662); telemetry / overview tests aligned with current source (#10654).

### Performance
- 5 perf commits (text-similarity, gate-diff, auth, cdal-judge SSOT delegations).

### Diagnostics
- Observer: `last_turn_ts` exposed in composite snapshot for watchdog diagnosis (#10663).

### Documentation
- CHANGELOG 0.16.0 + 0.17.0 release notes filled (#10639).

## [0.17.0] - 2026-04-26

Aggregate of 103 commits since v0.16.0 (42 feat / 24 fix / 15 perf / 15 refactor / 4 chore / 2 docs). No breaking API changes. Headline: design-system semantic alias migration completes its bulk of CSS/JSX surface; cascade unblock series resolves repeated `agent_sdk` cap drift; keeper stability gains stale watchdog fiber restart and stream-idle gap-detection.

### Added (feat)
- Design-system semantic alias migration (35 PRs, batches PR-M14 through PR-M26 + S3e–S3h). SPEC §3 alias introduced to both products at Stage 1 (#10611), then sweeps over `layout.css` (#10586), `sidebar.css` (#10587), `drawer.css` (#10588), `swimlanes.css` (#10589), `primitives.css` (#10590), `deck.css` (#10591), `code.css` (#10595), `cockpit.css` (#10597), `preview/*.html` (#10600), `preview/*.jsx` (#10601), `ui_kits/cockpit/*.jsx` (#10602), `_preview.css` (#10621). Bonsai shadow-ring rename + SPEC §6.2 escape hatch (#10620). Bonsai paper colors + scrollbar absorbed (#10556).
- Topbar variant API unified (Phase 3 consistency, #10505); SectionHeading primitive extracted (#10476).

### Changed (refactor)
- SSOT consolidation: cohort_key moved to source-of-truth module (#10618); 12 deprecated re-exports dropped from `Keeper_exec_context` (#10616); KeeperSandbox/DockerPlayground aliased to `Env_config_sandbox` (#10536); 5 Alerting/Pr_review timeout literals migrated to SSOT (#10502); 4 Sandbox/Turn_sandbox timeout literals migrated (#10486); 3 sandbox hardcoded constants migrated (#10551); personality I/O consolidated via samchon-style harness (#10538). Alerting default 15→20s (#10615).
- Yojson hygiene: drop unused decoder for `agent_identity.t` + `post_eval_result` (#10526); lint exempts encoder-only deriving from option-default rule (#10537).
- Bumped `agent_sdk` floor to 0.177.0 (#10608) after raising cap to <0.178.0 to align with pinned SHA v0.177.0 (#10592).

### Fixed
- Cascade unblock series: accept `weight=0` in toml materializer (#10571 / #10610) after the codex_cli weight=0 sweep (#10554) was reverted (#10613). Pin agent_sdk upper bound to <0.177.0 (#10497 / #10529), then raised to <0.178.0 (#10592). `check-oas-pin` regex accepts capped-floor pattern (#10596). Keeper supervisor handles `Stale_turn_timeout` in cohort_key (#10572 / #10574).
- Keeper stability: stale watchdog triggers fiber restart instead of cosmetic broadcast (#10540); `stream_idle_timeout` set to gap-detection value 120s (#10604); `Stdlib.Lazy` replaced with Atomic+Mutex memo in keeper memory bank (#10399 / #10407); personality re-sync loop stopped via symmetric compare (#10479); turn_timeout_sec_live aligned with SSOT (#10456 / #10469); pause directive persist + duplicate cohort key drop (#10593).
- Sandbox: accept legacy 3-field `docker inspect` without `ttl_sec` (#10488 / #10513 / #10514); preserve trailing tab; scrub `roots=` leak from path-rejection errors (#10349 / #10383); `gh-validation` inlines allowed command list in blocked error (#10561 / #10566).
- Auth: write short-form alias for every keeper at bootstrap (#10440 / #10525). Auth bridge SSOT routing (#10400 follow-through).
- Observability: inline rejection context in `cascade-no-callable-models` ERROR (#10528 / #10541); align `system_log` filename to UTC (#10392 / #10401); duplicate `InferenceTelemetry` emit dropped (#10489 / #10490 / #10511).
- TLA+: `OperatorPauseBroadcast` spec wired into `tla-check.sh` (#10516 / #10521).
- Dashboard: cb-group-a.jsx de-duplication after squash union (#10437 + #10451 → #10467).

### Performance
- String hot paths: `String.sub` equality replaced with `String.starts_with` across 8 hot paths (#10532), sweep 2 across 7 files (#10543), gh-validation 5 hunks (#10548); WS SSE data payload single `String.sub` (#10560); `String_util.equals_ci` SSOT applied to HTTP header lookup (#10612).
- List hot paths: `List.length` emptiness check replaced with `[] =` (13 hunks, O(N)→O(1), #10568); `List_util.count_if` SSOT introduced + sweep 16 sites across 14 files (#10609); single-pass `count_if` for 7 `List.length(List.filter)` sites in model_inference_metrics (#10607); file-private `take` helper for top-N truncation (#10619).
- Lookup: `try Hashtbl.find/Unix.getenv` replaced with `_opt` variants in 2 hot paths (#10575).
- Server auth: 2 allocations dropped from Bearer header check (#10483).
- MCP accept-header: redundant lowercase removed from callbacks (#10539, parked).

### Documentation
- See PR notes; 2 commits.

## [0.16.0] - 2026-04-26

Aggregate of 206 commits since v0.15.0 (95 fix / 38 perf / 21 feat / 13 chore / 10 refactor / 9 diag / 5 test / 3 obs / 2 docs). No breaking API changes. Headline: stability-heavy release — 95-fix sweep across keeper/sandbox/cascade/auth + 38 hot-path performance reductions + Trust system Phase 0a–1.

### Added (feat)
- Cascade trust system: fingerprint counter for trust observability (Phase 0a, #10292), JSONL snapshot of trust state every minute (Phase 0b, #10331), `trust_score` auto-rotation on persistent failures (Phase 1, #10365).
- Keeper identity: `normalize_all_names` SSOT (P1, #10417); silent identity-fallback paths surfaced (PR-I scope 1, #10351).
- Governance: destructive vs evasion-only payload severity split (#10355); routine matcher preflight + `keeper_shell git_clone` allowlist (PR-E, #10396).
- Transport: identity headers preserved on Codex CLI runtime MCP (#10359).
- Keeper runtime: sandbox cleanup error messages emitted in janitor loop (#10433); `keeper_composite` exposes `fiber_stop` / `fiber_wakeup` / `noop_count` / `idle_seconds` (#10312).
- Dashboard: low-trust operator recommendations (Phase 2a, #10416); a11y baseline for Code IDE v2 (#10394) and dashboard Phase 1 cb-group-a (#10451); semantic color tokens + theme infra (#10427).
- Config: `Env_config_exec_timeout` SSOT scaffold for #10426 P1 (#10452).

### Changed (refactor / chore)
- 10 refactor + 13 chore commits — see PR refs.

### Fixed
- Build / cascade unblock: main build unblocked after Phase-1 trust revert orphans (#10441 / #10445); `discover_keepers_toml` per-cycle WARN spam dedup (#10259 / #10380); `cascade_name` with `keeper_assignable=false` rejected (#10388 / #10406); degraded TOML-section fallback for keeper-name validator (#10259 / #10274); attribute and cool down Kimi resumable failures (#10285 / #10300); scheduler-safe RNG mutex (#10413).
- Keeper / sandbox: keepers taught to chdir before git in sandbox (#10424 / #10435); fall back to gh CLI keychain for sandbox `GH_TOKEN` (#10378); price cache usage in turn cost (#10379); register sandbox cleanup in server background loop (#10366); raise `git status` timeout default (#10360); consensus regex cache guard (#10377).
- Auth / dispatcher: ctx identity enforced on board author/voter (#10297 / #10305); keeper bearer tokens split at bootstrap (#10304 / #10313).
- Telemetry: tolerate nullable `Tool_assigned` preset (#10450); recover tool and task lifecycle diagnostics (#10358 / #10369); time-based flush makes sub-cap heuristic-metrics emit visible (#10348 / #10363); per-failure learning tags emitted instead of boilerplate (#10325 / #10330).
- Goal / FSM: `Awaiting_verification` exit transitions added (#10411 / #10420); periodic sweep fiber added in goal-janitor bootstrap loops (#10405 / #10439); lifecycle states blocked on goal upsert (#10247 / #10261).
- Transport: tunnel host detection in `legacy_messages_endpoint_url` corrected (#10454).
- Anti-rationalization: Korean rationalization patterns added (#10385 / #10391).
- Discovery history: all loaded models per probe preserved (#10404 / #10414).
- File I/O: `dated_jsonl` file-scope mutex registry shares lock across instances (#10372 / #10376); double-dropping tail prefix avoided (#10328).
- Bonsai: keeper SSOT bug eliminated by removing 3-source merge (#10343).
- OAS bridge: route Governance/Operator judges through OAS bridge SSOT (#9629 / #10400).

### Performance
- String hot paths: per-request `String.sub` allocations dropped on h2-gateway route prefix match (#10455), keeper-api-route per-suffix (#10444), ws-transport SSE/route (#10434), transport-read-model `trim_trailing_slashes` single-pass (#10438); 13 forked `starts_with`/`has_prefix`/`has_suffix` helpers routed through `Stdlib` (#10393); 7 forked `contains_substring` helpers routed through `String_util` SSOT (#10386); gh-cmd-validation routed through SSOT (#10384); `Json_util` SSOT applied to `json-string-field` 2 forks (#10410) + 2 more delegates (#10422); `Dashboard_http_helpers` `normalize_text` SSOT (#10402).
- PCRE caching: `Re.compile` hoisted in 4 hot paths + `String_util.find_substring` added (#10371); 2 more per-call `Re.compile` hoisted in drift-guard / board-votes (#10375); output-parse / memory-bank / consensus paths (#10367); tool-board / notify / inline-dispatch (#10361); link-preview compiled PCREs cached in `first_match` (#10381).

### Diagnostics
- Per-field personality drift exposed on re-sync (#10269 / #10370); structured `Timeout` / `Parse_degraded` from agent-stress failure path (#10341 / #10346); structured signals replace boilerplate institution-episode failure learnings (#10325 / #10339); `agent_stress` emits `Turn_failure` from `keeper_unified_turn` (#10341 / #10362); 9 diag commits total.

## [0.15.0] - 2026-04-25

Aggregate of 185 commits since v0.14.0 (26 feat / 93 fix / 30 perf-refactor-obs-docs / 10 chore / 26 misc). No breaking API changes.

### Added (feat)
- Keeper observability counters: per-keeper turn-latency buckets (#10124), livelock observer (#10123), context_max drift (#10122), require_tool_use violations (#10099), proactive skip-reason (#10060), compaction outcome (#10011), usage-trust Prometheus (#10021), Hebbian per-outcome edge (#10048), metric-emit drops (#10053).
- Keeper runtime: affordance-tool intersection at `Require_tool_use` gate (#10141), Ollama `keep_alive`/`num_ctx` forwarding from cascade.toml (#9985), wire `Gh_exit_class` into docker sandbox (#9974), persona authoring wizard (#9940).
- Coord/FSM: per-agent FSM drift counter (#10152), Prometheus task FSM drift (#10082).
- Dashboard: gRPC `events_dropped` strip (#10114), WS delivery counters (#10106, #10107), WS-only cutover flag (#10102), websocket route slice expansion (#9963), a11y high-contrast + forced-colors support (#10080).
- OAS/cascade: per-kind `masc_oas_error` counter (#10039), resolved_model_id metric label (#9962), context_overflow_imminent action signal (#9954).
- Keeper CLI: auto-construct Claude Code / Kimi CLI MCP config behind flag (#10059).

### Fixed
- Keeper: backlog gating on claimable tasks (#10159), supervisor sweep startup (#10161), max_restart loud alert (#10147), Ollama saturation skip (#10150), runtime MCP trajectory record (#10154), failed-turn episode persist (#10144), Hebbian first consolidation on fork (#10137), per-model telemetry empty-response defense (#10090), `keeper_msg` merged-CAS retry (#10135), Anthropic cache silent-disable flag (#10128), smart-heartbeat starvation (#10078), per_turn multiplier removed in favor of wall-clock cap (#10074), unified turn write_meta CAS retry (#10145).
- OAS: API fingerprint metadata drift detection (#10156), oas-bridge timeout SSOT (#10108), oas-bridge typed contract (#10153), `codex_cli` MCP omission WARN dedup (#10100), suppress repeated omission warnings (#10109).
- Cascade: declarative `fallback_cascade` for single-provider profiles (life-support escalation) (#10157).
- Telemetry: dedupe websocket delivery schema (#10151), legacy degenerate row scrub at init (#10095), heuristic-theatre Prometheus migration follow-up (#10044).
- Governance: auto-approve `masc_transition` + `keeper_board_post` for autonomous flow (#10148), default judge timeout raised to 180s (#10132), anti-rationalization gate-2 demoted to LLM advisory (#10116).
- Filesystem: `save_file_atomic` orphan boot sweep (#10131), test-executable HOME guard (#10085).
- Board/coord: keeper actor identity unified (#10133), original vote timestamp persisted across flush (#10093), fixture-vote quarantine (#10079).
- A11y: ARIA on vis-timeline/vis-network/filter chips (#10138), keeper-phase ARIA (#10142), GraphQL Playground viewport zoom (#10134).
- Auth/usage: bearer-token cross-agent mismatch counter (#10129), Anthropic cache provider-kind evidence requirement (#10163).
- Tool registry: shard tool registration completeness (#10105).
- Dashboard SSOT: keeper display source unified (#10084).
- PR automation: draft guard skip for owner-authored PRs (#10143).
- CDAL gate: dormancy diagnostics + ledger health surface (#10118).
- WS perf: dashboard delta gating on client `bufferedAmount` (#10104).

### Performance
- Slice-aware fanout: Phase 1 slice index bookkeeping (#10155), Phase 2 fanout gate (#10160). Keeper supervisor sweep liveness counter + age gauge (#10126), dashboard delta gating on client `bufferedAmount` (#10104).

### Refactor
- Keeper meta types facade refactor (`refactor-keeper-meta-types-facade`).
- Dedup of redundant code paths in oas-bridge, keeper-runtime, and telemetry-flow.

### Chore
- OAS-pin refresh to `main@bbe5e6b0` (`v0.174.0`) for OAS usage accounting (#1186); dependency floor remains `agent_sdk >= 0.174.0`.
- OAS-pin bump to agent_sdk v0.173.0 (#10149) with version-floor synchronisation.
- RFC documentation: WS slice-indexed fanout design (#10119).

## [0.14.0] - 2026-04-24

### Added
- `Env_git_noninteractive` module (`lib/env_git_noninteractive.{ml,mli}`) centralises `GIT_ASKPASS=''` and `GIT_TERMINAL_PROMPT=0` for keeper docker subprocesses. Previously these constants were absent everywhere in the codebase (verified zero hits on commit `0e408ffc`), so a keeper `git push` inside the sandbox could, in principle, block indefinitely on a credential prompt if the RO-mounted `hosts.yml` auth path failed before git fell through.

### Changed
- `keeper_shell_docker.run_docker_shell_command_with_status` now appends `Env_git_noninteractive.docker_env_args` to the docker `-e` env list at the single credential-composition callsite (`lib/keeper/keeper_shell_docker.ml:234-245`). No change to identity/auth semantics; the container now fails fast on a git credential prompt rather than hanging.

### RFC
- RFC-0007 rev.3 and RFC-0008 landed as design documents (`docs/rfc/`). This release implements RFC-0007 PR-1 only; PR-2 (`gh_result.t` structured result), PR-3 (typed `Api_get` / `Api_graphql_query`), and RFC-0008 `CredentialProvider` trait are tracked for follow-up releases.

## [0.13.0] - 2026-04-24

### Added
- Keeper `always_approve` flag bypasses rule-based approval gates for non-destructive, non-critical tools. Destructive operations (shell, git, critical risk) remain blocked regardless of the flag.
- `goal_id` is now a required parameter in `masc_add_task` and `masc_batch_add_tasks`. Tasks without a goal_id can no longer be created, closing the goal-task orphanage gap.

### Changed
- Approval gate audit events now log `auto_approved_always` disposition when `always_approve` is enabled, with full keeper/task/goal context.

## [0.12.3] - 2026-04-21

### Added
- `config/cascade.toml` is now the supported human-authored cascade catalog
  source. When present, the runtime materializes sibling `config/cascade.json`
  on load and continues serving the existing JSON-backed cascade path without a
  consumer-facing schema change.

### Changed
- Keeper Phase C blocker classification now uses structured
  `masc_internal_error` variants for admission queue timeout, turn timeout,
  and ambiguous post-commit cases instead of relying on formatted-string
  matching across the worker and supervisor surfaces.
- `Otel_spans` now ships an explicit `.mli` interface that hides mutable
  internal refs and publishes the supported tracing API surface
  (`init`, exporter setup, `shutdown`, span helpers, and trace state accessors).
- TOML-backed cascade catalogs now fail closed: invalid `cascade.toml` blocks
  cascade resolution instead of silently falling back to stale generated JSON.
- Dashboard cascade surfaces now make the authoring/runtime split explicit.
  The cascade panel shows the active authoring source, raw `cascade.json`
  editing becomes read-only when TOML-backed, and keeper config surfaces now
  show both the selected `cascade_name` and the paths that control selection
  versus generated runtime catalog state.
- Regression coverage now locks the TOML materialization contract, resolver
  behavior for TOML-only config roots, dashboard raw-config read-only behavior,
  and keeper-config source/cascade provenance.

### Deprecated
- None.
## [0.12.2] - 2026-04-21

### Changed
- Keeper `gh` execution no longer falls back to a hardcoded repository or
  stderr text matching when the working directory is not itself a Git
  checkout. It now resolves repo context structurally from the current task's
  worktree git root and fails with a typed error when that context is missing.
- `require_tool_use` completion enforcement now latches across the full keeper
  run and only treats actual keeper-surface tool calls as satisfying the
  contract. A final optional turn can no longer mask an earlier tool-required
  turn that never used tools.
- Keeper sandbox option validation and docs now expose `docker_with_git`
  consistently, and the new regression tests cover task-derived GitHub repo
  context plus run-level tool contract enforcement.

## [0.12.1] - 2026-04-21

### Changed
- TBD

### Deprecated
- TBD

## Unreleased

### Changed

- **Strict required-tool contracts now use typed tool effects.** MASC passes
  an input-aware required-tool satisfaction predicate into OAS, so passive
  observation tools such as `masc_status` and `keeper_tasks_list` no longer
  satisfy required productive action. The OAS dependency floor is raised to
  `agent_sdk >= 0.171.0` for the new contract hook.
- **OAS pin bump → `main@031c7e6b` (`v0.170.5`).**
  `scripts/oas-agent-sdk-pin.sh` now tracks the merged OAS truth-layer evidence
  primitives, and the dependency floor in `dune-project` / `masc_mcp.opam` is
  raised to `agent_sdk >= 0.170.5`. Keeper metrics now separate
  `raw_evidence_ref_count` from `violation_count`, so OAS
  `evidence/effects.json` rows are treated as advisory effect-decision evidence
  instead of mode violations.
- **Keeper TOML key drift assertion restored.** The TOML unknown-key allowlist no
  longer whitelists `tool_access.kind` / `tool_access.preset` unless the TOML
  profile parser actually consumes those nested keys, unblocking keeper test
  executable startup after the canonical/parsed key lists diverged.
- **OAS pin bump → `main@8b5bf30a` (`v0.170.4`).**
  `scripts/oas-agent-sdk-pin.sh` now tracks the merged OAS Kimi CLI session
  reuse fix on upstream `main`, and the dependency floor in `dune-project` /
  `masc_mcp.opam` is raised to `agent_sdk >= 0.170.4`. Generated keeper OAS
  pin docs are re-synced from the shared pin script so the declared base
  version, runtime SHA, and floor stay aligned.
- **OAS pin refresh → `main@09a19698` (`v0.170.3`).**
  `scripts/oas-agent-sdk-pin.sh` no longer tracks the deleted
  `fix/pipeline-message-constructor` branch. It now pins upstream OAS `main`
  at the current reachable head while keeping the dependency floor at
  `agent_sdk >= 0.170.3`, because upstream `main` still advertises version
  `0.170.3`. The generated keeper OAS pin docs are re-synced from the shared
  pin script so the declared track ref, SHA, and floor stay aligned.
- **Keeper sandbox profile collapsed to `Local | Docker` 2-mode.** The three
  external variants (`Legacy_local`, `Docker_hardened`, `Docker_with_git`) are
  replaced by two: `local` runs on the host with filesystem scoped to the
  keeper playground; `docker` runs in the hardened container. Git credential
  mounting is no longer a separate profile — when `sandbox_profile=docker` and
  `keeper_bash` cmd starts with `git`/`gh`, the dispatcher transparently
  upgrades to network=inherit with gh/git credential mounts for that one
  command. Response JSON carries `git_creds_enabled` so observers can tell
  which path fired. Old profile strings still load via a compat layer that
  warns and maps (`legacy_local→local`, `docker_hardened|docker_with_git→docker`);
  the compat arm is removable once state JSON/TOML files are migrated. See
  RFC-0006 §8 Addendum.
- **OAS pin bump → `main@3dabe7a8` (`v0.164.0`).** `scripts/oas-agent-sdk-pin.sh` now follows `jeong-sik/oas` `main` instead of the older `codex/glm-coding-plan-cascade` branch, and the dependency floor in `dune-project` / `masc_mcp.opam` is raised to `agent_sdk >= 0.164.0`. This matches the upstream version-boundary fix where current OAS `main` advertises `0.164.0` after post-`0.163.0` public API growth, so downstream pin metadata no longer conflates branch head with the older `0.163.0` line.

### Added

- **CLI auto-model rotation for cascade specs.** `gemini_cli:auto` now
  expands into a quota-aware concrete Gemini CLI candidate list
  (Flash/Lite first, Pro last), and `codex_cli:auto` expands through a
  light-to-heavy supported Codex order from `gpt-5.2` up to `gpt-5.4`,
  including `gpt-5.4-mini` and `gpt-5.3-codex-spark`. The ChatGPT-backed
  Codex rotation now excludes `gpt-5.1-codex-mini`, `gpt-5.1-codex-max`, and
  `gpt-5.2-codex` after direct runtime probes returned 400
  unsupported-model errors; operators can still re-add them explicitly
  through `MASC_CODEX_CLI_AUTO_MODELS`.
  `claude_code:auto` remains single-entry by default but can be expanded via
  `MASC_CLAUDE_CODE_AUTO_MODELS`. This lets existing cascade
  failover/round-robin/cooldown machinery rotate CLI models without
  relying on interactive `/model` state.

- **Legendary Bash shadow-counter per-reason `too_complex_*`
  histogram.**  `Legendary_counters.snapshot` now includes fifteen
  new fields — one per `Parsed.reason_too_complex` variant plus
  dedicated `too_complex_parse_error`, `too_complex_parse_aborted`,
  and `too_complex_other` buckets.  The shadow-observer in
  `keeper_exec_shell.ml` feeds the `parse_tag` string (e.g.
  `"too_complex:redirect"`) through the new
  `Legendary_counters.incr_too_complex_by_tag` routing table
  whenever `diff=Shadow_cannot_parse`; unknown tags collapse into
  `too_complex_other` so the histogram sum always equals
  `gate_diff_shadow_cannot_parse`.  Same zero-cost posture as the
  other counters — nothing increments until
  `MASC_BASH_AST_SHADOW_LOG` is on.  Exposed through the existing
  `/api/v1/legendary_bash/shadow_counters` endpoint (additive
  fields only, pre-existing consumers unaffected).  Six new unit
  tests (prefixed / bare / parse_error / parse_aborted / unknown /
  JSON shape).  `LEGENDARY-BASH-RUNBOOK.md` documents the new
  buckets and the A1-PR-N prioritisation recipe ("top-N buckets
  over observation window = next grammar expansion targets").

### Changed

- **TLA+ specs 이관 완결 (`tla/` → `specs/`).** 기존 top-level
  `tla/` 디렉토리에 남아 있던 3개 스펙을 `specs/` 서브디렉토리
  구조로 이동: `specs/task-lifecycle/TaskLifecycle.{tla,cfg,-buggy.cfg}`
  (#8960), `specs/checkpoint-trim/CheckpointTrim.{tla,cfg,-buggy.cfg}`
  (#9001), `specs/social-state-cap/SocialStateCap.{tla,cfg,-buggy.cfg}`
  (#9020). 이관 이유: (1) `specs/Makefile` 의 `find . -name '*.cfg'`
  auto-discovery 가 `specs/**` 하위만 탐색해 `tla/` 스펙은
  `make -C specs check-all` 에서 제외되었고, (2) `ci.yml` 의
  `tla-specs` job path filter (`^(specs/|lib/keeper/|lib/oas_.*\\.ml$
  |Makefile$)`) 도 `tla/` 변경을 무시해 TaskLifecycle 이 PR #8437
  merge 이후 로컬 only 로 남아 있었다. 이관 후 `scripts/tla-check.sh`
  의 legacy `tla/` 루프 제거 및 `.gitignore` 의 `tla/` 전용 패턴
  정리. `CheckpointTrim.cfg` / `-buggy.cfg` 에는 terminating spec
  (`pc: "trim" → "done"`) 의 default deadlock 오탐을 막기 위해
  `CHECK_DEADLOCK FALSE` 를 추가 — safety invariant 로만 검증.
  CI `TLA+ Model Checking` job 은 SocialStateCap 11,665 distinct
  states 포함 17 분 런타임에 pass.

### Added

- **Bash parser post-hoc `Too_complex` classifier (P5 parse-gap
  narrowing).**  `Masc_exec_bash_parser.Bash.parse_string` now
  post-processes lexer/grammar rejections through
  `classify_too_complex`, a substring scanner that upgrades the
  response from opaque `Parse_error` to a typed
  `Parsed.Too_complex reason` variant whenever the rejection is
  attributable to a subset-excluded bash feature.  Ordered
  multi-char markers first (`<<<`, `<<`, `>>`, `&&`, `||`, `$(`,
  `$((`, `<(`, `>(`), then single-char (`<`, `>`, `&`, `(`, `{`,
  etc.), first match wins.  New variant `Redirect` added to
  `Parsed.reason_too_complex` for `<`/`>`/`>>`; mapping added to
  `Worker_dev_tools.too_complex_reason_tag` → `"redirect"`.  Eleven
  new parser tests cover `Logic_op` (`&&`/`||`), `Redirect`,
  `Heredoc` (`<<`), `Here_string` (`<<<`), `Cmd_subst` (`` ` ``
  and `$(`), `Arith_expansion` (`$((`), `Background` (`&`),
  `Subshell` (`(…)`).  The existing
  `test_double_quote_with_backtick_rejected` now expects
  `Too_complex `Cmd_subst` — the substring scan is not
  quote-aware, and since anything reaching this arm has already
  been grammar-rejected the more specific tag is strictly better
  for the corpus-tap telemetry that drives future A1-PR-N grammar
  expansion priority decisions.

- **Legendary Bash `bg_tasks/<keeper>` HTTP endpoint.**  New
  `GET /api/v1/legendary_bash/bg_tasks/<keeper>` returns the
  per-keeper background task roster as
  `{"keeper": "<name>", "count": N, "tasks": ["<id>", …]}`.
  Wraps `Bg_task.list ~keeper` under the same public-read posture
  as `shadow_counters` (no auth on keeper identity, zero-cost when
  quiet).  Unknown / quiet keepers return `{"count": 0, "tasks":
  []}` — the endpoint mirrors the filesystem/PG lookup instead
  of gating on keeper existence, so a dashboard can poll liberally.
  Trailing-slash requests (`.../bg_tasks/`) return 400 with
  `"keeper name is required"`.  Three new route tests cover empty
  keeper, unusual-name echo (`my-keeper_01`), and stable
  `keeper → count → tasks` field ordering.
  `LEGENDARY-BASH-RUNBOOK.md` now documents the endpoint alongside
  the existing `shadow_counters` snapshot endpoint so dashboards
  and operator tooling have a single reference.

- **`Cdal_judge` jest / vitest classifier.**  `of_exec_outcome`
  now emits typed `Test_pass {count}` / `Test_fail {count}`
  markers for jest and vitest runner output in addition to dune,
  cargo, alcotest, pytest, and go test.  Detection anchors on the
  runner-specific summary banners — `Test Suites:` for jest,
  `Test Files ` for vitest — so bare prose or user-visible text
  mentioning "Tests" or "passed" cannot false-positive.  Count is
  extracted from the `Tests:` / `Tests` summary line by scanning
  for " passed" / " failed" and reading the int immediately
  before the tag.  This correctly handles vitest's pipe-delimited
  failure lines (`Tests  2 failed | 3 passed (5)` →
  `Test_fail {count=2}`).  Banner-required behaviour is covered
  by a dedicated negative test (`test_jest_vitest_banner_
  required`).  Verifier cascade now covers dune + cargo + pytest
  + go test + jest + vitest, bringing JavaScript-ecosystem
  runner output (Kidsnote FE repos, most npm projects) into the
  same typed-marker surface the rest of the cascade consumes.

## [0.12.0] - 2026-04-20

### Added

- **Bash parser single-quote string support (P5 parse-gap step).**
  `lib/exec/parser/bash_lexer.mll` now recognises `'...'` literal
  strings and emits them as a single `WORD` token with the surrounding
  quotes stripped.  Lets the AST gate classify commands like
  `git commit -m 'my message'` or `echo 'foo | bar'` without falling
  back to `Shadow_cannot_parse`, narrowing the
  `gate_diff_legacy_allow_shadow_deny` / `..._shadow_allow` signal
  on the `MASC_BASH_AST_SHADOW_LOG` observer (feeds the
  `MASC_BASH_AST_ONLY` flip decision per RUNBOOK §P5).  Five new
  parser tests cover: basic quoted arg, empty `''`, multiple quoted
  args in one command, pipe-metachar-as-literal-payload, and the
  unterminated-quote negative.  No grammar change; no behaviour
  change on commands without single quotes.

- **Bash parser double-quote string support (P5 parse-gap step).**
  `lib/exec/parser/bash_lexer.mll` now recognises `"..."` double-
  quoted literals alongside unquoted `WORD` tokens.  The double-
  quote body is matched by `dq_body = [^ '"' '\n' '\\' '$' '`']*`
  and emitted as a single `WORD` with the surrounding quotes
  stripped, so shapes like `rg "error pattern"` /
  `git commit -m "some message"` / `echo "hello world"` round-trip
  as one `Shell_ir.Lit` element — spaces preserved, pipe metachar
  inside the body left literal.  Bash features that `"..."` would
  otherwise interpret (backslash escapes `\"`/`\\`, variable
  expansion `$FOO`, command substitution `` ` ``/`$(…)`, embedded
  newlines) are subset-excluded at the A1 layer: their presence in
  the body breaks the lex and surfaces as `Parse_error`, which is
  fail-closed for the subset gate.  The grammar is unchanged
  (`WORD` production already accepts the token in any argument
  position).  Follow-up PRs will add an unescape sub-rule for `\"`
  / `\\` / `\n` / `\$` to widen coverage.  Eight new parser tests
  cover the happy paths (basic literal, empty string, pipe
  metachar as literal, `rg "error pattern" src/`) and the four
  fail-closed negatives (`$FOO`, `\"` escapes, backtick subst,
  unterminated `"`).  19/19 parser tests green locally.  Narrows
  the `Shadow_cannot_parse` bucket emitted by the AST gate shadow
  observer, bringing the `MASC_BASH_AST_ONLY` flip criterion one
  step closer.

- **`Cdal_judge` go test classifier.**  `of_exec_outcome` now emits
  typed `Test_pass {count}` / `Test_fail {count}` markers for `go
  test` output in addition to dune, cargo, alcotest, and pytest.
  Detection anchors on the runner-specific `--- PASS:` / `--- FAIL:`
  / `=== RUN` prefaces so that bare `PASS` / `FAIL` tokens elsewhere
  in stdout (e.g. docstrings or user-visible prose) cannot
  false-positive. Count is obtained by counting `--- PASS:` /
  `--- FAIL:` occurrences — one per completed subtest. Banner-
  required behavior is covered by a dedicated negative test
  (`test_go_test_banner_required`). Verifier cascade now covers
  dune + cargo + pytest + go test.

- **Legendary Bash shadow-counters HTTP endpoint.**  New
  `GET /api/v1/legendary_bash/shadow_counters` returns the
  `Legendary_counters.snapshot` as JSON.  Public-read (same auth
  posture as `/api/v1/activity/*`), zero-cost when observers are
  off (all counters stay at zero).  Wired behind
  `Server_routes_http_routes_artifacts` in the route pipeline.
  `LEGENDARY-BASH-RUNBOOK.md` now documents the endpoint and the
  suggested `disagree_ratio` formula so operators can drive the
  `MASC_BASH_AST_ONLY` flip decision from a dashboard instead of a
  log grep pipeline.

- **Legendary Bash in-process shadow counters.**  New
  `lib/legendary_counters.{ml,mli}` exposes `Atomic.t`-backed totals
  for the P5 gate-diff observer (`total` + 4 buckets mirroring
  `Worker_dev_tools.gate_diff` 1:1) and the P4 auto-background
  observer (`observed` + `would_have_promoted`).  The counters are
  incremented from the same sites that already emit
  `gate_diff_shadow` / `auto_bg_would_have_promoted` log lines, so
  the cost remains zero whenever the matching observer env flag is
  off.  `snapshot_to_json` returns a stable field layout intended
  for a later dashboard / HTTP endpoint.  5 unit tests
  (`test_legendary_counters`).  No behavior change on the request
  path.

- **`Cdal_judge` pytest classifier.**  `of_exec_outcome` now emits
  typed `Test_pass` / `Test_fail` markers for pytest output in
  addition to dune, cargo, and alcotest.  Detection is anchored on
  the canonical `===== N passed in Ts =====` / `===== N failed`
  summary banner so that bare "N passed" prose elsewhere in stdout
  cannot false-positive.  Banner-required behavior is covered by a
  dedicated negative test
  (`test_pytest_banner_required`).  Lifts the verifier cascade out
  of OCaml-only coverage so Python-test keepers get the same typed
  marker stream as dune keepers.

- **KEEPER-USER-MANUAL §3.1.2 Legendary Bash 도구 표면.**  New
  subsection documents the three-tool surface (`keeper_bash`,
  `keeper_bash_output`, `keeper_bash_kill`) at the level a keeper
  operator reads: call-schema contract, single-command / no-chaining
  rule, the three flag-gated optional response fields
  (`return_code_interpretation`, `verifiable_markers`, promoted
  triple), and the background polling / tree-kill lifecycle.  Points
  operators at the existing `LEGENDARY-BASH-RUNBOOK.md` /
  `ENV-CONTRACT.md §4` as SSOT for flag matrices.  Adds both files
  to the manual's 관련 문서 appendix so new keeper operators land on
  the procedure docs.  No code change.

- **Legendary Bash operator runbook.**  New
  `docs/LEGENDARY-BASH-RUNBOOK.md` consolidates the P1–P6 rollout
  surface: current flag state table, authoritative opt-out tokens,
  dark-launch observer grep recipes for `gate_diff_shadow` and
  `auto_bg_would_have_promoted`, flip criteria for the remaining
  `AUTO_BG` / `AST_ONLY` defaults, and a restart-free rollback
  checklist.  `ENV-CONTRACT.md §4` now cross-links to it.  No code
  change.

- **`MASC_BASH_AUTO_BG_OBSERVE` dark-launch observer.**  Companion
  to `AST_SHADOW_LOG` (#8902) covering the AUTO_BG rollout axis.
  When the flag is set every foreground-only `keeper_bash` run is
  timed, and if the elapsed duration would have tripped
  `MASC_BLOCKING_BUDGET_MS` (default 15 000 ms) the keeper emits
  `auto_bg_would_have_promoted keeper=… cmd_hash=… duration_ms=N
  budget_ms=M`.  Inert when `AUTO_BG` itself is already enabled.
  Evidence for the later `AUTO_BG` default-flip decision without
  any behavior change.

- **`MASC_BASH_AST_SHADOW_LOG` dark-launch observer.**  With the
  flag set to a truthy value every `keeper_bash` call runs
  `Worker_dev_tools.diff_command` side-by-side with the live regex
  gate and emits a structured log line
  (`gate_diff_shadow keeper=… cmd_hash=… diff=… legacy=… shadow=…`)
  for every non-`Agree` outcome.  Command strings are hashed to a
  12-hex MD5 prefix before logging so no raw shell fragments leak
  to the log stream.  Default off; behavior is unchanged when
  disabled.  This is the evidence-collection step before the
  `MASC_BASH_AST_ONLY` default flip, which still waits on an
  N=1000 zero-diff window per the plan.

### Changed

- **`MASC_BASH_VERIFIABLE_MARKERS` flipped to on by default.**
  Post-Legendary-Bash-P6 (#8721) rollout step paralleling the
  `SEMANTIC_EXIT` flip: every `keeper_bash` response now carries
  the `verifiable_markers` array (typed `Test_pass {count}`,
  `Build_ok`, `Lint_clean`, `Git_clean`, each with
  `Exact | Heuristic` confidence) when the heuristic matches.
  Empty-result callers are omitted, so consumers that don't parse
  the key remain byte-compatible.  Explicit opt-out: set the env
  to `0` / `false` / `no` / `off`.  The flag itself survives one
  more minor bump before removal.

- **`MASC_BASH_SEMANTIC_EXIT` flipped to on by default.** Post-
  Legendary-Bash-P1 (#8721) rollout step: every `keeper_bash`
  response now carries the typed `semantic_exit` variant and the
  `return_code_interpretation` hint without requiring an operator
  opt-in.  Fields are purely additive — no existing key is removed
  or renamed, so consumers that parse `status` directly are
  unaffected.  Explicit opt-out: set the env to `0` / `false` /
  `no` / `off`.  The flag itself survives one more minor bump to
  let downstream consumers confirm compatibility before removal.

### Added

- **`Docker_with_git` sandbox profile + git/gh per-command dispatch.** New `sandbox_profile = "docker_with_git"` keeps every `Docker_hardened` guard (cap-drop, no-new-privs, read-only rootfs, tmpfs, pids/memory limits, no nested runtimes) but adds `--network bridge` and read-only mounts for `~/.config/gh`, `~/.gitconfig`, optionally `~/.ssh` (opt-in via `MASC_KEEPER_SANDBOX_SSH_DIR`). Optional `GH_TOKEN` env forward via `MASC_KEEPER_SANDBOX_GH_TOKEN`. A `Docker_hardened` keeper still gets git/gh access for free: `keeper_bash` automatically routes commands whose first token is `git` or `gh` through the new profile (toggle `MASC_KEEPER_SANDBOX_GIT_DISPATCH=false` to disable). Closes the gap that left coding keepers with `repo clone 차단: allowed org mismatch` board posts and 16 days of zero `keeper_bash` git activity.

- **Legendary Bash P1–P6 (`feature/legendary-bash-p1`, PR #8721).**
  Reworks `keeper_bash` along six coordinated axes.  Every surface
  is additive and opt-in; the default JSON shape is unchanged.
  - **P1 — typed semantic exit.**  New `Exec_semantic` variant
    (`Ok / Fail / Timeout / Signaled / Git_not_a_repo / Oom_killed /
    Policy_denied / Tool_missing / Permission_denied`) with
    heuristic interpretation of exit codes 126/127/128 and dmesg
    OOM hints.  Gated by `MASC_BASH_SEMANTIC_EXIT`.
  - **P2 — background task lifecycle.**  `Bg_task.spawn/read/kill`
    plus `keeper_bash_output` / `keeper_bash_kill` mirror
    claude-code's `BashOutput` / `KillShell`.  pgid-owned children
    enable tree-kill; PID-file persistence
    (`<base>/.masc/keeper/<name>/bg/*.pid`) plus a startup
    `reap_orphans` hook recover stranded groups after restart.
  - **P3 — head+tail output cap.**  `Exec_buffer` keeps the first
    and last 500 KB of each stream in memory with an overlap-aware
    `bytes_dropped` counter.  Controlled by `MASC_BASH_OUTPUT_CAP`
    / `MASC_BASH_CAP_HEAD` / `MASC_BASH_CAP_TAIL`.
  - **P4 — auto-background race.**  `Exec_run.run_with_auto_bg`
    spawns a `Bg_task` and races its exit against
    `MASC_BLOCKING_BUDGET_MS` (default 15 000 ms) via
    `Eio.Fiber.first`.  Budget expiry returns `{promoted: true,
    background_task_id, partial_output, bytes_dropped, budget_ms,
    hint}`.  Gated by `MASC_BASH_AUTO_BG`; falls back to the
    blocking path when no Eio clock is available.
  - **P5 — AST-shadow safety layer.**  `Worker_dev_tools`
    classifies every `Eval_gate.destructive_patterns` entry into an
    8-arm `destructive_class` and runs the existing regex allowlist
    in parallel with the `Masc_exec_bash_parser` AST gate.  The
    legacy↔shadow diff harness (`test/test_gate_diff.ml`) pins the
    flip covenant: no `Eval_gate` pattern may slip into
    `Legacy_deny_shadow_allow`.
  - **P6 — verifiable markers.**  `Cdal_judge.of_exec_outcome`
    translates `(semantic, stdout, stderr)` into a typed marker
    list (`Test_pass {count}`, `Build_ok`, `Lint_clean`,
    `Git_clean`, …) with `Exact | Heuristic` confidence, so the
    verifier cascade can consume structured proofs instead of regex
    scraping.  Emitted when `MASC_BASH_VERIFIABLE_MARKERS` is set.

  All six phases land behind flags so operators can soak each axis
  independently before default flip.  See
  `docs/ENV-CONTRACT.md §4` for the flag matrix.

### Changed

- **OAS pin bump → `main@36490371` (v0.163.0).** Single-commit upstream bump for `pipeline: handle Nudge decision in before_turn` (oas#1065). Without this, `before_turn` hooks returning `Hooks.Nudge` were silently dropped by `pipeline.ml stage_input` (`_ -> ()` fall-through). Effect on masc-mcp: the work-discovery nudge wired in PR #8805 (1089-char Samchon schema text) now actually reaches the LLM. 3 SSOT axes bumped per `feedback_oas-pin-must-bump-version-floor`: `scripts/oas-agent-sdk-pin.sh`, `dune-project`, `masc_mcp.opam`. Generated docs re-synced via `scripts/sync-oas-pin-docs.sh`. Live verification: post-deploy, `keeper:<name> before_turn: injecting work_discovery nudge` log lines should be followed by `tool_call` events from the same keeper (currently 10 fires + 0 follow-up actions over the live server's 2 hour uptime).

- **OAS pin bump → `main@2798831c` (v0.162.0 + 7 follow-ups).** Carries
  upstream OAS commits since the last `54f4aeab` pin:
  - `2798831c` #1035 — `fix(hooks): emit OnError on tool-not-found
    dispatch failure (#1032)`. Surfaces a previously-silent dispatch
    failure mode through the existing `Hooks.OnError` channel; useful
    for keeper observability when LLMs hallucinate tool names.
  - `2a9a8756` #1061 — batch register 15 orphan test executables (OAS
    internal coverage; no surface change).
  - `e1578747` #1045 — refactor: split runtime control and memory
    backend helpers (internal split, public modules unchanged).
  - `4d7b8489` #1043 — refactor: split context reducer helpers
    (internal split, `Context` API unchanged).
  - `98a13ab5` #1041 — refactor(checkpoint): split codec and delta
    helpers (internal split, `Checkpoint` API unchanged).
  - `8a5abf2e` #1060 — register orphan `test_memory_advanced` (OAS
    internal coverage).
  - `d2b81773` #1059 — `build(dune): bump lang 3.11 → 3.22 to match
    toolchain` (OAS-side dune version, opaque to consumers).

  Dependency floor and declared base version remain `0.162.0`.

## [0.11.0] - 2026-04-20

### Added

- **Tool-failure root-cause sweep (#8688, RFC #8760).** Server-authored
  hints now have Good/Bad examples for the top rejection classes and
  the keeper persona prompt documents how to consume them. Observability
  script `scripts/sweep-tool-error-signatures.sh` (#8767) buckets daily
  `tool_calls/*.jsonl` failures by normalized signature so the impact
  of prompt changes is measurable. Shipped:
  - `keeper_exec_shell` — raise gh op timeout floor 5s → 15s (#8712),
    hint on gh `Could not resolve to a Repository` from playground cwd
    (#8734), Good:/Bad: examples for 5 readonly-shell categories
    (#8704).
  - `keeper.capabilities` — tool error grammar (envelope / hint field /
    same-turn retry / judgment escalation) replaces the weak
    "do not retry" one-liner (#8775 / RFC R1).
  - `worker_dev_tools` — Chain_or_redirect and Injection hints name
    the `cwd=` argument explicitly so `cd X && Y` stops being the
    default suggestion (#8783).
  - `keeper_alerting_path` — `path_not_in_allowed_paths` suggests the
    concrete playground prefix when the raw path starts with `repos/`
    or `mind/` (#8789).
  - `tool_task` — completion-rejection message embeds a concrete
    accepted-notes example (#8708).
  - `anti_rationalization` — empty evaluator response routes to
    liveness approval instead of hard rejection (#8722).
- **Runtime event listener (pilot).** `feat(runtime_events)` (#8792)
  installs an OCaml `Runtime_events` listener and reserves event handles
  for MASC turn / tool-call observability (Wave 2A pilot).
- **Streamable HTTP atomic race fix (pilot).** `session.last_seen`
  marked `[@atomic]` to remove an unlocked race in the streamable HTTP
  transport (#8790, Wave 2 pilot).
- **CDAL attribution on verification legs.** Approve/reject verification
  transitions now record attribution so the post-hoc CDAL timeline
  includes who verified (#8731).
- **Verifier role gating for `task_verify`.** Affordance is now gated
  to verifier-role keepers (#8715). Default keeper set excludes the
  verification approvers from ordinary work claim queues.
- **Multi-assignment current binding semantics.** Task assignments can
  now express the current active binding vs historical ones; surfaced
  in `masc_check` and downstream accountability paths (#8776).
- **Keeper msg observability.** Usage / cost / cache-token counters and
  the raw model id are surfaced on `keeper_msg` MCP responses so clients
  and dashboards can attribute cost per keeper turn (#8717).

### Changed

- **Doctor phase 1 — 시스템 전반 진단.** MASC 전체(서버 + 5 sidecar)를
  동일한 `Check/Severity/AutoFix` 모델로 진단하는 Doctor 축을 CLI · HTTP ·
  Dashboard 3계층으로 일괄 구축. `flutter doctor` / `brew doctor` 외형 참고.
  - **CLI** — `masc-mcp doctor [config|sidecar <name>|all] [--json]`
    (`bin/main_eio.ml` 의 `Cmd.group` 으로 backward-compat 유지, 무인자 호출
    은 기존 `config` 와 동일).
  - **Fan-out** — `doctor all` 은 config + `discord|slack|telegram|imessage|cli`
    sidecar 를 순차 실행하고 Korean aggregate summary (`정상/경고/오류`) +
    per-doctor breakdown 을 출력. `--json` 은 envelope 형태
    (`{title, doctors[{name, kind, exit_code, payload}], summary, exit_code}`)
    로 CI · 대시보드 contract 제공. `Doctor_dispatch.aggregate_exit_code` 는
    `error > warn > ok` 우선순위와 unknown rc → error 상향을 보장.
  - **HTTP endpoint** — `GET /api/v1/dashboard/doctor` (phase 1: self-subprocess
    forward, `with_public_read` 권한). 실패 시 5xx + `{error, hint}` 로 운영자
    원인 안내.
  - **Dashboard UI** — Lab 탭 → inspector → **Doctor** sub-tab. `<DoctorPanel />`
    이 envelope 을 poll 해 summary header + 3-column grid 로 렌더. 카드 클릭
    시 drill-down 으로 sidecar `checks[]` 또는 config `warnings[]` 표시, 자동
    치유 가능한 check 에는 accent 배지 (실제 `--fix` 실행은 CLI 유지).
  - **Observability** — `doctor --fix` 가 `FixOutcome` 리스트를 캡처해
    "자가 치유 실행:" 블록으로 실패 격리(try/except)와 결과 렌더. 세 상태
    (fix 성공·환경 미해결 / fix 예외 / fix 미정의) 를 구분 가능.
  - **출력 polish** — sidecar `render_pretty` 제목을 markdown `#` 대신
    underline 스타일로 전환해 `doctor all` divider 와 시각적 일관성 확보.

  관련 PR (모두 2026-04-19 merge):
  - Framework (이전 배포): #8375 / #8406 / #8410 / #8432 / #8442 / #8452 / #8457 / #8468
  - Observability: #8478 (FixOutcome)
  - CLI dispatch/fan-out: #8481 #8502 #8518
  - Backend endpoint: #8525
  - Dashboard UI: #8533 #8534 #8535 #8540 #8541
  - Polish / docs: #8539 #8536

  Docs: `docs/DOCTOR-ARCHITECTURE.md`, `docs/CONFIG-DOCTOR.md`.

  후속 (phase 2 / 축 9): server endpoint in-process 전환(Eio.Process ~cwd),
  `--fix` 버튼 HITL approval, 실제 callback 확장.

- **CDAL verdict attribution on verification approve/reject legs (#8731).**
  `tool_task.ml` 의 `Approve_verification` / `Reject_verification` 핸들러에
  `Cdal_verdict_gate.gate_check` 호출을 추가. FSM-enabled 경로는
  `Done_action` 를 우회하기 때문에 기존 CDAL gate 가 verification 승인
  시점에 동작하지 않아 `/api/v1/attribution/summary` 에 `cdal_verdict`
  gate 가 0 entries 로 남았다. 이제 `Env_config_runtime.Cdal.gate_enabled()`
  (default true) 가 켜진 환경에서 approve/reject 양쪽이 verdict lookup +
  `Dashboard_attribution` ring 기록을 남긴다.

- **Verifier-role affordance gating (#8715).**
  `keeper_unified_turn.ml` 의 `observed_triggers_of_observation` /
  `observed_affordances_of_observation` 에 `?meta` optional param 을 추가하고
  `pending_verification` trigger 및 `task_verify` affordance 를
  `is_verifier_role_keeper` 가 참인 keeper 에만 노출한다. 그 외 persona 는
  world observation 에서 verification 관련 신호를 보지 않으므로 fleet 노이즈
  감소. `?meta=None` 호출은 legacy surface-to-all 유지 (diagnostics / snapshot
  caller 호환).

### Changed

- **OAS pin bump → `main@54f4aeab` (v0.162.0 + Gemini policy fix).**
  Carries upstream OAS `#1048 fix(gemini_cli): use sentinel name to
  disable MCP, avoiding empty-string policy crash`. Gemini CLI 0.38
  introduced a Policy Engine that rejects empty `--allowed-mcp-server-names`
  entries, which crashed every keeper turn that set
  `OAS_GEMINI_NO_MCP=1` (i.e. all 4 built-in keepers — scholar / analyst
  / executor / verifier — and any cascade vendoring Gemini). OAS now
  passes the sentinel name `__oas_no_mcp__`. Dependency floor and
  declared base version remain `0.162.0`.
- **OAS pin bump → `v0.162.0`.** Raises the `agent_sdk` dependency floor
  from `0.161.0` to `0.162.0` and pins OAS `main@3b0409d2`, pulling in
  the provider-registry context-window fix (#1040) plus the 0.162.0
  release rollup (#1042) without leaving `check-oas-pin` drift warnings.

### Reliability

- **FD leak SSOT (#8538 Tier 2).** PR #8543 이 3 hot-path call site 에 inline
  try/with 으로 pipe fd leak 을 막았지만, 같은 패턴을 여러 곳에서 재유도하면
  drift 가 발생한다. 공통 combinator `With_process.with_process_in` /
  `with_process_args_in` 을 `lib/process/with_process.ml` 에 추출하고
  `doctor_dispatch.ml`, `server_routes_http_routes_dashboard.ml`,
  `worktree_live_context.ml` 세 site 를 SSOT 에 귀속시켜 drift vector 제거.
  `test/test_with_process_coverage.ml` 이 error path 별 fd 회수와 100-iter
  stress 를 검증한다. `Fun.protect` 대신 수동 try/with 을 선택한 근거:
  finally 에서 던져진 예외가 `Fun.Finally_raised` 로 랩핑돼 `Eio.Cancel.Cancelled`
  의 구조적 취소 정보를 가릴 수 있음 (OCaml stdlib `Fun.protect` spec).
  후속: `Eio.Process.parse_out` 기반 Tier 3 이관 (follow-up Issue).

## [0.10.1] - 2026-04-19

### Changed

- **OAS pin bump → `v0.160.1`.** `agent_sdk` floor raised from `0.160.0`
  to `0.160.1` (dune-project + masc_mcp.opam + pin script SHA
  `f70fd95e79bbe5f53ddd6687d3438e39f7b2c59f`). Picks up OAS #1001's
  `completion_contract` fix: `validate_response` now accepts no-ToolUse
  responses when `stop_reason` is `MaxTokens` or `Unknown "pause_turn"`
  (resumable), unblocking Haiku 4.5 vendor_mix_balanced cascades that
  exhaust the 8192-token output budget during extended thinking before a
  ToolUse block emits. `EndTurn` / `StopToolUse` / `StopSequence` /
  other `Unknown` reasons continue to reject no-ToolUse responses.

### Context

Observed empirically via `~/me/.masc/logs/system_log_2026-04-18.jsonl`:
104 `Completion contract [require_tool_use] violated` entries in a single
day, with +12 new violations accumulating in the 25 minutes between
observation and fix — silent cost of the pre-fix contract shape.

## [0.10.0] - 2026-04-18

### Changed

- **Verification surface — advisory CDAL attribution + verifier keeper
  signal + Kanban visibility + TLA+ bug-model.** Responds to the
  "검증 흔적이 UI에서 안 보인다" feedback by making every hop of the
  verification pipeline observable.
  - CDAL gate records an attribution entry for advisory (strict=false)
    contracts instead of silently skipping the lookup (#8402).
  - `Keeper_unified_turn.is_verifier_role_keeper` predicate plus
    `observation.verifier_role_keeper` field on every decision record
    let the dashboard pick verification-authority keepers out of the
    fleet (#8422).
  - Kanban adds a "검증 대기" column (store bucket +
    `TaskBacklog` wiring + card pill) so `awaiting_verification`
    tasks stop disappearing into the Done column (#8424).
  - `tla/TaskLifecycle.tla` bug-model: `DoneRequiresApproval`
    invariant is verified on the clean cfg (5 states, exit 0) and
    violated on the buggy cfg (exit 12), confirming the contract
    that Done is reachable only after Approve_verification (#8437,
    draft).

- **Dashboard design-system migration.** Multi-wave sweep of raw Tailwind
  color utilities to semantic CSS var tokens (`var(--ok)`, `var(--warn)`,
  `var(--bad-light)`, `var(--accent)`) across ~50 files.
  - Severity hues (emerald/rose/amber/red) collapsed to `--ok`/`--bad-light`/`--warn`
    (#8271, #8273, #8278, #8279, #8283, #8286).
  - Working hues (sky/blue/violet/...) folded into `--accent` (#8284).
  - Orange/lime sweep (#8285). Neutral-gray (zinc/gray/neutral/stone)
    collapsed to `--text-muted`/`--white-*` (#8281).
  - Final high-shade/extreme variants cleanup (#8288).
  - Paper-theme bridges `--accent`/`--ok`/`--warn`/`--bad` (#8290).
  - Text size hygiene sweep `text-[9px]` → `text-[10px]` (97 instances /
    29 files, #8260).
  - Radius tokens absorb `rounded-[3px]`/`rounded-[18px]` drift (#8291).
  - Sharp corners sweep `rounded-{xl,2xl,3xl}` → `rounded` (#8292).
  - Flat shadows (`shadow-{md,lg,xl,2xl}` → `shadow-sm`) (#8299).

- **Keeper — critical-path + lifecycle fixes.**
  - Surface unified turn critical path failures (#8265).
  - Consume overflow event-bus signal (#8251).
  - Honour declared `max_checkpoint_messages` default on create (#8256).
  - Synchronous `is_registered` check after `start_keepalive` (#8247).
  - Tool-policy validator recognises admin-dispatched keeper tools (#8241).
  - `coord_gc` quarantines broken agent files instead of deleting (#8253).
  - `keeper_tool_affinity.configured_max_k`/`lookback_days` treat empty
    or whitespace-only env values as unset; optional `?getenv` injection
    seam for tests (#8190).

- **Cascade + verification.**
  - Hard-quota-aware immediate cooldown in cascade (#8249).
  - `/api/v1/cascade/health` exposes `hard_quota_cooldown_sec` (#8277).
  - Verification-protocol warns on missing-contract submit (#8276).
  - Verification-panel exposes `task_title` + pending-0 hint (#8259).
  - Dashboard surfaces live `pending_ruling` count instead of hardcoded 0 (#8268).

- **Dashboard runtime + auth.**
  - Auto-provision shared loopback dev token for `/mcp` (#8258).
  - Runtime-panel uses `CollapsibleSection` instead of raw `<details>` (#8275).
  - Ring buffer replaces `spread+slice` for hot-path signals (#8269).
  - Buffer sizes Vite-env overridable (#8270).

- **Sidecar + bridges.**
  - Sidecar honours configured runtime paths (#8267).
  - `oas_sse_bridge` surfaces `keeper_name` on envelope `agent_name` (#8261).

- **OAS pin bump → `v0.160.1`.** `agent_sdk` floor raised from `0.159.0`
  to `0.160.1` (dune-project + masc_mcp.opam + pin script SHA
  `43527e8095f2f0c35aa84853d941025a0031aea0`). Keeps the event-bus
  backpressure-policy API (`Block` / `Drop_oldest` / `Drop_newest`),
  per-subscription + per-bus stats, and `subscribe ?purpose` labels from
  OAS #998, and now tracks OAS PR #1004 where the deprecated
  `agent_sdk_swarm` package was removed from the upstream tree.

- **Keeper `[keeper.oas_env]` TOML table.** Per-keeper OAS transport env
  vars are now declarative. `config/keepers/<name>.toml` accepts a new
  `[keeper.oas_env]` table whose entries are applied via `Unix.putenv`
  at turn start, right before any OAS call. Keys must match
  `^OAS_(CLAUDE|CODEX|GEMINI)_.+` — anything else is silently dropped
  to block ambient env injection (e.g. a `PATH=/evil/bin` entry in a
  TOML cannot reach the process). Bool / int TOML values coerce to
  strings (`true` → `"1"`, `false` → `"0"`) so the OAS transport
  build_args side reads them uniformly.
  - Default applied to all four built-in keepers (`analyst`, `executor`,
    `scholar`, `verifier`): `OAS_CLAUDE_STRICT_MCP=1` +
    `OAS_GEMINI_NO_MCP=1` — keeper subprocess calls no longer pull in
    ambient MCP servers from the operator's `~/.claude.json` /
    `~/.gemini/settings.json`, keeping behaviour deterministic across
    deployments.
  - `merge_keeper_profile_defaults` merges `oas_env` key-by-key: a
    persona-level base survives where the keeper TOML overlay doesn't
    override.
  - 5 new inline tests in `test_keeper_toml.ml` cover allowed / dropped
    / absent / bool-coerced / unknown-keys-whitelist paths.

- **Tool-task schema.**
  - `handoff_context.summary` declared required; runtime error surfaces
    example payload (#8293).
  - Ignore underscore-prefixed internal markers in transition schema (#8289).

### Deprecated
- None.

## [0.9.13] - 2026-04-17

### Changed

- **Dashboard — form control whitelists + new semantic components.**
  - `Select` prop whitelist expanded (id/name/aria/required/blur/testId) + tests 0 → 14 (#8007).
  - `TimeAgo` renders as semantic `<time>` with `aria-label` + `mode` prop + tests 0 → 19 (#8011).
- **Dashboard — highlight-on-match helper wired into 2 panels** (#8012).
- **Keeper — team memory scope enforcement** [codex] (#8016). Keeper team-memory writes now fail closed when the keeper does not own the scope.
- **CI — lib_option_get baseline naturalized 0 → 3** after the lockfree cache refactor in #7953 exposed 3 legitimate call sites (#8022).
- **Docs/design — CDAL PHASE1A rename.** `cdal_eval` references renamed to `cdal_eval_v1`; successor modules clarified (#8020).

### Deprecated
- **Spec sync — board + testing dead refs retired (#8008).**
  - `docs/spec/11-board.md` Maps-to row: dropped `lib/tool_vote.ml` and
    `lib/tool_social.ml` (both folded into `lib/tool_board.ml` per that
    file's own `Replaces tool_social.ml for new installations` header);
    corrected sub-library path `lib/board/` → `lib/board_types/`.
  - `docs/spec/15-testing.md`: §5.3 Anti-Fake and §5.6 Keeper Contract
    collapsed into RETIRED paragraphs (`lib/anti_fake.ml`,
    `lib/keeper/keeper_contract.ml` purged — 0 grep hits each).
  - §5.5 Keeper Verifier rewritten to describe the 3-way successor
    split: `lib/verifier_core.ml` + `lib/verifier_oas.ml` +
    `lib/keeper/keeper_guards.ml` (`lib/keeper/keeper_verifier.ml`
    removed in #2589). Maps-to row adjusted accordingly.
  - Net: 47 lines of stale catalogs removed, 17 lines of retirement
    records + successor pointers added.

## [0.9.12] - 2026-04-17

### Changed

Dashboard prop-whitelist expansion batch + structural cleanup. Autocoder-
driven increments on top of the 0.9.11 release.

- **Dashboard — form control prop whitelists.**
  - `Checkbox` prop whitelist expanded (id/name/aria/value/testId) + tests 0 → 13 (#8000).
  - `NumberInput` prop whitelist expanded (id/name/aria/autocomplete/keyboard/blur/testId) + tests 0 → 15 (#8005).

- **Dashboard — copy affordance.**
  - `CopyIdButton` placed next to truncated `trace_id` displays (#8001).

- **Dashboard — connector/keeper views.**
  - K×M `ConnectorKeeperMatrix` added under all-connectors view (#8002).

- **Dashboard — cleanup / clarity.**
  - Retired `runtime-params` / `param-audit` state cluster purged (#8003).
  - `'runtime'` label overload disambiguated; card titles made KO-only (#8004).

### Deprecated

- None.

## [0.9.11] - 2026-04-17

### Changed

Post-0.9.10 bulk merge cycle (admin override). Corrects the four entries
(#7981, #7982, #7985, #7986) that landed *after* the v0.9.10 tag commit
(`9820decae`) and were incorrectly attributed to 0.9.10 in #7994 — they
belong to this release.

- **Dashboard UX.**
  - Cascade Profiles + Keeper Mapping merged into one Cascade Routing card (#7986).
  - Visible toast cap at 5 + test coverage 0 → 9 (#7985).
  - Text filter on harness-health compaction/handoff lists (#7981).
  - Text filter on agent-detail owned-tasks + histories (#7982).
  - `CopyIdButton` wired into keeper-detail prompt fingerprint displays (#7989).
  - `ActionButton` prop whitelist expanded (aria-busy/id/title/testId) + tests 0 → 16 (#7995).
  - `TextInput` / `TextArea` now forward `id` — fixes orphan `<label for>` a11y regression (#7987).

- **Keeper / cascade / server.**
  - Raw `cascade_name` preserved on keeper side; canonicalization pushed to point-of-use (#7978).
  - `Accept_rejected` split from success in cascade evaluator; added `evict_idle` + `rejected_in_window` metrics (#7996).

- **Performance.**
  - Autoresearch pagination: in-memory mtime cache removes O(N) file I/O bottleneck (#7988).

- **Dead code / cleanup.**
  - Dead `mission-cards` barrel removed (no importers, `SummaryStat` unreferenced) (#7991).

- **Spec / docs / tooling.**
  - RFC-0004: OCaml ↔ TS shared contract (SSE + gRPC-web) (#7999).
  - Spec §7/§8/§10 type sections retired (checkpoint / context_budget / message_schema purged) (#7997).
  - Capsule Execution Plan Slices A–C marked historical (team_session retired) (#7984).
  - OAS pin bumped to `0.155.1` + compat fixes (#7993).
  - CHANGELOG `[0.9.10]` TBD placeholders filled (#7994).
  - `.tmp/` scratch directory added to `.gitignore` (#7998).

### Deprecated

- **Capsule Execution Plan slices marked historical (#7984).**
  `docs/design/masc-capsule-execution-plan.md` Slices A–C targeted the retired
  `team_session` subsystem (9 dead `lib/team_session/*` and
  `lib/tool_team_session_*` module refs). Slices preserved as migration context
  for future `board_posts` + keeper-FSM coordination work. Product Thesis,
  Boundary Rules, Execution Order, Social Runtime Invariants, and Review Gate
  sections remain the current design stance.

## [0.9.10] - 2026-04-17

### Changed

Bulk merge cycle (2 `/loop` batches, admin override) covering dashboard UX, keeper observability, lock-free refactors, and spec/docs cleanup.

- **Dashboard UX.**
  - Connector overview strip gains an incident banner for sidecars dropped in the last 5 min (#7925) and an aggregate summary line (#7944).
  - Auto-restart toggle chains Save → stop → start on connector config (#7933).
  - Quick-bind form supports Enter-to-submit with per-connector channel ID hint (#7970).
  - Setup guide gains per-step completion checklist (#7974) and Vercel-style Start button on onboarding cards (#7963).
  - Copy affordance: new `CopyIdButton` on transport-health hot session ids (#7973) with inline "Copied" confirmation (#7980).
  - Live-ticking counter on startup-warning banner (#7967).
  - Text filters added to mission worker-runs evidence list (#7975) and runtime-monitor model-id/tool-name search (#7957).
  - Keyboard shortcuts for connector navigation (1–4, ?) (#7958).
  - Keeper modal KPIs regrouped into 4 question-led sections (#7946).
  - Live Judge promoted to page title; empty toolbar card purged (#7969).
  - AA accessibility pass on connector readiness rail (#7960).
  - Zod parse boundary for SSE events (#7955).
  - Outcomes rollup added to keeper JSON response (#7941).
  - Autoresearch loops API + list UI gain pagination (#7861).

- **Keeper / server / lib.**
  - Keeper behavioral regime deriver MVP (7th FSM axis: Crashing/Thrashing/Healthy) (#7968).
  - HTTP transport session/conn registries: global mutexes eliminated via lock-free atomic maps (#7979).
  - `a2a` global mutexes eliminated via lock-free atomic maps (#7857).
  - Dashboard cache global mutex eliminated via lock-free atomic map (#7953).
  - New `Lockfree_atomic` helper module extracted for reuse (#7952).
  - `bash exec` substrate semantics hardened (#7891).
  - Board flusher actor started with jsonl backend (#7915).
  - Autoresearch: exception-throwing serde helpers removed (#7942).
  - Dashboard: unexport internal-only helpers across 2 component files (#7977).
  - Dead cluster removal: `governance-panels/detail/strips` (follow-up #7927) (#7962), 3 orphan components (mission, connector-binding-summary, execution/shared) (#7938), orphan `keeper_handoff_delta` module (#7948).

- **Spec / docs / tooling.**
  - TLA+: `KeeperConditionsGovernPhase` liveness spec + clean/buggy cfg pair (#7965).
  - Spec §2 module table + §17 references synced with `lib/coord/` (room → coord rename) (#7954).
  - Comprehensive glossary sync: Chain/CP/agent_ecosystem/context_budget retired (#7964).
  - Keeper spec §05 synced with current keeper module layout (#7972).
  - Dead `code_refs` dropped (`sdk_version.ml`, `agent_ecosystem`, `message_schema`); §6 retired (#7945).
  - Retired CP/MDAL dropped from `DASHBOARD-INTEGRATION`; self-contradicting `BENCHMARK-RUNBOOK` note fixed (#7943).
  - Runtime gate for frontmatter `code_refs` existence (#7966).
  - OAS pin bumped to `cb4beb52` (PR-O2 pipeline → `Complete.complete`) (#7956).
  - `oas-pin` orphan SHA `6c79cf3f` replaced with ref-reachable `f2387e2a` (#7898).

### Deprecated

- None.

## [0.9.9] - 2026-04-17

### Changed

- **README facts aligned with code (PR #7730).**
  - OAS pin floor in badge + Tech Stack: `0.118.2` → `0.153.0` (matches `masc_mcp.opam` and `dune-project`).
  - Keeper lifecycle diagram corrected from "11-state" to the actual **12 states** in `lib/keeper/keeper_state_machine.mli` (`Overflowed` was missing).
  - WebRTC signaling endpoints made precise: `POST /webrtc/offer`, `POST /webrtc/answer`, gated by `Server_webrtc_transport.is_enabled`.
  - Personal-project disclaimer added (Korean + English) at the top.
  - "Production surface" framing replaced with surface-map vocabulary that doesn't imply external SLA.
- **Root scratch removed (PR #7744).**
  - `git rm` on 9 tracked one-off files: `pr-payload.json`, `pr6975.json`, `pr_body_tmp.txt`, `test-integration-{retry,verify}.txt`, `test_portal_lock_stress.ml` (no rg refs in `lib/bin/test/scripts`), `EIO_REFACTOR_ISSUES.md`, `AGENTS.md` (CLAUDE.md is the live SSOT), `session_tracker_qa_tests.md`.
  - `.gitignore` extended with `pr-*.json`, `pr_body_*.txt`, `test-integration-*.txt` so future drops are ignored automatically.
- **Audit tracker added (PR #7749).** `docs/_audit/2026-04-17-doc-classification.md` classifies all 145 markdown files in `docs/` into A·Live (81) / B·Historical (46) / C·Hype (7) / D·Duplicate (11), with grep evidence and disposition per file. Tracker only — actual delete / archive / merge / frontmatter PRs are sequenced separately.

No code changes. Bump captures the documentation/hygiene cycle as a tagged release boundary.

## [0.9.8] - 2026-04-17

### Changed
- **OAS pin bump to `v0.153.0`** — picks up OAS PR #975
  (`Budget_strategy.default_summarizer` exported in the `.mli`).
- **`keeper_summarizer.ml` simplified** — deletes the local
  `default_extractive_summary` re-implementation and delegates to
  `Agent_sdk.Budget_strategy.default_summarizer` directly. This was
  the follow-up promised in PR #7668 (Gen4 compaction-layer [STATE]
  scrub). Net diff: −36 lines; behavior unchanged (4 existing tests
  in `test_keeper_summarizer.ml` still pass).
- `scripts/oas-agent-sdk-pin.sh` BASE/SHA/MIN → `v0.153.0` /
  `485ac29af8c14942e29c99381a9946c7000a55c9` / `0.153.0`.

## [0.9.7] - 2026-04-17

### Changed
- **OAS pin bump to `v0.152.0`** — raises the `agent_sdk` floor in
  `dune-project` and updates the helper constants in
  `scripts/oas-agent-sdk-pin.sh` (BASE_VERSION, SHA, MIN_VERSION) to
  `d5d92f38f6490b924238b5a176a9feb6e79d17e3`.
  - Picks up OAS PR #973 (`Agent.options.summarizer` +
    `Builder.with_summarizer`): downstream consumers can now inject a
    custom summarizer callback into `Budget_strategy.reduce_for_budget`
    via the options record instead of falling through to
    `default_summarizer`.
  - Also picks up OAS PR #962 (Anthropic `cache_extended_ttl`), included
    transitively via the 0.151.0 release.
  - No runtime behavior change in masc-mcp itself: this is a pin-only
    bump. Registering a `[STATE]`-aware summarizer is the follow-up step
    and ships separately.

## [0.9.6] - 2026-04-16

### Fixed
- **Keeper continuity resonance loop** (PR #7612, #7615, #7618) — closes the
  save/read asymmetry that caused keepers to echo their own prior `[STATE]`
  narrative every turn.
  - `keeper_world_observation.ml:read_continuity_summary` now prefers the
    structured snapshot stored in `Checkpoint.working_context` over
    re-parsing `[STATE]` blocks from message bodies (PR #7612). Completes
    the RFC-MASC-001 Phase 1 read side; the save side already wrote
    structured JSON when enabled.
  - `scripts/retro-clean-keeper-continuity.sh` one-shot: dry-run default,
    `--apply` backs up and zeroes stale `continuity_summary` fields across
    `.masc/keepers/*.json`. Preserves all other fields (PR #7615).

### Changed
- **`MASC_STRUCTURED_STATE` default flipped to `true`** (PR #7618) —
  completes RFC-MASC-001 Phase 1 rollout. The structured
  `Checkpoint.working_context` save path is now active by default;
  combined with PR #7612 every keeper turn writes a typed snapshot and
  reads it back on the next turn instead of re-parsing `[STATE]` text.
  Accepted opt-out values: `false`, `0`, `no`. Legacy text `[STATE]`
  fallback is preserved for checkpoints without `working_context`.

## [0.9.5] - 2026-04-16

### Added
- **CDAL Verdict Gate** (PR #7531, env `MASC_CDAL_GATE_ENABLED`, default off) —
  `cdal_verdict_gate.ml` blocks task completion when CDAL verdict is Violated
  or Inconclusive with blocking gaps. Reads persisted verdicts with task_id
  filtering via typed `persisted_verdict` envelope.
- **Task verification FSM** (PR #7531, env `MASC_VERIFICATION_FSM_ENABLED`,
  default off) — new `AwaitingVerification` task_status + 3 actions
  (`submit_for_verification`, `approve`, `reject`). Cross-agent enforcement
  (worker ≠ verifier). Contract-driven deadline and required role.
- **Verification protocol** (`verification_protocol.ml`) — board post + SSE
  event emission on submit/approve/reject/timeout. Updates
  `Verification.ml` state machine on cross-agent verdicts.
- **Keeper-as-verifier** — `pending_verification_count` in
  `world_observation`; keepers can observe and act on verification requests
  via `masc_transition(action=approve|reject)`.
- **Typed evidence criterion** — `Types_core.evidence_criterion` ADT
  (Schema_match/Contains/Not_contains/Custom) replaces string list for
  `task_contract.verify_gate_evidence`. Backward compat reader.
- **Env-configurable knobs** —
  `MASC_CDAL_VERDICT_LOOKUP_LIMIT` (default 500),
  `MASC_VERIFICATION_TIMEOUT_CHECK_INTERVAL_SEC` (default 60.0).

### Changed
- verification_id now cryptographically random (128-bit CSPRNG via
  mirage-crypto). Previously used `Hashtbl.hash` + timestamp (weak).
- Dashboard shows `검증 대기` badge for `awaiting_verification` status
  (accent color, event icons).

### Deprecated
- Legacy `_task_id` string-prefix JSONL envelope still read but no longer
  written. Reader handles both formats.

## [Unreleased]

### Changed (specs)

- **`KeeperContextLifecycle.tla` completeness pass** — closes 3 of the
  gaps flagged by the 2026-04-16 compaction FSM/TLA+ audit
  (#7568 §1.4):
  - `CompactionFailed(k)` action added (documentation-only in the
    clean `Next` to avoid infinite retry without a bounded retry
    variable; exercised by `NextBuggy`). Models the
    `Compaction_failed` event at `keeper_state_machine.ml:383-389`
    that routes `compacting → overflow_retry` without clearing
    `context_overflow`.
  - `CompactionCompletesBuggy(k)` + `NextBuggy` + `SpecBuggy` —
    new Bug Model variant that reallocates `context_id` during
    compaction (models a broken Context.t identity path).
  - `CheckpointConsistency` strengthened: previously a duplicate of
    `TurnMonotonicity` (`ckpt_turn <= turn + 1`); now verifies that
    `ckpt_ctx_id` references an allocated context_id
    (`0 < ckpt_ctx_id < next_ctx_id`). Strengthens formally-verified
    surface without weakening the turn-monotonicity check.

### Added (specs)

- `KeeperContextLifecycle-buggy.cfg` — Bug Model cfg that runs the
  deliberate `CompactionCompletesBuggy` variant. TLC finds
  `Invariant ResumeIdentity is violated` at 377 states / depth 6 /
  1s. Completes the Bug Model pattern coverage that was missing.
- `KeeperContextLifecycle-ci.cfg` — smaller-constant cfg for quick
  invariant validation in every CI build. Reserves the default cfg
  (5.6M+ states) for nightly/release runs. Liveness
  (`PROPERTIES`) intentionally omitted — see file header comment.

### Follow-ups (out of scope)

- Add a bounded retry-budget variable to model the
  `compact_retry_exhausted` latch → `Paused` routing, then include
  `CompactionFailed(k)` in the clean `Next` and re-add liveness to
  `KeeperContextLifecycle-ci.cfg`.
- Upgrade `TurnSucceeds` fairness from WF to SF so small-model
  liveness holds without growing the state space (exposed by
  `KeeperContextLifecycle-ci.cfg` during this work).

## [0.9.5] - 2026-04-16

### Added

- **Keeper compaction audit** (`lib/keeper/keeper_compact_audit.{ml,mli}`).
  New Event_bus subscriber that observes `ContextCompactStarted` and
  `ContextCompacted` payloads emitted by OAS, synthesises a per-keeper
  `compaction_id` to correlate Start/Complete pairs, and appends
  structured JSONL rows to `.masc/data/harness-compact/YYYY-MM/DD.jsonl`.
  Rolling retention (default 14 days, override via
  `MASC_COMPACTION_AUDIT_RETENTION_DAYS`) prunes old day-files on every
  write — self-healing, no cron. No OAS changes required; subscriber
  runs alongside existing `oas_sse_bridge` each on its own bounded
  stream.
- **Audit CLI** (`bin/masc_compaction_audit.ml`, installed as
  `masc-compaction-audit`). Options: `--since`, `--until`,
  `--keeper NAME`, `--orphans-only`, `--prune`, `--retention-days`.
  Pairs Start/Complete by `compaction_id`, emits human-readable summary,
  flags orphan rows (compaction that never completed, or server crash).
- **Compaction FSM/TLA+ audit** (`docs/audits/compaction-fsm-tla-audit-2026-04-16.md`,
  #7568). Traceability matrix for `KeeperContextLifecycle.tla` and
  `MemoryCompaction.tla` against 12-phase OCaml FSM. Confirms
  `Compaction_completed`/`Compaction_failed` handlers align with spec
  intent; reclassifies the `manual_reconcile_required` drift from prior
  audit as abstraction mismatch (live behaviour correct via PR #6834's
  separate event dispatch). Flags gaps: missing
  `KeeperContextLifecycle-buggy.cfg`, no `CompactionFailed` action in
  context spec, 3-of-5 gate abstractions.

## [0.9.4] - 2026-04-16

### Added

- **Runtime TOML config** for all 4 Python sidecars (#7509, #7518). Each
  sidecar reads an optional `$MASC_BASE_PATH/.gate/runtime/<kind>/config.toml`.
  File absent = field defaults only (zero-config works). Secrets stay in
  env vars. Priority: env > TOML > field default.
- **Shared bindings-store helpers** (`gate_shared/bindings_store.py`,
  #7501). `load_bindings` + `save_bindings` free functions replace 3x38
  duplicated lines across Slack/iMessage/Telegram sidecars.
- **Env-var aliases** for Slack + Telegram timeout/path config fields
  (#7506).
- **Cascade `weighted_entry.supports_tool_choice`** (#7493). Per-entry
  capability override parsed from cascade.json; `sangsu` profile's
  Ollama entry declares `"supports_tool_choice": true`.

### Changed

- **OAS pin bumped to v0.150.0** (#7493). Removes
  `OAS_OLLAMA_SUPPORTS_TOOL_CHOICE` env var in favor of per-config
  `Provider_config.supports_tool_choice_override`.
- **Code quality pass** (#7516): trimmed 56 LOC of excessive comments +
  fixed 3 TOCTOU `Sys.file_exists` pre-checks in `read_json_file_opt`.

### Fixed

- Keeper: redirect `gh` to keeper_shell op=gh (#7474), demote
  semaphore_wait logs to INFO (#7472), add admin tools to Keeper_denied
  surface (#7455), hand off after overflow retry (#7435), accept both
  `pr_number` and `number` in keeper_pr_review (#7476).
- CI: pin `ocaml/setup-ocaml` to avoid upstream opam-binary regression
  (#7499).
- Dashboard: activity_graph events_shown vs events_store_total (#7502).
- Coord: before-state snapshots in error path logging (#7512), unified
  transition log_event JSON (#7504), correlation_id/run_id on task
  activity (#7511).

## [0.9.3] - 2026-04-16

### Changed

- **Gate wire vocabulary migrated** from `keeper_name` to `destination_id`
  across a 4-phase rolling deprecation. The Gate library is en route to a
  standalone `gate-mcp` repo (Track B4); `keeper_name` carried
  MASC-specific language that didn't belong in a generic gate contract.
  Phases:
  - Phase 1 (#7482): `inbound_of_json` accepts either key (prefers
    `destination_id`).
  - Phase 2 (#7484): `outbound_to_json` emits both keys.
  - Phase 2b (#7485): sidecar `GateResponse.from_json` parses either
    key on the consumer side (single shared helper covers all four
    Python sidecars).
  - Phase 3 (#7487): `outbound_to_json` drops `keeper_name`; only
    `destination_id` emitted now.
  - Phase 4 (future major release): rename internal OCaml record field
    and inbound-only `keeper_name` parse as well.

### Migration note

Out-of-tree consumers that still read only the `keeper_name` key from
gate reply JSON now see `null`. Upgrade to read `destination_id`. The
transition window was Phase 2 → Phase 3 (both keys emitted); consumers
had the full Phase 2 release to migrate.

## [0.9.2] - 2026-04-16

### Changed

- **B3c Python sidecar migration complete**. All four Python sidecars
  (`discord-bot`, `imessage-bot`, `slack-bot`, `telegram-bot`) now
  default to `.gate/runtime/<kind>/*` and share the same 1-tier legacy
  read-fallback pattern. Pre-v0.9.0 `bindings.json` auto-discovered on
  first startup; next save writes to the new default (#7477 iMessage,
  #7478 Slack, #7479 Telegram). Discord already migrated in v0.9.1.

### Fixed

- **OCaml bootstrap no longer depends on upstream latest-opam auto-pick**.
  On 2026-04-16 the latest stable `opam 2.5.1` release was published
  before Linux x86_64 binaries were attached, so `ocaml/setup-ocaml`
  failed early with `Failed to find opam binary for 'linux' and 'x86_64'`.
  The shared toolchain bootstrap now downloads the published `opam 2.5.0`
  Linux binary directly and `release.yml`, `webrtc-live-interop.yml`, and
  `deploy-railway.yml` reuse the same local bootstrap.
  Closes #7475.

## [0.9.1] - 2026-04-16

### Changed

- **Gate runtime path migration**: default storage paths move from
  `.masc/connectors/<kind>/*` to `.gate/runtime/<kind>/*` for Discord
  (OCaml + Python sidecar) and iMessage (OCaml). The pre-v0.9.0 layout is
  demoted to `legacy_*_path` so existing deployments see a transparent
  read-fallback — next write lands at the new default (#7467, #7468, #7470).
- iMessage's OCaml `configured_read_path` gained a required `~legacy`
  parameter, matching the Discord resolver in
  `Channel_gate_discord_names`. Read priority: env var > new default (if
  file exists) > legacy (if file exists) > new default (stable for later
  creation) (#7468).
- Discord sidecar cleanup: the `LEGACY_BASE_ROOT = Path("sidecars/discord-bot")`
  constant and `_resolve_legacy_storage_path` helper were removed. They
  served a 2026-Q1 cwd-relative layout (`sidecars/discord-bot/.gate/discord_*`)
  that is no longer auto-discovered; deployments still on it must set
  `DISCORD_*_PATH` env vars explicitly (#7470).

### Deferred to v0.9.2

- iMessage, Slack, Telegram sidecar migrations (Python). These sidecars
  currently have **no read-fallback loop** in their `bot.py` entry, unlike
  Discord. Each needs a 1-tier fallback wired in before the `DEFAULT_*` →
  `LEGACY_*` rotation can safely ship.

## [0.9.0] - 2026-04-16

### Added

- **Dashboard UX**: density toggle (comfortable/compact) (#7377); Compound Graph
  toggle bound to `g` (#7398); tab anomaly indicator on selected keeper (#7383);
  manual refresh button + `r` shortcut (#7378); Watson-pattern inferred reason
  on transition trail (#7397); time-windowed observatory telemetry (#7390).
- **Keeper features**: social transition reasons exposed + cross-turn state
  (#7399, #7395); magentic ledger social model + TLA+ spec (#7426, #7430);
  campaign FSM harness (#7385); `sangsu` cascade profile — local-first Ollama +
  GLM fallback (#7404); pipe support in `masc_code_shell` (#7393).

### Changed

- **Discord connector dashboard is now keeper-first** (#7388). Each configured
  keeper has its own section with inline channel-binding management; bindings
  that reference a keeper not in the directory are surfaced under `⚠` instead
  of being silently dropped. Replaces the prior binding-first grouping that
  users reported as opaque across 5 distinct confusion points.
- **Gate library extraction**: pure Gate modules (`gate_protocol`,
  `channel_gate_connector`, `channel_gate_discord_*`, `channel_gate_imessage_*`,
  `channel_gate_metrics`, `gate_time_util`) moved to `lib/gate/` as the
  `masc_gate` sub-library (#7407 B1a). `channel_gate` facade joined the same
  sub-library after Pulse extraction (#7457 B1c). Call sites unchanged thanks
  to `wrapped false`. Prerequisite for the planned standalone `gate-mcp` repo.
- **Pulse library extraction** (#7452 B1b): the beat engine moved to
  `lib/pulse/` as the `masc_pulse` sub-library. Unblocks Gate's dependency on
  Pulse without routing the arrow back through `masc_mcp`.
- **OAS pin → v0.148.0** (from v0.141.0) (#7394 + prior pins). Legacy cascade
  API removed from OAS across v0.142.0–v0.148.0 — `Judge.judge` and
  `Tool_selector.default_rerank_fn` now take a single `Provider_config.t`, and
  `Cascade_executor` was deleted (839 LOC). Cascade orchestration is now
  entirely a MASC concern; `keeper_agent_run` resolves the cascade locally,
  picks the first healthy provider, and passes a single provider to the
  single-provider SDK. Falls back to `core+prefilter+discovered` on
  no-healthy-provider (same as before).
- **`Room` module retired** (#7355): split into `room_state.ml` + renamed
  remainder to `Coord`.
- **Hashtbl → immutable StringMap/StringSet** across 14+ modules: `exec_memory`
  (#7414 #7416), `memory_bank` (#7429), `memory_recall` (#7421), `hooks_oas`
  (#7428), `tool_diversity` (#7425), `types_profile` (#7423), `rate_limit`
  (#7420), `cancellation` (#7419), `supervisor` (#7409 #7410), `context_core`
  (#7418), `exec_shared` (#7417), `tool_policy` (#7359), `agent_identity`
  (#7422), `streamable_http session storage` (#7427).
- Stringly-typed internal variants replaced with typed sums (#7347).
- `fail_fast_enabled` → `startup_abort_eligible` rename (#7415).

### Fixed

- Dashboard: 50-task hard cap removed (#7432); legacy composite payload
  normalized (#7412); duplicate cache timeout WARN in bg-revalidate (#7446);
  repeat shell cache timeout on rooms with many board posts (#7402).
- Keeper: deduplicated tool_use_failure + cycle-failure WARN/ERROR
  (#7454, #7451); `gh` timeout floor + org allowlist in `validate_gh_command`
  (#7433); status tails sorted + continuity fallback marker (#7363); real-cause
  pointer when `rg` exits 2 (#7408).
- Log: normal keeper/JSON flows no longer WARN (#7444).
- Board: `masc_board_post` accepts `body` alias + auto-fills author (#7445);
  duplicate 100-post pagination cap removed (#7396).
- Checkpoint: malformed checkpoint detection logging in `load_latest` (#7413).

### Removed

- `keeper_pr_submit` tool + hardened `gh`/dashboard flows (#7389).
- 18 dead permission entries (#7434); dead tool references
  (`masc_release`, `swarm_start` variants) (#7376).
- Dead `Blocked` variant from `turn_outcome` (#7346).
- Dead functions from `keeper_status_bridge` (#7403, #7406).

## [0.8.0] - 2026-04-15

### Changed
- **Tool registry pruning** (#7184): removed 65 dead tools with zero
  usage in April 2026 tool_usage logs. Deleted 5 entire subsystems
  (verify_*, auth_*, repair_loop_*, handover_*, heartbeat internals)
  as 19 source files + ~7,700 lines. Also pruned individual dead
  handlers, schemas, permission entries, and dispatch arms for 25+
  system-internal tools (agent eval, error tracking, lock/unlock,
  cancellation, subscription, progress, feature_flags, init,
  governance_set, set_room, etc.). keeper_denied surface reduced to
  `masc_reset`, `masc_spawn` only. masc_heartbeat dispatch relocated
  from deleted tool_heartbeat.ml to tool_room.ml.

### Added
- Operator-facing context overflow recovery tools (#7115). Two new MCP
  tools paired with the `Overflowed` phase introduced in #7083:
  - `masc_keeper_compact`: dispatches `Operator_compact_requested` to the
    keeper FSM and runs checkpoint compaction via OAS
    `recover_latest_checkpoint_for_overflow_retry`. Phase precondition is
    `Overflowed`/`Paused`/`Compacting`; `force=true` bypasses for
    `Running`/`Failing`.
  - `masc_keeper_clear`: last-resort context wipe. Loads the checkpoint,
    clears non-system messages (system prompt preserved by default), saves
    a new checkpoint, dispatches `Operator_clear_requested`. Requires an
    operator-provided `reason` for audit trail.
- Prometheus counters for the new operator tools:
  `masc_keeper_operator_compact_total{keeper,result}` (result ∈
  `ok|no_checkpoint|precondition`) and
  `masc_keeper_operator_clear_total{keeper,preserve_system}`.
- `checkpoint_found` field in the `masc_keeper_clear` response so
  operators can distinguish "no messages to clear" from "no checkpoint
  on disk".

### Fixed
- `masc_keeper_compact`/`masc_keeper_clear` now read/write checkpoints
  from `session_base_dir(config)` (`<masc_root>/.masc/traces`) instead
  of the incorrect `<base_path>/<keeper_name>`. Previous path would have
  made the tools always report missing checkpoints.
- When no valid checkpoint exists, `masc_keeper_compact` now dispatches
  `Compaction_failed` rather than `Compaction_completed { 0, 0 }`. The
  latter was a false-success signal that would clear `context_overflow`
  even though no compaction happened.

## [0.7.0] - 2026-04-14

### Added
- Prometheus metrics dashboard surface under monitoring tab (#6974). Fetches
  `/metrics`, parses Prometheus text format, renders 8 categorized tables
  (Server, Agent, Keeper, Transport, Inference, Tool, Delta, Provider).
- Clickable links from Prometheus labels: `keeper=` labels navigate to
  keeper detail, `tool_name=` labels navigate to tool-quality with
  highlight-and-scroll of the matching row (#7017).
- Agent + Transport metric categories — recategorize `masc_agent_*`,
  `masc_grpc_*`, `masc_ws_*` that previously fell into Other (#7017).
- RFC-0003 Keeper Composite Lifecycle docs + TLA+ spec with buggy variants
  (cascade, compaction, recovery) for regression-style verification (#7020).

### Fixed
- UTF-8 sanitization on outbound telemetry writers. `keeper_tool_call_log`
  and `oas_sse_bridge` now scrub invalid UTF-8 before persisting or
  broadcasting, eliminating ~12% JSONL row drop when tool output contains
  truncated multi-byte sequences (#6929).
- Prometheus histogram export format. `to_prometheus_text()` now emits
  histograms as `summary` type with `_sum`/`_count` pair rather than the
  invalid `histogram` bare type, so Prometheus servers parse the metrics
  correctly (#6936).
- `tool_usage_log` syntax error at line 105 (`let counts = fold_left ...`
  missing `in`) that broke Build/Test, Health, and Lint CI (#6975).
  Complexity comment updated from O(1) to O(log n) to match StringSet.mem.

### Changed
- Concurrency hardening: serialize `keeper_recurring` tasks Hashtbl +
  atomic id counter (#7022), `sse event_buffer` Queue with Eio.Mutex
  (#7016), `tool_shard` agent_shards read-modify-write (#6985).
- Pin `agent_sdk` to 0.134.0 (#7012).
- CI `ci_core=true` no longer forces TLA+, saving ~14 min per run (#7024).
- Dashboard: remove unused config binding in `ordered_room_ids` (#7021).

## [0.6.0] - 2026-04-14

### Added
- Dashboard OAS telemetry surface (#6978).
- `oas_sse_bridge` usage relay wiring (#6938).

### Changed
- Concurrency and observability fixes carried over from the 0.5.x line.

### Notes
- Version bumped in `dune-project` and `masc_mcp.opam` by #7009. This
  entry finalizes the release docs that were omitted in that bump, so
  `scripts/check-version-truth.sh` stops failing on every main-base PR.

## [0.5.11] - 2026-04-13

### Changed
- Replace all `Eio.traceln` in `lib/` with structured `Log` module
  calls (cascade_inference, autoresearch_codegen, dashboard judges,
  opentelemetry_client). Zero ad-hoc traceln calls remain.
- Add relay calibration drift metric: warn on correction_factor
  outside [0.5, 1.5], debug on shift > 0.1.

## [0.5.10] - 2026-04-13

### Added
- MASC-driven cascade FSM Phase 2: direct provider failover from MASC (#6776)
- Event_bus envelope API adoption: correlation_id + run_id metadata (#6777)
- Groq cascade fallback restored (#6566)
- OAS log bridge to masc-mcp structured logging (#6618)
- Keeper cascade provider allowlist env knob (#6478)
- Cross-model enforcement rate on dashboard (#6565)
- Keeper FSM dashboard exposure + TLA+ bug model (#6556)
- Prometheus llm_provider_http_status metrics (#6514)

### Fixed
- OAS pin v0.124.2: GLM auth passthrough (static_token) + intra-turn truncation (#6781, #6790)
- Cascade: add default_api_key_env for GLM providers (#6784)
- Admission queue: size to actual decode parallelism (#6768), passthrough mode (#6788)
- Keeper: context compaction in reducer (#6731), unified prompt CI alignment (#6700, #6783)
- Test: prevent integration tests from leaking real PRs to GitHub (#6756)
- Test: align admission queue default (#6785)
- Remove dead blocker_class_of_failure_reason (#6778)

### Refactored
- Spawn: add mcp_flag/prompt_flag types, replace match tables (#6767)
- Keeper: immutable string list for keeper_internal_set (#6761)

### Docs
- RFC-MASC-001 (checkpoint boundary migration), MASC-004 (memory bridge), MASC-005 (dashboard eval consumer) (#6787)

## [0.5.9] - 2026-04-12

### Added
- Harden OAS telemetry visibility and proactive monitoring (#6679)

### Fixed
- Keeper: add keeper_board_delete + cleanup to boundary-exempt list (#6698)
- Lazy: replace Stdlib.Lazy with Eio.Lazy in keeper modules (#6696)
- Dashboard: externalize agent status thresholds (#6683)
- Prompt: restore world prompt contract and sanitize unified prompt (#6675)
- Prompt: reinforce playground containment in keeper capabilities (#6678)
- Re-raise Eio.Cancel.Cancelled in 5 catch-all handlers (#6697)
- CI: unblock Build and Test (#6699)

### Hardened
- Store cache: mutex-protect Dated_jsonl store caches (#6690)
- Agent registry: serialise session cache mutations (#6682)

### Performance
- Memory OAS bridge: move episode JSONL load outside cache mutex (#6671)
- Prompt registry: move markdown disk reads outside registry mutex (#6663)

## [0.5.8] - 2026-04-12

### Fixed
- SSE: stop double-incrementing event_counter when ~id is passed (#6660)
- RNG: guard module-level Random.State with Eio.Mutex in 3 modules (#6652)
- Repair loop: gate working_dir on caller playground (#6651)
- Local runtime pool: drop dead select_runtime, re-check fingerprint after env load (#6650)
- Cascade: remove coding_first profile, cap max_tokens to 32768 (#6687)
- Cascade: clamp keeper_unified + coding_first max_tokens to 32768 (Groq limit) (#6686)
- Build identity: probe exe_dir before cwd for git commit (#6688)
- Keeper: masc_* boundary-exempt gap + cascade.json prune (#6681)
- Worker OAS: stop sending min_p=0.0 to cloud providers (#6672)
- Keeper checkpoint store: classify Eio.Io Fs Not_found as Not_found (#6655)

### Changed
- Bump OAS pin for GLM max_tokens clamp (#6689)
- Improve keeper timeout visibility (#6552)

### Performance
- Board: move Agent_economy.earn outside store.mutex (#6649)

## [0.5.7] - 2026-04-12

### Fixed
- CP unit: bound descendant_units_of_kind recursion (#6647)
- Prompt registry: merge validate+write into single mutex transaction (#6646)
- Room task schedule: reuse Room_task.update_local_agent_state on agent writes (#6642)

### Changed
- Bump OAS pin for min_p capability gate fix (#6653)
- Keeper: remove redundant UTF-8 sanitize calls on LLM input path (#6645)
- Docs: fix prompt-layer drift teaching server-root .worktrees/ (#6648)

## [0.5.6] - 2026-04-12

### Added
- Restore Groq cascade fallback, confirmed by OAS 0.121.0 (#6566)
- Bridge Agent_sdk.Log to masc-mcp structured log (#6618)

### Fixed
- CP unit: bound descendant_ids recursion with max_tree_depth guard (#6635)
- Room task: hold with_file_lock on agent state writes (#6634)
- Room/CP: hold with_file_lock around archive read-modify-write (#6632)
- Session: hold registry.lock on all hashtable reads, drop dead unregister_sync (#6628)
- Auth: gate cross-agent create_token and revoke on initial_admin (#6627)
- Channel gate: wire dedup_cleanup into orchestrator pulse (#6612)
- Keeper: fix retry timeout budget and local-only context (#6593)
- Config: prefer base-path config over repo-local env (#6626)

### Changed
- Bump OAS pin to v0.122.0 (#6631)

## [0.5.5] - 2026-04-12

### Added
- Harness: expose cross-model enforcement rate on dashboard (#6565)
- Dashboard: expose keeper FSM + root-fix hardcoded constants + TLA+ bug model (#6556)

### Fixed
- Keeper: cap Eio.Semaphore.acquire wait in with_keeper_turn_slot (#6608)
- Keeper: delete manual_reconcile file on clear to unblock legacy binaries (#6576)
- Tool worktree: reject cross-agent agent_name in masc_worktree_create (#6617)
- Tool code_write: scope writable paths and clone cwd per-agent (#6610)
- CI: narrow Keeper_tool_policy_config shortcut, revert signature tightening (#6607)
- CI: require tool_policy.toml in config_signature_exists (#6595)

### Changed
- Bump OAS pin to v0.121.0 for keep_alive=-1 fix (#6601)
- CI: wire specs/bug-models/ into tla-check.sh (#6582)

### Specifications
- TLA+ KeeperTaskInterlock: no Dead keeper holds a claimed task (#6574)

### Documentation
- Document post-turn-lifecycle implicit invariant (#6604)

## [0.5.4] - 2026-04-11

### Added
- `MASC_KEEPER_CASCADE_PROVIDER_ALLOWLIST` env knob for runtime cascade narrowing (#6478)
- `Config_dir_resolver.log_resolution` startup log with shadow hint (#6478)
- `test_cascade_config_validity` alcotest suite for cascade.json profiles (#6478)
- `scripts/sync-version-truth.sh` dry-run version sync helper (#6478)
- `scripts/opam-pin-external-deps.sh --install` flag (#6478)

### Changed
- Keeper: remove scope_kind gating (#6544)
- Cascade: drop unsupported groq labels (#6558)
- Dashboard: remove dead SSE route entries (#6557)

### Fixed
- Keeper: block write ops outside playground in keeper_bash (#6579)
- Keeper: address cross-model review follow-ups for #6543 (#6563)
- Keeper: log when open_pending overwrites a Cleared reconcile record (#6562)
- Keeper: use Eio.Lazy for decision_audit env caches (#6549)
- Keeper: tolerate text_response when provider ignores tool_choice (#6532)
- Keeper: distinguish Cancel from Timeout in LLM bridge (#6543)
- Keeper: enforce base path SSOT for playgrounds (#6548)
- Keeper: fix startup base path and cwd defaults (#6546)
- Keeper: fix channel gate ack leak (#6545)
- gRPC: guarantee cleanup on heartbeat fiber exit paths (#6524)
- gRPC: guarantee typed_stream close on subscribe fiber exit paths (#6529)
- Worktree: remove server-root fallback from worktree_create_r (#6542)
- Config: align config truth with runtime paths (#6503)
- CI: clean log noise and TLA workflow (#6505)
- Dashboard: type supervisor_diagnostics + ErrorState wave 3 (#6550)
- Test: clone into playground before masc_worktree_* (#6577)
- Docs: require keeper worktree under own playground clone (#6533)

## [0.5.3] - 2026-04-11

### Added
- Expose llm_provider_http_status via Prometheus counter (#6514)

### Changed
- Extract shared tool permission map from auth (#6501)
- Rename type result to tool_result across all tool modules (#6482)
- Bump OAS pin to v0.120.0 (#6510)
- Replace tautological assertions with observable post-conditions in keeper-registry tests (#6506)
- Prune retired front doors (#6520)
- Remove unused delete_posts_by_predicate (#6509)
- Remove 13 dead dashboard exports (#6493)

### Fixed
- Keeper: gate auto-clear of manual reconcile behind age threshold (#6497)
- Keeper: should_run_turn now consults manual_reconcile_pending (#6518)
- Keeper: SSOT playground paths, drop hardcoded masc-mcp and container root (#6468)
- Keeper: convert parse_keeper_identity from failwith to Result (#6479)
- Keeper FSM runtime integration (#6451)
- Goal-janitor: surface write_meta Error instead of ignoring (#6513)
- Board: log vote/vote_comment errors instead of silent drop (#6463)
- Backend: detect partial writes in atomic_increment and atomic_update (#6480)
- Transport: surface WS and WebRTC send failures in server bootstrap (#6517)
- Eio: wrap oas_sse_bridge + rate_limit cleanup fibers with exception loggers (#6519)
- Dashboard: restore control surface routing (#6490, #6523)
- Dashboard: standardize error display to CSS variable color scheme (#6494)
- Dashboard: standardize time display to relativeTime/TimeAgo (#6491)
- Dashboard: improve accessibility for buttons and form labels (#6496)
- Dashboard: preserve board scroll position on refresh (#6461)
- Dashboard: rename harness rail labels to match actual state (#6521)
- Dashboard: align navigation descriptions with actual UI (#6526)
- Worktree: use config base_path for worktree root (#6449)
- Playground: docker_playground_cwd double-slash escape (#6522)

### Security
- Remove tracked localhost TLS key from repository (#6487)

### Performance
- Memoize expensive derived state in fleet and agent-roster dashboard (#6492)

## [0.5.2] - 2026-04-11

### Changed
- Eliminate vendor hardcoding outside provider_adapter boundary (#6495)
- Root cause fixes for JSONL parsing, keeper_github repo, preset validation (#6457)

### Fixed
- Restore loopback cross-port relaxation in auth (#6504)
- Delegate context budget to OAS pipeline (#6488)

## [0.5.1] - 2026-04-11

### Changed
- FSM apply_event returns `Applied | Ignored` transition type — detect invalid events (#6481)
- Replace stringly-typed gate field with variant type (#6454)

### Fixed
- Restore keeper reset surface and typed tool expectations (#6477)
- Use glm-coding (Coding Plan) before glm (pay-per-use) in cascade (#6475)
- Align 4 tests with post-#6433 main state (#6460)

## [0.5.0] - 2026-04-11

### Added
- Typed_tool_masc + State_product + TLA+ orthogonal FSM verification (#6321)
- Trust Observatory dashboard — raw signals (Phase C0) (#6359)
- B-SIM Monte Carlo verification — 4 gates pass (#6352)
- Per-decision trifecta evaluation (Phase B3) (#6346)
- Guard → Thompson bridge (Phase B1) (#6307)
- TLA+ KeeperDecisionPipeline — Phase B0 gate (#6277)
- Shared gate client + Telegram/CLI connectors (#6367)
- iMessage channel connector (#6329)
- Docker playground for keeper_bash (#6338)
- Decision Pipeline FSM diagram in keeper detail dashboard (#6405)
- masc_keeper_reset command for stale runtime state (#6428)
- rate_limit.mli — hide bucket internals behind abstract type (#6431)
- coding_first cascade profile — glm-5.1 first for PR-capable keepers (#6430)
- Voice tools for sangsu (ElevenLabs Roger) (#6247)
- Keeper Failing → recovery minimum shards + .masc/ whitelist (Phase B2) (#6325)

### Changed
- Restructure keeper.world.md and keeper.capabilities.md (#6298)
- Substitute keeper_name into world/capabilities prompts (#6316)
- Expand decision log error_category: 5 → 7 categories (#6316)
- Wire OAS Tool_retry_policy + post_tool_use_failure hook (#6324)
- Per-keeper error prevention hints in TOML instructions (#6298)
- Broadcast PoC uses Tool_schema_gen combinators (#6427)
- Remove params_to_input_schema duplicate — use OAS shared utility (#6418)
- Draining invariant doc fix to match TLA+ (#6403)
- Rename team_session → execution_session (#6364)
- Remove remaining team session surfaces (#6363)
- OAS pin bumped to v0.119.1 (#6446)
- Allow localhost cross-port browser mutations for dev dashboard (#6459)

### Fixed
- Keeper turn timeout 300s → 1200s default (env var override removed) (#6371)
- Auto-recover reconcile-safe tools on server parse errors (#6370)
- Feature flag registry: MASC_KEEPER_DOCKER_PLAYGROUND (#6365)
- Voice config empty session endpoints (#6357)
- Keeper sidecar suffix check for dotted names (#6408)
- Worktree basepath config resolution (#6449)
- Keeper autonomous stall — raise turn budget, classify shell read-only (#6371)
- 50 additional bug fixes across keeper, dashboard, and infrastructure

## [0.3.0] - 2026-04-09

### Added
- Startup TOML cross-validation for tool registration (#6093)
- Keeper cascade config API + dashboard selector + TOML hot-reload (#6100)
- MASC store diagnosis cards in telemetry view (#6105)
- OAS runtime diagnosis surfaces (#6061)
- Prompt fingerprint telemetry (#6075)
- Keeper PR history tracking + active worktree listing in dashboard (#6083)
- Keeper playground state cache + dashboard panel (#6060)
- Dashboard OAS worker observability enrichment (#6071)
- Fleet telemetry panel improvements (#6104)
- Governance HITL approvals dashboard (#6098)
- Keeper TOML→JSON config SSOT resync — 20 fields (#6110)

### Changed
- **Breaking**: Renamed `keeper_shell_readonly` to `keeper_shell` across all configs, prompts, and registry (#6095)
- Centralized keeper entrypoint alias resolution (#6096)
- Simplified dashboard command surface (#6058)
- Simplified monitoring agents runtime view (#6103)
- Simplified playground status with stdlib `List.take` (#6097)
- Tool spec handler_binding required variant for type-safe dispatch (#6073)
- OAS pin bump to 120710a with Uncertain.t (#6114)
- Hardened OAS ownership boundaries (#6101)
- OAS pin SSOT and doctor checks relaxation (#6113)

### Fixed
- Discord keeper session isolation per room (#6094)
- Keeper post-commit timeout classification (#6102)
- Worker model_id hardcoded "turn-exhausted" in MaxTurnsExceeded response (#6087)
- Dashboard error prefix stripping before JSON categorization (#6057)
- Removed fake no-op Dashboard_cache.set_clock/set_sw (#6081, #6074)
- Dead OAS proof bridge panels removed from telemetry view (#6106)
- Sangsu keeper switched to local_only cascade (#6088)
- CI semantic version comparison in OAS pin check (#6111)

## [0.2.0] - 2026-04-09

### Changed
- Release SemVer restarts at `0.y.z` to reflect that `masc-mcp` is still pre-1.0.
- Release-train automation now compares tags within the active major series, so frozen legacy `v2.*` tags do not block the new `0.x` line.
- Front-door docs, release policy, and issue templates now point at `v0.2.0` as the active package version.
- The reset starts at `0.2.0` because historical `v0.1.0` and `v0.1.1` tags already exist in the repo.

### Deprecated
- New `v2.*` release tags. Historical `v2.87.0` through `v2.263.0` remain immutable legacy references.

## [2.263.0] - 2026-04-09

### Added
- OAS exit_condition plumbing — boring gate exits Agent.run early after 8+ idle turns (#5988)
- Configurable boring exit threshold via Runtime_params (#5997)
- Tool schemas for autonomy pipeline: keeper_pr_submit, keeper_preflight_check, keeper_pr_review_* (#5996)
- Keeper read-only tool classification with Tool_dispatch mirroring (#5983)
- Retry-safe tool metadata — board tools registered with Mod_inline + idempotent flags (#5973)
- Self-repo --base-path guard — rejects runtime state in source repo (#5992)

### Changed
- Adaptive OAS timeout — context-based (180s + 1.5s/1K tokens), max_turns 200→5 (#5987)
- GLM cascade simplified — removed redundant glm:glm-5-turbo, OAS glm:auto handles expansion (#5985)
- Time constants extracted to Masc_time_constants SSOT module (#5993)
- Network defaults centralized — SearXNG, OTel, allowed_origins (#5994)
- Output cap and min context constants deduplicated (#5995)

### Fixed
- Dashboard null-status crash — assoc_member wrapper tolerates null nested JSON (#5985)
- Keeper ambiguous-partial-commit reclassification for read-only tools (#5983, #5973)
- OAS cascade model timeout derived from keeper OAS budget (#5985)
- Cheolsu keeper set to ollama-only for slot queuing test (#5986)
- TLA+ spec: separated timeout from fairness, use Filename.concat (#5979)
- Version truth sync across ROADMAP, SPEC-INDEX, PRODUCT-OPERATING-PLAN (#5982)
- OAS pin updated to 0.117.0 (#5981)

## [2.262.0] - 2026-04-09

### Added
- Genuine HITL approval pipeline — Eio.Promise fiber suspension, MCP approval tools (#5907 Phase 1, #5955)
- Graduated boring-turn guard — 5-level tool_choice escalation to cut idle token waste (#5968)
- OAS pin drift doctor — local switch validation in Makefile build/test targets (#5958)
- Spawn stderr capture + cloexec pipes — child process observability and hang prevention (#5960)
- Approval audit log — persistent JSONL records for pending/resolved/expired events (#5969)
- Git clone sandboxing in keeper_shell (#5930)

### Fixed
- Ollama thinking mode disabled for keepers — unblocked all keeper timeouts (#5948)
- ToolResult.json field drift — aligned with OAS 0.116.1 (#5948)
- Hardcoded port 8085 removal — env-driven LLM endpoint discovery (#5962)
- Keeper name and MCP prefix boundary resolution (#5967)
- Dashboard null-agent patch guard (#5971)
- GLM-5-turbo cascade fallback for outage resilience (#5956)
- Read path validation with bounded suffix resolution and symlink escape prevention (#5930)
- Approval queue fiber cancellation cleanup — no orphan entries (#5955)

### Changed
- Named constants for model context thresholds (64k/200k) replacing magic numbers (#5969)
- Governance risk patterns documented in-code for mandatory review (#5969)

## [2.261.0] - 2026-04-08

### Added
- Per-keeper provider filter via `allowed_providers` config (#5831)
- Preset-aware task routing — keepers only claim tasks matching their preset (#5820)
- 11-state keeper phase diagram in dashboard (#5829)
- Excuse patterns editor UI with server-side validation (#5818)
- Output validation stats in tool-quality dashboard (#5832)
- Dashboard SSE `keeper_tool_skipped` event + centralized thresholds (#5824)
- Deterministic tool output validation (Samchon-style schema constraints) (#5821)
- Analyst persona (verification-driven) (#5850)

### Fixed
- Comprehensive Eio.Cancel.Cancelled guard sweep — 72 files, 129 patterns (#5842)
- Cancelled guard rollback for 3 cleanup sites (fd close before re-raise) (#5848)
- AllowList pruning WARN + agent JSON race condition (atomic write) (#5840)
- Defensive lowercase + warn log in filter_by_providers (#5846)
- Policy preset name validation at load time (#5787)
- Cluster-aware telemetry read path (#5828)
- Chevron discoverability (opacity-40 default) (#5837)

### Changed
- Board_listener removed — filesystem-first, PG relay redundant (#5809)
- Heuristic metadata matching replaced with deterministic Tool_dispatch sets (#5830)
- DRY `lower_string_list_opt` helper for allowed_providers parsing (#5844)
- Transport status reports canonical HTTP protocol (#5833)

### Docs
- Gate-Connector Protocol RFC: fail-closed, shorter URL TTL, replay protection (#5805)

## [2.260.0] - 2026-04-08

### Fixed
- Eio.Cancel.Cancelled re-raised instead of swallowed in bridge, dashboard, and metrics modules (#5810)
- truncate_tool_output now enforces hard cap on total output length (#5814)
- autonomous_turn_limit default set to 1 for single-slot servers (#5806)
- Yojson.Json_error catch narrowed in dashboard tool-quality (#5812)
- Branch-switch guard hardened with tab tokenization, global git options, and precise mutation detection (#5813)
- useEffect void prefix for floating promise lint (#5816)

### Changed
- Board votes now use stable post content hash instead of monotonic counter (#5817)
- K2K preset routing refined with forbidden_tools and improved score penalty (#5819)
- Deterministic read-only boundary enforcement for shell/gh tools (#5822)
 
