---
rfc: RFC-0082
title: Keeper `last_blocker` auto-clear + cascade recovery escalation
author: jeong-sik (with Claude Opus 4.7)
created: 2026-05-14
corrected: 2026-05-15
status: Draft (corrected — see §12)
supersedes: —
related:
  - RFC-0038 §4 problem 3 (operator_disposition ↔ paused desync — noted but unresolved)
  - RFC-0039 (Keeper FSM Streaming Escape — calls for separate recovery escalation RFC; this is it)
  - RFC-0042 (Keeper terminal code closed-sum — `cascade_exhausted` migration incomplete)
  - RFC-0026 (Work-Conserving Keeper Admission — admission layer retired, no replacement)
---

> **READ §12 FIRST.** 2026-05-15 fleet measurement falsifies the "no clear path" premise this RFC was built on. Phase 1 (auto-clear hook) is re-scoped pending stale-recovery investigation. §1.2 Axis C and §6 Tier 1 are factually amended.

# RFC-0082: Keeper `last_blocker` auto-clear + cascade recovery escalation

## §0 Summary

When a keeper's cascade exhausts (`cascade_exhausted` terminal reason), the supervisor stamps `keeper_meta.runtime.last_blocker = { klass: { name = "cascade_exhausted"; reason = "no_providers_available" }; detail = ... }`. **Six code paths** in `lib/keeper/` already assign `last_blocker = None` on normal turn-success paths (see §1.2 Axis C, corrected). They clear the latch on the *expected-path keepers* but **fail to fire on keepers exiting via `stale_*` diagnoses** (`stale_turn_timeout`, `stale_fleet_batch`), because those keepers never reach the success-path branches that hold the clears. The dashboard reads `last_blocker` for the "일시정지 / 런타임 차단" UI affordance, perpetuating the *appearance* of a paused keeper even when `paused = false`. Combined with the absence of a runtime endpoint behind the dashboard's *OVERRIDE* buttons and the append-only `last_proactive_preview` field, *some* keepers — those whose last turn died by stale diagnosis — are structurally unable to self-recover.

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
5. *(Corrected 2026-05-15)* Six code paths in `lib/keeper/` assign `last_blocker = None`:
   - `keeper_turn_up_create.ml:579` (turn creation)
   - `keeper_turn_up_update.ml:281` (turn update)
   - `keeper_unified_metrics.ml:1392` (metrics path)
   - `keeper_supervisor.ml:801` (supervisor — first path)
   - `keeper_supervisor.ml:2071` (supervisor — auto_resume cleanup)
   - `keeper_supervisor.ml:2279` (supervisor — secondary cleanup)

   The 2026-05-15 fleet measurement (server uptime 1 min → 5 min) shows `dict→null` transitions on 12/18 keepers within ~5 min, confirming these paths *do* fire on healthy turn cycles. The remaining 5 latched keepers (`glm-coding`, `imseonghan`, `janitor`, `qa-king`, `sangsu`) all carry `klass = stale_turn_timeout` or `stale_fleet_batch` — their last turn exited via stale diagnosis, which does *not* route through any of the six clear sites. The *real* defect is "stale-exit keepers skip the clear path", not "no clear path exists".

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

### §3.1 `last_blocker` typed lifecycle *(RE-SCOPED pending §12 stale-recovery investigation)*

> Adding a seventh clear site is workaround-rejection-bar pattern #3 (N-of-M) as long as the six existing clear sites are the *correct* place to fire and merely fail to be reached by stale-exit paths. The typed-lifecycle module below is still the right *target shape* — it deduplicates six scattered assignments into one — but it should be introduced *after* the stale-exit flow is traced and either (a) routed through one of the existing clear sites, or (b) shown to require a structurally new clear site that the lifecycle module then owns.


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
| **0** (this PR — merged 2026-05-14 as #15316) | `docs/rfc/RFC-0082-*.md`, `tla+/KeeperLastBlockerLatch.tla` + `.cfg`s | docs+spec only | none | revert PR |
| **0.5** *(NEW, this corrective PR)* | this RFC §1.2 / §6 / §12 corrections, no code | docs only | none | revert PR |
| **1** *(BLOCKED on Phase 0.6 below)* | ~~`lib/keeper/keeper_blocker_lifecycle.ml{,i}` + caller~~ | TBD | TBD | TBD |
| **0.6** *(NEW, prerequisite to Phase 1)* | Trace stale-exit code path — `lib/keeper/keeper_stale_watchdog.ml`, `keeper_heartbeat_loop.ml`, supervisor stale-detection branches. Output: which existing clear site (if any) the stale-exit recovery turn lands on. Investigation memo, no code change. | docs only | none | n/a |
| **2** *(deferred)* | Supervisor diagnostic probe | ~350 LOC | medium (new scheduler edge) | env flag + canary |
| **3** *(deferred)* | Admin endpoint + dashboard wiring | ~250 LOC | low | revert PR |
| **4** *(deferred)* | `last_proactive_preview` unconditional update | ~150 LOC | low | env flag |
| **5** *(deferred)* | RFC-0042 `cascade_exhausted` typed closure | ~200 LOC | medium (wire format coordination) | revert PR |

Phase 1 was originally framed as the load-bearing change. The 2026-05-15 measurement (§12) showed *most* keepers already self-clear within minutes — Phase 1 would have added a seventh clear site without diagnosing *why* the six existing sites miss the 5 stuck keepers. Phase 0.6 (stale-exit trace) is now the prerequisite: its output decides whether Phase 1 introduces a new clear site or wires one of the six existing sites into the stale-recovery path.

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

> *Corrected 2026-05-15*: option 1 below (now demoted) is heavier than it needs to be. Option 0, validated on masc-improver on 2026-05-14, is the smallest safe recovery. Option 3's "*once Phase 1 ships*" qualifier was wrong — see §12.

0. **`masc_keeper_down` + `masc_keeper_up`** (validated 2026-05-14 on masc-improver):
   ```
   masc_keeper_down  name=<keeper>
   masc_keeper_up    name=<keeper>
   ```
   Both pass governance (unlike `masc_keeper_reset` which is `risk_level=critical`). Result: `last_blocker = null`, `paused = false`, `trace_id` preserved. Server keeps running. *This is the recommended Tier 1 recovery.*
1. **Server stop + JSON edit + restart** *(legacy — only if `masc_keeper_*` is unavailable)*:
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
   Direct JSON edits while the server is running race with `main_eio` meta writes — only safe with server stopped.
2. **Wait for Phase 3 (admin endpoint)** and use the dashboard *OVERRIDE* button.
3. **Cascade-side fix**: ensure cascade `tier-group` member providers (e.g. `claude_code.claude-auto.tool_candidate`, `kimi_cli.kimi-cli-coding.tool_candidate`) are healthy (CLI binaries installed, credentials valid). If a *normal-path* turn then completes, one of the six existing clear sites (§1.2 Axis C #5) will fire. *Stale-exit* keepers still need the stale-recovery flow that Phase 0.6 must trace before Phase 1 lands.

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

## §12 Correction (2026-05-15) — falsifying measurements

This RFC was merged 2026-05-14 (#15316) with a *fleet-wide auto-clear gap* as the load-bearing premise. A re-measurement 2026-05-15 on the same fleet falsifies that premise. Honest record:

### §12.1 What was actually true at 2026-05-14

- One keeper observed: `masc-improver`. `last_blocker.klass = cascade_exhausted`. Persisted ≥ 21h. Empirical N = 1.
- §1.2 Axis C #5 generalisation ("no code path clears `last_blocker`") was based on a `rg -n` invocation whose output was misread. The *clear* paths exist; they were filtered out by the grep's exact-string pattern.

### §12.2 What the 2026-05-15 measurement showed

Server restarted on RFC-0082's merge commit (`90e02e0ee0`). Fleet measurements:

| Server uptime | `last_blocker = dict` count | `last_blocker = null` count |
|---|---|---|
| ~1 min | 17 (apparent — see §12.4 below) | 1 |
| ~5 min | 5 (real) | 13 |

12 keepers self-cleared between t+1min and t+5min, with no operator action. The six clear sites in §1.2 Axis C #5 *do* fire on normal turn-success paths.

### §12.3 Which keepers stayed stuck and why

Of the 5 remaining latched keepers (`glm-coding`, `imseonghan`, `janitor`, `qa-king`, `sangsu`):

- 1 carries `klass = stale_turn_timeout` (`active=625s` > `threshold=600s`)
- 4 carry `klass = stale_fleet_batch` (mostly with `root_cause=stale_turn_timeout` and active times 2132–2167 s)

All 5 share: `set_at = None` (no timestamp on the latch dict — legacy shape), `paused = false` (so dispatch is not gated), and `last_proactive_reason` in {`text_response`, `tools=[...]`, `require_tool_use` error} — *they are running turns*. Their *running* turns do not pass through any of the six clear sites. This is the real defect.

### §12.4 Measurement caveat — initial 17/1 was inflated

The first dump script bucketed `last_blocker` values incorrectly:

- One keeper (`velvet-hammer`) had `last_blocker = None` but was mis-classified as `dict` (fallback label in the dump's `else` branch).
- Five `dict` values had a `klass` field whose value was a *string* (not a sub-dict), and the script fell through to a `"dict"` fallback label that hid the structural shape.

After fixing the script, the t+5min reality was 5 latched, not 17.

### §12.5 Consequences for the RFC

- **§0 Summary**: amended in-line — "no code path clears" → "six code paths clear, but stale-exit keepers skip them."
- **§1.2 Axis C #5**: amended in-line with the six call sites and the t+5min observation.
- **§3.1 typed lifecycle**: marked *RE-SCOPED*. Adding a seventh `last_blocker = None` site without diagnosing why the existing six miss the stale-exit path would be CLAUDE.md §"워크어라운드 거부 기준" #3 (N-of-M). The lifecycle module is still the right target shape — it consolidates six scattered assignments — but it is *gated on §0.6*.
- **§4 phasing**: Phase 0.6 inserted (stale-exit code-path trace, docs only). Phase 1 BLOCKED on Phase 0.6 output.
- **§6 Tier 1**: option 0 (`masc_keeper_down` + `masc_keeper_up`) promoted to first recommendation, validated empirically on masc-improver 2026-05-14.
- **§10 migration completion criteria**: criterion "`rg -n "last_blocker = .*None|reset_last_blocker|clear_blocker" lib/keeper/` returns the new lifecycle calls" stands — but is now *additionally* qualified: the lifecycle module must replace the six existing assignments (consolidation), not just add a seventh.

### §12.6 Lessons (for future RFCs)

1. N = 1 is not a fleet claim. The original RFC generalised one stuck keeper to a fleet-wide structural defect without measuring the fleet. The first measurement after merge would have falsified the premise.
2. `rg -n "<pattern>" lib/`  output should be enumerated, not summarised. The grep that "confirmed no clear path" was not actually empty — `last_blocker = None` (with spaces, with `=`, not `:=`) returns six lines.
3. Time matters. A fleet measurement at server uptime t+1min is *transient state*, not *steady state*. Transient latches at restart are not the same defect as persistent latches under steady state.

### §12.7 Memory entry

A feedback memory `memory/feedback_rfc_premise_falsified_by_first_measurement.md` is added in the same correction PR, recording the pattern: *first measurement after merge can falsify the RFC; merge does not validate the premise.*

🤖 Generated with [Claude Code](https://claude.com/claude-code) — original 2026-05-14, corrected 2026-05-15
