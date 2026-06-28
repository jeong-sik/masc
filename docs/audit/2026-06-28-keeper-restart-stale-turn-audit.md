# Keeper restart stale-turn audit - 2026-06-28

status: draft_pr_ready
last_verified: 2026-06-28T19:43:33+09:00
runtime_window_utc: 2026-06-27T10:34:00Z..2026-06-28T10:34:00Z
runtime_root: `<RUNTIME_ROOT>`
repo_head: `92d1df5d1d4`
live_runtime_head: `0830676537f`

## Evidence

- [근거] Live health: `curl -fsS '<MASC_HTTP_BASE>/health?full=1'`, checked 2026-06-28T19:34+09:00, confidence High. Runtime reported `version=0.19.51`, `keeper_fibers=1`, `keeper_fleet_safety.status=degraded`, `blocker=low_running_fiber_margin`, running keeper `sangsu`, and multiple blocked/dead keepers with `stale_turn_timeout(idle_turn(...))`.
- [근거] 24h system-log aggregation: parsed `<RUNTIME_ROOT>/logs/system_log_2026-06-27.jsonl` and `system_log_2026-06-28.jsonl` with cutoff `2026-06-27T10:34:00Z`, checked 2026-06-28T19:36+09:00, confidence High. WARN/ERROR dominant classes included stale-turn recovery, SSE unknown sessions, empty librarian responses, prompt fallback, anti-rationalization empty approvals, and compaction manifest unknown events.
- [근거] Restart timeline: exact `rondo`, `nick0cave`, and `sangsu` log slices showed each keeper restarted, consumed `bootstrap`, then was killed by `stale_turn_timeout(idle_turn(...))` roughly one sweep later while retaining the pre-restart `last_turn_ts`; checked 2026-06-28T19:38+09:00, confidence High.
- [근거] Source trace: `lib/keeper/keeper_supervisor.ml`, `lib/keeper/keeper_registry_setup.ml`, `lib/keeper/keeper_registry.ml`, and `test/test_keeper_supervisor.ml`, checked 2026-06-28T19:43+09:00, confidence High.
- [근거] OCaml 5.4 manual: `https://ocaml.org/releases/5.4/index.html` and effect handler chapter `https://ocaml.org/releases/5.4/effects.html`, checked 2026-06-28T19:40+09:00, confidence High.
- [근거] Eio API docs: `https://ocaml-multicore.github.io/eio/eio/Eio/Switch/index.html` and `https://ocaml-multicore.github.io/eio/eio/Eio/Fiber/index.html`, checked 2026-06-28T19:39+09:00, confidence High.
- [근거] Jane Street Base README: `https://raw.githubusercontent.com/janestreet/base/master/README.org`, checked 2026-06-28T19:41+09:00, confidence Medium as a library/style signal rather than a MASC dependency rule.
- [근거] OCaml Forum Eio discussions: `https://discuss.ocaml.org/t/understanding-cancellation-in-eio/9369` and `https://discuss.ocaml.org/t/i-roughly-translated-real-world-ocamls-async-concurrency-chapter-to-eio/14548`, checked 2026-06-28T19:42+09:00, confidence Medium because they are design discussion, not normative API documentation.

## Primary Finding

P0: restarted keepers inherit old completed-turn metadata and immediately burn restart budget.

- Symptom: `rondo`, `nick0cave`, and `sangsu` all restarted successfully, then died one sweep later with `stale_turn_timeout(idle_turn(...))`; repeated attempts exhausted `max_restarts`.
- Root point: `register_restarting` creates a fresh registry entry with fresh `started_at`, but preserves `meta.runtime.usage.last_turn_ts`. `assess_stale_run` used only `last_turn_ts`, so a newly launched fiber could be classified as stale before its current supervised lifetime had exceeded the stale threshold.
- Fix in this branch: `assess_stale_run` now requires both the last completed turn and the current supervised lifetime anchor to exceed the same configured threshold. It does not mutate `last_turn_ts`, does not add a new env knob, and does not add prompt constraints.
- Code: `lib/keeper/keeper_supervisor.ml`, `lib/keeper/keeper_supervisor.mli`, `test/test_keeper_supervisor.ml`, `test/test_keeper_idle_threshold_contract.ml`.

## Runtime Findings

1. P0 restart-budget false exhaustion
   - Root: stale-run helper ignored `entry.started_at`.
   - Surface: `lib/keeper/keeper_supervisor.ml`, `lib/keeper/keeper_registry_setup.ml`.
   - Status: fixed in this branch.

2. P0 fleet reaction capacity collapse
   - Root: multiple keepers reached Dead/paused while only `sangsu` remained executable.
   - Surface: `lib/server/server_routes_http_runtime_fleet_scan.ml`.
   - Status: follow-up; fix P0 restart false-positive first.

3. P0 self-preservation suppression amplifies false cohort
   - Root: stale-turn cohort dominated restart candidates because the root stale classifier was wrong.
   - Surface: `lib/keeper/keeper_supervisor_self_preservation.ml`.
   - Status: re-evaluate after this fix is deployed.

4. P1 pending no-progress recovery for non-executable keepers
   - Root: reaction ledger can retain pending stimuli for dead/paused/no-fiber keepers.
   - Surface: `lib/keeper/keeper_reaction_ledger*`, fleet health scan.
   - Status: follow-up; do not solve by prompt constraints.

5. P1 event queue restores `bootstrap` repeatedly after restart
   - Root: restart path restores durable event queue snapshot, then launch enqueues bootstrap again.
   - Surface: `lib/keeper/keeper_registry_setup.ml`, `lib/keeper/keeper_supervisor_launch.ml`.
   - Status: follow-up with event ack/tombstone proof.

6. P1 no real turn before stale sweep after restart
   - Root: bootstrap consumption alone is not proof that the restarted keeper completed a turn.
   - Surface: `lib/keeper/keeper_supervisor_launch.ml`, keeper heartbeat loop.
   - Status: covered by lifetime gate; deeper admission proof remains follow-up.

7. P1 paused/autoboot/dead state interaction is hard to reason about
   - Root: durable pause, autoboot config, and supervisor restart recovery all contribute to bootability.
   - Surface: `lib/server/server_routes_http_runtime_fleet_scan.ml`, keeper TOML parsing.
   - Status: follow-up; keep scope per keeper.

8. P1 active task owner without executable fiber
   - Root: health reports active owner state where the registry has no matching executable keeper fiber.
   - Surface: `lib/server/server_routes_http_runtime_fleet_scan.ml`.
   - Status: follow-up; release/quarantine must be explicit.

9. P1 anti-rationalization empty text approves by liveness
   - Root: empty evaluator output can produce approval fallback.
   - Surface: `lib/task/anti_rationalization.ml`.
   - Status: follow-up; this is a silent-failure risk.

10. P1 memory librarian empty response and timeout fallback
    - Root: provider returned empty/unparseable output or timed out; global slot capacity also skipped work.
    - Surface: `lib/keeper/keeper_librarian_runtime.ml`.
    - Status: follow-up; validate against current deployed head before tuning.

11. P1 prompt SSOT fallback
    - Root: externalized prompt `keeper.turn_intent.task_create_guidance` resolved empty and binary fallback was used.
    - Surface: prompt resolver/config prompt store.
    - Status: follow-up; binary fallback is an SSOT risk if the external prompt is required.

12. P1 compaction manifest event schema drift
    - Root: dashboard reader surfaced unknown manifest events `memory_injected` / `memory_flushed`.
    - Surface: `lib/keeper/keeper_runtime_manifest.ml`, `lib/keeper_registry/keeper_runtime_manifest_types.ml`, `lib/server/server_dashboard_http_keeper_api.ml`.
    - Status: follow-up; current source appears to know these event names, so verify live binary freshness.

13. P1 source entries accept-and-ignore invalid shape
    - Root: `source_entries_arg` ignores null/non-object/non-list sources instead of rejecting caller shape.
    - Surface: `lib/board_tool_adapter/board_tool_format.ml`.
    - Status: follow-up; schema should decide whether null is valid.

14. P1 correction pipeline still invalid after deterministic fixes
    - Root: deterministic repair can exit invalid without a typed terminal reason visible in the top-level log.
    - Surface: correction pipeline modules; exact owner needs focused trace.
    - Status: follow-up.

15. P2 SSE unknown-session noise
    - Root: stale dashboard/session clients repeatedly attempted SSE registration with unknown session IDs.
    - Surface: `lib/sse.ml`, MCP/SSE transport tests.
    - Status: follow-up outside keeper restart.

16. P2 dashboard token mismatch fallback
    - Root: token mismatch fallback is frequent enough to obscure Keeper logs.
    - Surface: dashboard auth/server paths.
    - Status: follow-up outside keeper restart.

17. P2 Discord heartbeat ack timeout outside Connected state
    - Root: state machine receives ack timeout after leaving Connected; ignored by design.
    - Surface: `lib/gate/discord_gateway_state.ml`.
    - Status: monitor; not a Keeper restart root cause.

18. P2 resume directive names not in registry
    - Root: directives use agent identifiers such as `keeper-*-agent` while registry lookup expects current keeper names.
    - Surface: `lib/keeper/keeper_keepalive.ml`.
    - Status: follow-up; avoid string-name drift.

19. P2 tool/path readiness failures in keeper playground
    - Root: keeper attempted unavailable repo path or denied repository access.
    - Surface: tool repository access and playground path mapping.
    - Status: follow-up; keep path guards strict.

20. P2 path/env audit remains live risk
    - Root: health reported config subpaths from env while runtime base/root came from explicit CLI; path ownership is correct but still fragile under mixed startup surfaces.
    - Surface: config resolver and runtime health path reporting.
    - Status: follow-up; no hardcoded `<MASC_BASE_PATH>` runtime default was introduced here.

## Design Check

- OCaml 5.4/Eio: the fix is a pure decision helper and does not add long-lived blocking I/O, a new switch, an unstructured cancellation path, or a wall-clock provider/tool timeout. This matches Eio's resource ownership model: switches own resources/fibers and cancellation belongs at the right ownership boundary.
- Jane Street/Base signal: use explicit module origins and typed operations. This patch keeps `Stdlib.Float.max` explicit and extends the typed helper interface rather than hiding a defaulted optional parameter.
- OCaml Forum signal: cancellation and timeout behavior should be tied to resource/fiber ownership, not arbitrary external invalidation. The patch uses the current supervised lifetime as ownership evidence instead of force-touching metadata or adding a side-channel knob.

## Verification State

- `git diff --check`: passed.
- `ocamlformat --check lib/keeper/keeper_supervisor.ml lib/keeper/keeper_supervisor.mli test/test_keeper_supervisor.ml test/test_keeper_idle_threshold_contract.ml`: passed.
- Local Dune build: intentionally not run; CI is the requested build authority for this repo.
- Remaining proof: draft PR CI, then deploy/restart and re-run the exact stale-turn log slice for `rondo`, `nick0cave`, and `sangsu`.
