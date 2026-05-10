# RFC-0063 — Telemetry Feedback Loop & Cooperative Scheduling Safety

- **Status**: Draft
- **Author**: vincent (yousleepwhen)
- **Created**: 2026-05-11
- **Postmortem reference**: PR #14491 (introduce) → PR #14499 (fix) → PR #14503 (release bump)
- **Related**: RFC-0029 (dashboard fiber-batched aggregation), RFC-0042 (typed terminal codes), RFC-0013 (iowait sampler), RFC-0001 (det/nondet boundary harness)

## 1. Problem

PR #14491 (`feat(keeper): wire OAS telemetry into provider health, livelock gate, and supervisor`, merged 2026-05-10 14:34Z) introduced the OAS-side telemetry feedback loop without a tracking RFC. The PR body cited `RFC-WAIVED: telemetry feedback loop is new cross-repo concern, no prior RFC exists.` and pointed to `docs/design/telemetry-feedback-loop-architecture.md` as the design substitute.

Two retroactive findings from origin/main on 2026-05-11:

1. **The cited design doc does not exist**. `git ls-tree origin/main docs/design/` shows no `telemetry-feedback-loop-architecture.md`. The PR template's RFC-WAIVED escape hatch was satisfied by a path that nobody verified.
2. **A cooperative-scheduling regression slipped through.** The new `Keeper_telemetry_consumer.spawn_subscriber` drain fiber called the non-blocking `Agent_sdk_metrics_bridge.drain` and recursed without `Eio.Time.sleep` / `Eio.Fiber.yield`. On a quiet bus the fiber pinned a single Eio domain at ~100% CPU, starving every co-located fiber. Server boot stalled at `lazy_task: starting restore_sessions`; `/health` timed out; HTTP handlers accepted connections but never responded.

This RFC has two purposes:

- Retroactively document the telemetry feedback loop architecture that #14491 actually shipped.
- Codify the **cooperative-scheduling safety contract** that #14491 violated and #14499 restored, so the next drain loop cannot reintroduce the same hang shape.

## 2. Postmortem timeline

| Time (KST) | Event | Artifact |
|------------|-------|----------|
| 2026-05-10 23:34 | #14491 merged: telemetry consumer wired without yield | `a2e34b63d4` |
| 2026-05-11 00:19 | User boot — server hangs at `lazy_task: starting restore_sessions`; CPU 99%, `/health` 3s timeout, ports LISTEN | PID 22289 sample |
| 2026-05-11 00:33 | #14499 merged: `Eio.Time.sleep clock 0.1` added between drains | `93489c1d2e` |
| 2026-05-11 00:34 | Restart on fix binary — `phase=ready`, `pending_lazy_tasks=[]`, CPU 8.4%, `/health` 200 | PID 1657 |
| 2026-05-11 00:44 | #14503 merged: 0.19.16 → 0.19.17 + CHANGELOG entry | `f3737b9815` |

Total wall clock from regression to recovery: **~14 minutes after user discovery**.

Diagnostic decisive moment: `sample 22289 2 -mayDie` showed the hot stack as `Keeper_telemetry_consumer.loop → Agent_sdk_metrics_bridge.drain → Eio.Stream.take_nonblocking → caml_ml_mutex_lock/unlock`, ruling out `restore_sessions` (the last log line) as the cause. *Last log ≠ stuck location* under cooperative scheduling.

## 3. Goal

1. Document the telemetry feedback loop's actual data flow, ownership, and back-pressure boundaries — what #14491 wired and what it implies for operators.
2. Establish a **drain-loop yield contract** for every Eio fiber that consumes a non-blocking primitive.
3. Surface enforcement options (lint hook, TLA+ Bug Model, sibling-pattern check) and pick a minimum viable enforcement.

## 4. Non-goals

- Rewriting the telemetry pipeline. #14491's wiring is correct apart from the missing yield, which #14499 already addressed.
- Mandating a uniform drain interval. Different consumers have legitimately different cadence needs (compact_audit batches per minute, telemetry consumer needs ~100ms responsiveness for EWMA freshness).
- Promoting cooperative-scheduling rules across all OCaml/Eio code in the repo. This RFC scopes the contract to *drain loops over non-blocking primitives*, where the failure mode is most acute.

## 5. Telemetry feedback loop architecture (as shipped by #14491)

```
OAS turn execution
   │
   ▼
Agent_sdk.Event_bus  (bounded Eio.Stream, default depth 256)
   │
   │  Custom("telemetry_event", json) payloads
   ▼
Agent_sdk_metrics_bridge   ── start_sampler ──▶ Prometheus depth gauge
   │
   │  bounded subscription per consumer
   ▼
Keeper_telemetry_consumer  ──▶ Keeper_provider_health  (per-(provider, model) EWMA)
                            │
                            ├─▶ livelock gate     (turn admission veto)
                            └─▶ supervisor signal (cascade rotation)
```

Wiring sites on `origin/main` (post-#14503):

- `lib/server/server_bootstrap_loops.ml:317` — `Keeper_compact_audit.spawn_subscriber ~sw ~clock ~base_path ~retention_days:14 event_bus`
- `lib/server/server_bootstrap_loops.ml:324` — `Keeper_telemetry_consumer.spawn_subscriber ~sw ~clock ~bus:event_bus` (clock argument added by #14499)
- `lib/keeper/keeper_telemetry_consumer.ml:18-66` — drain fiber forked under the caller's switch, sleeps `drain_interval_s = 0.1` between iterations.

Bounded back-pressure: each subscription has its own bounded stream (default depth 256). Slow consumers cause depth ramps that the depth gauge surfaces; depth saturation does not block the publisher (publish is non-blocking with drop-on-full semantics).

## 6. Cooperative scheduling safety contract

### 6.1 Rule

> Every Eio fiber whose loop body is dominated by **non-blocking primitives** (`Eio.Stream.take_nonblocking`, `Agent_sdk_metrics_bridge.drain`, `Queue.take_opt`, etc.) MUST yield before recursing — either by `Eio.Time.sleep clock <interval>`, `Eio.Fiber.yield ()`, or a blocking IO call within the iteration.

### 6.2 Why

Eio's scheduler is cooperative and currently single-threaded per domain. A fiber that never yields starves every co-located fiber on the same domain — including HTTP handlers, lazy startup tasks, and other consumer fibers — even though the OS thread is fully occupied. The starvation is invisible to TCP listen state and to `gh pr checks` style verification; the symptom only surfaces under low-traffic conditions where the non-blocking primitive returns empty.

### 6.3 Coverage on origin/main (verified 2026-05-11 by lint #14511)

The `let rec loop` drain-fiber pattern that motivated this RFC appears at four sites; the lint introduced by PR #14511 sweeps a broader 11 files that mention non-blocking drain primitives, all of which currently obey the contract.

#### Drain-fiber loop sites (the regression class)

| Site | Yield | Pattern |
|------|-------|---------|
| `cascade/cascade_event_bridge.ml:1170` | `Eio.Time.sleep clock interval_s` | env-tunable interval |
| `keeper/keeper_compact_audit.ml:432` | `Eio.Time.sleep clock drain_interval_s` | env-tunable interval |
| `server/server_bootstrap_loops.ml:391` | `Eio.Time.sleep clock keeper_listener_retry_interval_sec` | env-tunable interval |
| `keeper/keeper_telemetry_consumer.ml:67` | `Eio.Time.sleep clock drain_interval_s` (#14499) | hardcoded 0.1s |

#### Lint baseline (file-level, includes single-shot drain callers)

The lint script `scripts/ci/check-drain-loop-yields.sh` walks every `.ml` under `lib/` that calls a non-blocking drain (`Agent_sdk_metrics_bridge.drain`, `Agent_sdk.Event_bus.drain`, `Eio.Stream.take_nonblocking`) and verifies the same file contains a yield primitive. Eleven files are in scope:

```
lib/agent_sdk_metrics_bridge.ml         lib/keeper/keeper_compact_audit.ml
lib/cascade/cascade_event_bridge.ml     lib/keeper/keeper_telemetry_consumer.ml
lib/keeper/keeper_unified_turn.ml       lib/server/server_bootstrap_loops.ml
lib/metrics_store_eio.ml                lib/session.ml
lib/pulse/pulse.ml                      lib/sse.ml
lib/tool_metrics_persist.ml
```

11/11 PASS at the time of this revision. The seven sites beyond the four loop-fibers above are single-shot drain callers (cleanup paths, one-off flushes) — they are not the regression class but the file-level lint covers them defensively.

The contract retroactively explains why the four loop-fiber sites already had the sleep: the same shape was discovered earlier and patched site-by-site without naming the contract.

## 7. Enforcement options (ranked by cost / coverage)

| Option | Cost | Coverage | Notes |
|--------|------|----------|-------|
| **A. Sibling pattern grep on PR review** | very low | partial | Reviewer greps for `Agent_sdk_metrics_bridge.drain` / `take_nonblocking` and checks each call site has a sleep within the same `let rec loop` body. Already implicit; just promotes to a checklist item. |
| **B. ocaml-lint or custom dune rule** | medium | high | AST-level rule: any `let rec f ... = ... ; f ()` whose body contains a `take_nonblocking` or `drain` call but no `sleep` / `yield` / blocking IO is rejected. Implementation cost: one merlin-style traversal. |
| **C. TLA+ Bug Model** (per `software-development.md` §TLA+ Bug Model) | high | precise | Model the consumer fiber + bounded queue + scheduler as a TLA+ spec. `BugAction` = recurse without yield. `SafetyInvariant` = co-located fibers receive turns within bounded steps. Ships with `*-buggy.cfg` that must violate. Strongest correctness statement; cost matches RFC-0042 / KeeperOASAdvanced precedent. |
| **D. Test harness probe** | low | partial | New alcotest case: spawn the subscriber under a `Eio_mock.Clock`, advance N ticks, assert that a co-located fiber received at least one turn. Catches the regression but only for sites that adopt the test pattern. |

**This RFC originally recommended A + D as the minimum viable enforcement.** During implementation B and C were also delivered (see §8); A is now redundant and explicitly deferred — the automated layers cover the cases a process checklist would catch.

## 8. Implementation status

- §5 (architecture documentation): **this RFC**.
- §6 (yield contract for telemetry consumer): merged in #14499 (`93489c1d2e`).
- §7-A (PR review checklist): **deferred**. B + C + D superseded the value of a manual checklist.
- §7-B (lint script `scripts/ci/check-drain-loop-yields.sh`): merged in #14511 (`92a4c8b7b2`). Wired into `.github/workflows/ci.yml` lint job; baseline 11/11 PASS.
- §7-C (TLA+ Bug Model `specs/bug-models/CooperativeDrainYield.tla`): merged in #14515 (`277aa7c25e`). Clean spec PASS (71 states, depth 23); buggy spec violates `NoStarvation` in 8 steps (TLC exit 12). Auto-discovered by `scripts/tla-check.sh`.
- §7-D (Eio test harness `test/test_keeper_telemetry_consumer.ml`): merged in #14508 (`334f79639f`). Wall-clock 0.105s on fix code; regression detected as hang via CI cutoff.
- Release: 0.19.17 (`f3737b9815`) carries the fix.

## 9. Open questions

1. Should `drain_interval_s` in the telemetry consumer become env-tunable (matching siblings) or stay hardcoded? 100ms is small enough that EWMA latency is unaffected; making it tunable adds a knob without an obvious knob owner. *Tentative: stay hardcoded; revisit if a fleet >50 keepers shows depth gauge ramps.*
2. Should the RFC-WAIVED escape hatch require **proof of design-doc existence** (CI hook on PR body grep)? This regression's root cause is partly that nobody verified the cited path. Out of scope for this RFC; candidate follow-up to `instructions/workflow-pr.md`.
3. Are there other "ghost design docs" cited by RFC-WAIVED PRs in the last 90 days? Quick audit candidate.

## 10. References

- PR #14491 — telemetry feedback loop wiring (regression source)
- PR #14499 — yield fix (this contract's first compliance)
- PR #14503 — 0.19.17 release bump
- `lib/keeper/keeper_telemetry_consumer.ml` — current implementation
- `software-development.md` §AI 코드 생성 안티패턴 #4 (FSM Sparse Match), §TLA+ Bug Model 패턴
- Memory: `feedback_eio_drain_loop_must_yield`, `feedback_workdir_grep_must_cross_check_origin_main`, `feedback_rfc_number_reservation_needed`
