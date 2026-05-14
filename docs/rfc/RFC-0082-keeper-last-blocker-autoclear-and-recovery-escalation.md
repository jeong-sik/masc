---
rfc: RFC-0082
title: Keeper `last_blocker` auto-clear + cascade recovery escalation
author: jeong-sik (with Claude Opus 4.7)
created: 2026-05-14
status: Draft
supersedes: —
related:
  - RFC-0038 §4 problem 3 (operator_disposition ↔ paused desync — noted but unresolved)
  - RFC-0039 (Keeper FSM Streaming Escape — calls for separate recovery escalation RFC; this is it)
  - RFC-0042 (Keeper terminal code closed-sum — `cascade_exhausted` migration incomplete)
  - RFC-0026 (Work-Conserving Keeper Admission — admission layer retired, no replacement)
---

# RFC-0082: Keeper `last_blocker` auto-clear + cascade recovery escalation

## §0 Summary

When a keeper's cascade exhausts (`cascade_exhausted` terminal reason), the supervisor stamps `keeper_meta.runtime.last_blocker = { klass: { name = "cascade_exhausted"; reason = "no_providers_available" }; detail = ... }`. There is **no code path** that clears this latch when providers later become available. The dashboard reads `last_blocker` for the "일시정지 / 런타임 차단" UI affordance, perpetuating the *appearance* of a paused keeper even when `paused = false`. Combined with the absence of a runtime endpoint behind the dashboard's *OVERRIDE* buttons and the append-only `last_proactive_preview` field, the keeper is *structurally unable to self-recover*.

This RFC proposes:

- **(A) `last_blocker` auto-clear hook** on next successful cascade attempt;
- **(B) diagnostic probe turn** that bypasses `last_blocker` gate without counting toward budget — used by supervisor to re-evaluate cascade health periodically;
- **(C) dashboard admin endpoint** — implement the runtime API the *OVERRIDE* buttons already promise on the surface;
- **(D) `last_proactive_preview` unconditional update on new autonomy cycle** — kill the display latch;
- **(E) RFC-0042 closure** for `cascade_exhausted` — wire format still string, gating logic still `String.equal`, typed closed-sum migration incomplete.

A new TLA+ spec `tla+/KeeperLastBlockerLatch.tla` accompanies this RFC and proves the `LastBlockerEventuallyCleared` liveness invariant against an explicit `BugLastBlockerSticky` bug action (per CLAUDE.md §"TLA+ Bug Model").

## §1 Problem (verified evidence)

### §1.1 Production state, masc-improver, 2026-05-14

`~/me/.masc/keepers/masc-improver.json`:

```json
{
  "paused": false,
  "last_blocker": {
    "klass": {
      "name": "cascade_exhausted",
      "reason": "no_providers_available"
    },
    "detail": "Internal error: [masc_oas_error] {\"kind\":\"cascade_exhausted\",\"cascade_name\":\"strict_tool_candidates\",\"reason\":\"no_providers_available\"}"
  },
  "last_proactive_preview": "[turn budget exhausted: 10/10 turns used]",
  "total_turns": 685,
  "generation": 0,
  "trace_id": "trace-1776871892035-b93f2"
}
```

Most recent receipt (`execution-receipts/2026-05/14.jsonl`):

```json
{
  "outcome": "receipt_failed",
  "terminal_reason_code": "cascade_exhausted",
  "operator_disposition": "alert_exhausted",
  "operator_disposition_reason": "cascade_exhausted",
  "cascade_profile": "tier.ollama_cloud_primary",
  "provider": null,
  "model": null,
  "generation": 0
}
```

Receipt produced 2026-05-14T00:00:42Z. At time of this RFC (~21h later), keeper is still listed as *Fleet stale 배치 / 런타임 차단 / stale_fleet_batch(distinct_count=6)* in the dashboard.

### §1.2 The 3-axis investigation

Three independent code-path investigations were run in parallel (read-only, no production change). Findings:

#### Axis A — Generation lifecycle (HYPOTHESIS REJECTED)

`grep -nA20 "generation = meta.runtime.generation + 1" lib/keeper/` → **single** site: `lib/keeper/keeper_heartbeat_loop.ml` inside an *identity drift repair* block (`trace_id` change). Every other reference is comparison/initialisation/JSON parse. **`generation` is an identity-reset counter, not a lifecycle phase counter.** `total_turns: 685` with `generation: 0` is *correct behavior under current design* — the keeper has had a single trace identity throughout.

This rules out the "generation never advances → budget never resets" hypothesis some downstream tooling (including this author's earlier informal triage) suggested.

#### Axis B — Turn budget reset (PARTIALLY THE CAUSE)

Default budget `10` defined in `lib/keeper/keeper_runtime_resolved.ml:58-66` (`autonomous_max_turns_per_call_live`). Cascade runner enforces it per-call at `lib/cascade/cascade_runner.ml:585-595` and *resets* per-call — there is no inter-call budget state on the runner side.

The display string `"[turn budget exhausted: 10/10 turns used]"` lives in `keeper_meta.last_proactive_preview`. Update is conditional in `lib/keeper/keeper_unified_metrics.ml:1316-1323` — *only when the next cycle produces new text*. If subsequent cycles fail at cascade selection (no provider dispatched, no response text), the field stays frozen on the first exhausted message — a **display latch**, not the actual block.

The dashboard "예약 자율 10 OVERRIDE" button has no runtime endpoint: `rg -n "override.*budget\|set.*proactive" lib/dashboard/` → 0 hits. Operator cannot unblock via UI.

#### Axis C — Receipt failure → next-turn block (THE STRUCTURAL CAUSE)

The decision-grade block is **`last_blocker`**, not `paused`. The stamp path:

1. Cascade exhausts → `receipt.terminal_reason_code = "cascade_exhausted"` (string; RFC-0042 typed-variant migration incomplete — wire format unchanged).
2. `lib/keeper/keeper_execution_receipt.ml:475` derives `operator_disposition = "alert_exhausted"` by `String.equal`.
3. `lib/keeper/keeper_supervisor.ml:1485` stamps `keeper_meta.runtime.last_blocker` with `klass = Stale_fleet_batch` (when ≥6 keepers fleet-wide) or `klass = Cascade_exhausted` (single keeper).
4. Dashboard renders `last_blocker` as "일시정지 / 런타임 차단 / stale_fleet_batch(distinct_count=6)".
5. **No code path clears `last_blocker`** even on next successful cascade attempt. `rg -n "last_blocker = None\|reset_last_blocker\|clear_blocker" lib/keeper/` confirms.

`auto_resume` (`lib/keeper/keeper_supervisor.ml:2026-2069`) is gated on `meta.paused = true`, which is *separate state*. Since `paused = false`, `auto_resume` is not even attempted — but the *appearance* of stuck persists because the dashboard surfaces `last_blocker`.

### §1.3 Why this matters

In a fleet of 18 keepers, 6 became stuck (`distinct_count=6` in `stale_fleet_batch`) on the same cascade exhaustion. The 6-count threshold escalates from per-keeper to fleet-level pause, multiplying the operational impact. Manual recovery — `~/me/.masc/keepers/<keeper>.json` direct edit, server restart — is the only current mechanism, and it's not scriptable through the documented surface.

## §2 Goals / Non-goals

### Goals

- Make `last_blocker` self-clearing under recovery conditions, so a keeper whose provider returns to health *resumes without operator intervention*.
- Provide a *bounded* diagnostic mechanism for the supervisor to test cascade health without exhausting budget on each attempt.
- Wire up the dashboard's *OVERRIDE* buttons to a real endpoint so operator-side recovery is one click, not a JSON edit.
- Kill the `last_proactive_preview` display latch.
- Close RFC-0042 for `cascade_exhausted` (typed closed-sum migration end-to-end).

### Non-goals

- Provider health probe redesign — that is upstream of this RFC and stays in `lib/keeper/keeper_health_probe.ml`. This RFC only touches the *consumption* of probe results.
- Cascade strategy redesign (`tier-group.*` member selection) — out of scope.
- Generation lifecycle redesign — generation semantics ("identity reset counter") are correct; this RFC does not propose renaming or repurposing.

## §3 Design

### §3.1 `last_blocker` typed lifecycle

```ocaml
(* lib/keeper/keeper_blocker_lifecycle.ml — new *)
type clear_reason =
  | Cascade_recovered of { cascade_name : string; attempt_count : int }
  | Provider_returned of { provider : string }
  | Operator_cleared of { operator : string; ts : float }
  | Diagnostic_probe_success
  [@@deriving yojson, show]

val clear : keeper_meta -> reason:clear_reason -> keeper_meta
(* Returns a meta with [last_blocker = None] and an audit trail entry.
   Idempotent — clearing an already-clear meta is a no-op. *)
```

Caller obligations: `Cascade_runner.run` *must* call `clear ~reason:(Cascade_recovered _)` on every successful cascade completion. `Operator_admin.clear_last_blocker` (new endpoint) calls with `Operator_cleared _`. The supervisor's diagnostic probe path calls with `Diagnostic_probe_success`.

### §3.2 Diagnostic probe turn

The supervisor periodically (default: 5 min, env `MASC_KEEPER_DIAGNOSTIC_PROBE_INTERVAL_SEC`) issues a *probe turn* for any keeper with a non-empty `last_blocker.klass = Cascade_exhausted`:

- Probe bypasses `last_blocker` gate (single-shot, gated on `is_diagnostic_probe`).
- Probe does *not* count against `autonomous_max_turns_per_call_*` or any visible budget — it is a separate counter `diagnostic_probe_count` with its own ceiling (default 12/hour).
- Probe payload is a no-op tool call (`keeper_time_now`) — minimal latency, no side effect.
- Outcome:
  - Success → `Keeper_blocker_lifecycle.clear ~reason:Diagnostic_probe_success`.
  - Failure → `last_blocker` reason updated with most-recent timestamp; probe counter increments.
- Probe is **structurally distinct** from autonomy/reactive/mention turns at the dispatch layer to prevent it from being conflated with regular budget accounting.

### §3.3 Dashboard admin endpoint

`POST /api/v1/admin/keepers/{name}/clear-blocker`:

- Body: `{ "operator": "<identifier>", "reason": "<freetext>" }`
- Auth: existing admin auth (`lib/server/server_admin_auth.ml`); falls back to `MASC_ADMIN_TOKEN` env.
- Effect: invokes `Keeper_blocker_lifecycle.clear ~reason:(Operator_cleared _)` and emits an audit row.
- Dashboard *OVERRIDE* buttons (currently dead UI) wire here.

### §3.4 `last_proactive_preview` unconditional update

`lib/keeper/keeper_unified_metrics.ml:1316-1323` changes from:

```ocaml
(* current: update only when result.response_text is non-empty *)
if String.length result.response_text > 0
then meta_with_preview meta ~preview:result.response_text
else meta
```

to:

```ocaml
(* proposed: update unconditionally per cycle.  An empty/cascade-failed
   cycle produces an explicit "[autonomy cycle started · no response]"
   marker so the latched "exhausted" message cannot survive past the
   cycle in which it was generated. *)
let preview =
  if String.length result.response_text > 0
  then result.response_text
  else "[autonomy cycle " ^ string_of_int meta.autonomous_turn_count ^ " · no response]"
in
meta_with_preview meta ~preview
```

Trade-off: the field becomes "noisier" — every cycle leaves a marker. Mitigation: the dashboard's "최근 활동" surface should display the *last non-empty* preview when the latest is the no-response marker. Or accept the marker as honest signal that the cycle ran and produced nothing.

### §3.5 RFC-0042 closure for `cascade_exhausted`

`lib/keeper/keeper_execution_receipt.ml:475` currently:

```ocaml
if String.equal terminal_reason "cascade_exhausted"
then "alert_exhausted"
else ...
```

Migrate to:

```ocaml
match (terminal_reason_code : Keeper_turn_terminal_code.t) with
| Cascade_exhausted _ -> "alert_exhausted"
| ...
```

`Keeper_turn_terminal_code.t` already exists (`lib/keeper/keeper_turn_terminal_code.ml:35,56`). The blocker is the *producer* in `keeper_turn_driver.ml:1103-1118` which still emits the string. Convert producer + consumer in same PR (RFC-0042 §"N-of-M migration" anti-pattern explicitly forbids leaving partial sites).

## §4 Implementation phasing

Each phase ≤ 600 LOC, independently revertable, build-green-at-every-PR.

| Phase | Files | Diff target | Risk | Rollback |
|---|---|---|---|---|
| **0** (this PR) | `docs/rfc/RFC-0082-*.md`, `tla+/KeeperLastBlockerLatch.tla` + `.cfg`s | docs+spec only | none | revert PR |
| **1** | `lib/keeper/keeper_blocker_lifecycle.ml{,i}` + caller in `lib/cascade/cascade_runner.ml` (one site) | ~200 LOC | low | env flag `MASC_KEEPER_BLOCKER_AUTOCLEAR=0` |
| **2** | Supervisor diagnostic probe: `lib/keeper/keeper_supervisor.ml` + new `keeper_diagnostic_probe.ml` | ~350 LOC | medium (new scheduler edge) | env flag + canary |
| **3** | Admin endpoint: `lib/server/server_admin_keeper_api.ml` + dashboard wiring | ~250 LOC | low | revert PR |
| **4** | `last_proactive_preview` unconditional update + dashboard "최근 활동" fallback | ~150 LOC | low | env flag |
| **5** | RFC-0042 `cascade_exhausted` typed closure: `keeper_execution_receipt.ml` + `keeper_turn_driver.ml` | ~200 LOC | medium (wire format coordination) | revert PR |

Phase 1 lands first because it is the load-bearing change (one keeper attempting recovery should *succeed*). Phases 2-4 build on Phase 1. Phase 5 is the cleanup.

## §5 TLA+ verification (Bug Model)

`tla+/KeeperLastBlockerLatch.tla` — composition with existing `RFC0061CacheInvalidationBroadcast`, `DiscoveryCacheTTL`, and `KeeperOASAdvanced` specs.

**State vars**:

- `last_blocker ∈ {None, Some(Cascade_exhausted), Some(Stale_fleet_batch), Some(Other)}`
- `cascade_status ∈ {Healthy, Unhealthy, Unknown}`
- `pending_probe ∈ BOOLEAN`
- `paused ∈ BOOLEAN` (separate latch, for cross-axis composition)

**Safety invariants**:

- `BlockerAndPausedAreIndependent`: `last_blocker ≠ None ⇒ ¬paused` is *not* required; the two latches can co-exist (matches production state).
- `ProbeBypassesBlocker`: when `pending_probe = TRUE`, turn dispatch ignores `last_blocker`.

**Liveness invariants** (the load-bearing claim):

- `LastBlockerEventuallyCleared`: `□◇(cascade_status = Healthy ⇒ last_blocker = None)` — once cascade recovers, the blocker clears within finite steps.
- `NoRecoveryDeadlock`: there is no state `s` where `last_blocker ≠ None ∧ cascade_status = Unknown ∧ pending_probe = FALSE ∧ ∀ next state s': same as s`.

**Bug actions** (per CLAUDE.md §"TLA+ Bug Model"):

- `BugLastBlockerSticky`: `last_blocker` never assigned `None` from a non-`None` state.
- `BugProbeRespectsBlocker`: probe path checks `last_blocker` before dispatch (i.e. probe is gated on the same field it's supposed to test — circular).
- `BugDashboardOverridesIneffective`: dashboard *OVERRIDE* button sets `last_blocker` to `None` but supervisor's next stamp re-applies it (mismatch between sources of truth).

**Verification claim**: TLC must show `Clean.cfg` passes both safety and liveness invariants and `Buggy.cfg` (with one bug action enabled at a time) violates the matched invariant in ≤ 8 states.

## §6 Tier 1 immediate unblock (out of band — operator action)

This RFC is the *root-fix*. To unstick masc-improver *today* (before Phase 1 ships) the operator has three options:

1. **Server stop + JSON edit + restart**:
   ```bash
   # Identify masc-mcp main_eio process
   lsof -nP -i :8935 | rg LISTEN
   # Stop server (SIGTERM)
   kill $(lsof -nP -i :8935 | rg LISTEN | awk '{print $2}')
   # Backup + clear blocker
   cp ~/me/.masc/keepers/masc-improver.json ~/me/.masc/_backups/masc-improver-$(date +%Y%m%d-%H%M%S).json
   jq '.last_blocker = null | .last_proactive_preview = ""' \
     ~/me/.masc/keepers/masc-improver.json > ~/me/.masc/keepers/masc-improver.json.tmp
   mv ~/me/.masc/keepers/masc-improver.json.tmp ~/me/.masc/keepers/masc-improver.json
   # Restart server (operator-specific command)
   ```
2. **Wait for Phase 3 (admin endpoint)** and use the dashboard *OVERRIDE* button.
3. **Cascade-side fix**: ensure `claude_code.claude-auto.tool_candidate` and `kimi_cli.kimi-cli-coding.tool_candidate` are healthy (CLI binaries installed, credentials valid). Then a successful turn will clear `last_blocker` automatically *once Phase 1 ships*. Until then, even a healthy cascade leaves the latch.

## §7 Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Phase 2 probe turn introduces hidden budget consumption (regression to budget-exhausted) | Medium | Medium | Strict separation in dispatch layer; new counter `diagnostic_probe_count` with independent ceiling |
| Phase 4 unconditional preview update spams dashboard "최근 활동" with no-response markers | Medium | Low | Dashboard renderer prefers last non-empty preview; markers are honest |
| Phase 5 RFC-0042 string-to-typed migration leaves wire-format readers on stale path | Low | Medium | Same PR converts producer and consumer; CI lint blocks reintroduction |
| `BugDashboardOverridesIneffective` bug action turns out to model real present behavior | Medium | Medium | Phase 3 endpoint is the single source of truth for operator clears; supervisor reads endpoint-emitted audit and respects it |

## §8 Open questions

1. Probe payload — `keeper_time_now` is no-op; should it be a *real* cascade attempt to a known-cheap model instead, so probe outcome reflects cascade routing not just network? *Tentative*: cheap real attempt, with separate `probe_max_tokens = 1` budget guard.
2. Probe interval — 5 min default. Per-keeper override via toml? *Tentative*: yes, `keeper.diagnostic_probe_interval_sec` in `~/.masc/config/keepers/<name>.toml`.
3. Should `last_blocker` carry a `cleared_at` history rather than a single `None`? — *Tentative*: yes, for audit; new field `last_blocker_history : (timestamp × clear_reason) list` capped at 16 entries.

## §9 Stop conditions

- Phase 1 canary: if `last_blocker` is cleared but a *new* cascade_exhausted re-stamps within 60 s, abort and re-investigate (suggests cascade health probe itself is broken, RFC-out-of-scope).
- TLC verification: if `Clean.cfg` cannot prove `LastBlockerEventuallyCleared` within 30 min wall clock, the composition model is wrong — split specs.

## §10 Migration completion criteria

- `rg -n "last_blocker = .*None\|reset_last_blocker\|clear_blocker" lib/keeper/` returns the new lifecycle calls.
- A keeper whose cascade recovers within 5 min after exhaustion automatically resumes without operator action.
- Dashboard *OVERRIDE* buttons trigger an audit-logged blocker clear on the running server.
- `rg -n "String.equal terminal_reason" lib/keeper/` returns 0 hits for `cascade_exhausted`.
- TLA+ `KeeperLastBlockerLatch` spec passes Clean.cfg, fails each Buggy.cfg as intended.

## §11 References

- Production state evidence: `~/me/.masc/keepers/masc-improver.json` + `~/me/.masc/keepers/masc-improver/execution-receipts/2026-05/14.jsonl` (2026-05-14)
- Dashboard screenshots, masc-improver detail panel, 2026-05-14
- 3-axis code-path investigation, sub-agent transcripts at `/private/tmp/claude-502/-Users-dancer-me/<session>/tasks/{ad8ec8979cef72647,a2b20180f03ae2f55,a8c42e55f427f68da}.output`
- `MEMORY.md` `project_masc_mcp_fleet_idle_quartet` — 4-axis configured-but-idle pattern; this RFC addresses a 2-axis tight variant (latch + dead UI)
- CLAUDE.md §"워크어라운드 거부 기준" — telemetry-as-fix (#1) and N-of-M (#3) self-checks applied at each phase

🤖 Generated with [Claude Code](https://claude.com/claude-code) during 3-axis root-cause investigation
