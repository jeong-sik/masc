# RFC 0022 — Cascade Attempt Liveness Contract

- Status: Draft
- Author: Vincent (vincent.dev@kidsnote.com)
- Date: 2026-05-01
- Related RFCs (layer hand-offs):
  - RFC-0009 (Cascade Trust Phase 2) — *pre-attempt* layer, provider reputation
  - RFC-0012 (Mid-Turn Progress Probe) — *cross-attempt at turn level*
  - **This RFC** — *in-attempt* layer, streaming liveness
- Related memory:
  - `feedback_oas_timeout_budget_late_cascade_exhaustion`
  - `feedback_codex_cli_internal_5model_rotation`
  - `feedback_proactive_turn_contract_violation_dominant`
  - `feedback_oas_execution_uncancellable_mid_turn`
  - `feedback_provider_cli_rollout_thread_not_found`
- Empirical input: `scripts/diag-keeper-cycle.sh` (PR #TBD-reproducer) — 14 keepers, MAX_S clusters at 3600s for 11/14, P95 bimodal at ~1170s/~3600s.

## 0. TL;DR

Cascade providers are called without any in-attempt liveness contract. A
single hung HTTP read on the first cascade slot consumes the entire
turn budget (3600s) before the cascade FSM advances to the next
provider. This RFC introduces an attempt-level three-tier streaming
liveness gate (TTFT, inter-chunk idle, wall) that fails the *current
attempt* — not the turn — when the provider stops emitting evidence of
forward motion. Thinking tokens count as motion, so adaptive-reasoning
turns are protected.

## 1. Layer Separation (Mandatory)

This RFC must not collide with RFC-0009 or RFC-0012. The three layers
operate on disjoint state and disjoint kill classes:

| Layer | RFC | State | Decision input | Kill class | Effect on caller |
|---|---|---|---|---|---|
| Pre-attempt | RFC-0009 | `Cascade_health_tracker.trust_score` | aggregate failures over time | provider demoted in cascade order | next call sees better order |
| **In-attempt (this RFC)** | **0022** | per-attempt liveness clock | absence of streaming chunks | `Attempt_no_first_token` / `Attempt_inter_chunk_idle` / `Attempt_wall_exceeded` | this attempt fails, FSM advances to next slot, **turn lives** |
| Cross-attempt (turn) | RFC-0012 | `turn_observation.last_progress_at` | absence of `oas:event` across all attempts in this turn | `Mid_turn_no_progress` | watchdog terminates fiber, turn dies |

Invariant L1 (layer independence):
```
∀ event e :
  e advances RFC-0012's last_progress_at  ⇒  e advances this RFC's chunk_clock
  e advances this RFC's chunk_clock        ⇒  e advances RFC-0012's last_progress_at
```
i.e. the two clocks are in lockstep on every emission, but their
*timeouts* are different (this RFC short, RFC-0012 long).

Invariant L2 (no double kill):
```
attempt killed by this RFC  ⇒  cascade FSM advances *before*
                               RFC-0012 watchdog observes idle.
```
The attempt-level kill must always be faster than the turn-level kill
or the turn dies before the cascade gets a chance to recover.

## 2. Problem statement

### 2.1 Empirical evidence (2026-05-01)

`diag-keeper-cycle.sh` over `~/.masc/keepers/` shows:

```
KEEPER          TOTAL     OK    ERR   NULL    P50_S    P95_S    MAX_S
analyst           256     36     62    158      0.0    682.2   3585.6
executor          148     34     26     88      0.0   3585.1   3600.0
issue_king        386    118    146    122      6.5    585.6   3598.1
nick0cave         603     81    393    129      2.1   1199.1   3602.1
qa-king           490    118    244    128     18.7   1172.0   3584.8
sangsu            717    160    231    326      0.6    898.2   3585.3
```

Two facts are diagnostic:

1. **MAX_S converges to ~3600s for 11/14 keepers.** Latency is bounded
   not by provider behaviour but by `MASC_KEEPER_TURN_TIMEOUT_SEC`
   (default 3600s). The cascade exhausts the entire turn budget on a
   single bad attempt.
2. **P95 is bimodal at ~1170s and ~3585s.** The 1170s cluster maps to
   one HTTP layer timeout (~19.5 min); the 3585s cluster is the turn
   cap. There is *no* sub-1000s liveness check.

### 2.2 Mechanism

```
keeper_turn (timeout = 3600s)
  └─ cascade.run                    (no timeout, no liveness)
       ├─ codex_cli:gpt-5.3-codex-spark   (HTTP read, no liveness) → hang
       ├─ gemini_cli:auto                  (never reached)
       ├─ kimi_cli:kimi-for-coding        (never reached)
       ├─ glm-coding:auto                  (never reached)
       └─ claude_code:auto                 (never reached)
```

A grep across `lib/cascade/cascade_fsm.ml`, `lib/cascade/cascade_strategy.ml`,
`lib/cascade/cascade_runtime.ml` for the keywords `timeout|deadline|with_clock`
returns **zero matches**. Cascade has no notion of attempt liveness.

### 2.3 User-visible symptom (verbatim, 2026-05-01)

> "서버 켜면 존나 열심히 막 tool 쓰다가 ... 갑자기 멈춰서 가만히 있다가.
> 한참 지나면 gemini 에러가 미친듯 나오고 ... 다시 잠수."

Reconstructed timeline:
- t₀: keeper turn starts, cascade slot 1 (codex_cli:spark) is called.
- t₁ ≈ t₀: HTTP request emitted to provider.
- t₁ < t < t₀+3600s: provider holds the connection without yielding
  any chunks. Watchdog does not observe idle because "turn started"
  was logged (turn obs.started_at) and watchdog only checks
  `now - started_at > 3600`.
- t₀+~1170s or t₀+~3600s: HTTP layer or turn-cap times out → cascade
  FSM advances → slot 2 (gemini_cli) called → fails the same way →
  slots 3,4,5 fail in rapid succession because they are each tried
  near the budget cap → **error burst**.
- t > t₀+3600s: keeper goes back to sleep, repeats next turn.

This RFC kills the attempt at t₀ + TTFT, before the burst.

## 3. Failure model

A streaming provider attempt can be in one of these terminal states.
All terminal states except `Done` must be detected and reported as a
typed cascade failure (not a generic timeout):

| State | Detection | Kill class | Trust impact (RFC-0009) |
|---|---|---|---|
| `Done` | response complete | — | success |
| `No_first_token` | TTFT exceeded | `Attempt_no_first_token` | persistent |
| `Inter_chunk_idle` | gap between chunks > idle_max | `Attempt_inter_chunk_idle` | persistent |
| `Wall_exceeded` | total wall > attempt_wall_max | `Attempt_wall_exceeded` | persistent |
| `Provider_error` | HTTP 4xx/5xx with body | classified by RFC-0009 | depends |
| `Network_drop` | TCP RST / EOF mid-stream | `Network_drop` | transient |
| `Cancelled` | upstream Cancel | `Upstream_cancelled` | n/a |

Note: `No_first_token` and `Inter_chunk_idle` are **distinct** states
because their probable causes differ:
- `No_first_token` ≈ provider auth / queueing / cold-start at provider
  side. Try next slot immediately.
- `Inter_chunk_idle` ≈ provider mid-response stall (network, GPU
  pause, etc). The partial response is discarded — do not surface
  partials to the keeper because the response is no longer
  well-formed.

## 4. Design

### 4.1 Living attempt liveness gate

```ocaml
(** Attempt liveness budget. All durations in seconds. *)
type liveness_budget = {
  ttft_max         : float;  (* time to first chunk            *)
  inter_chunk_max  : float;  (* gap between consecutive chunks *)
  attempt_wall_max : float;  (* hard backstop                  *)
}
```

The first attempt for a concrete provider/model candidate uses an
explicit bootstrap budget. After successful streaming attempts exist,
the runtime derives the budget from recent successful samples for that
same candidate:

| Source | TTFT | Inter-chunk | Wall |
|---|---|---|---|
| bootstrap | conservative fixed floor | conservative fixed floor | conservative fixed floor |
| observed success | padded P95 successful TTFT | padded P95 successful max gap | padded P95 successful wall |

Rejected, killed, errored, or cancelled attempts do not train the
budget. There is no provider-size taxonomy in this RFC: model labels
must not imply liveness classes.

### 4.2 Thinking-aware

Adaptive reasoning models (`extended_thinking`, `gpt-5.x reasoning`,
gemini "thinking", etc.) emit *thinking* chunks before *answer*
chunks. These thinking chunks must satisfy TTFT and inter-chunk
heartbeat:

Invariant T1 (thinking counts as motion):
```
chunk_clock advances on:
  - thinking_delta
  - answer_delta
  - tool_call_started
  - tool_call_arguments_delta
  - tool_call_completed
  - any_substrate_event
```

If a provider emits no thinking signal at all, it must still emit
some periodic protocol-level heartbeat (server-sent-event keepalive,
HTTP/2 ping, JSONL keepalive line) within `ttft_max`. If it does not,
the provider is broken from this RFC's perspective, regardless of how
"reasonable" the silence is.

### 4.3 Cancellation propagation

Killing an attempt must release the provider connection. Per
`feedback_oas_execution_uncancellable_mid_turn` this is non-trivial
because OAS HTTP single-bulk-read is uncancellable from inside the
fiber. Two implementation choices:

| Choice | Pros | Cons |
|---|---|---|
| **Switch-bound cancellation** (Eio.Switch) | First-class Eio idiom, clean | Provider client must enrol the read in the switch |
| **Dual-fiber race** (read fiber + clock fiber) | Works with any client | Wasted fiber per attempt |

Recommendation: switch-bound cancellation primary; dual-fiber as
fallback for clients that do not yet enrol. Migration plan tracked
per provider in §10.

### 4.4 Streaming protocol contract

Define a typed contract for what counts as a chunk:

```ocaml
module Stream_chunk = struct
  type kind =
    | Thinking_delta
    | Answer_delta
    | Tool_call_start of { tool_name : string }
    | Tool_call_arg_delta
    | Tool_call_complete
    | Substrate_event of { kind : string }
    | Heartbeat   (* protocol-level, no semantic content *)
    | Done

  type t = {
    kind        : kind;
    received_at : float;       (* monotonic, seconds *)
    bytes       : int;         (* for telemetry only *)
  }
end
```

Invariant S1 (every chunk advances the clock):
```
∀ c : Stream_chunk.t, c.kind ≠ Done
  ⇒  liveness.last_chunk_at = c.received_at
```

Invariant S2 (Done is terminal):
```
c.kind = Done  ⇒  no further chunks accepted
                  cascade FSM observes Done → success
```

Invariant S3 (Heartbeat is non-empty):
```
Heartbeat is permitted only as a liveness signal during long thinking
/ tool-call windows. Provider clients MUST NOT emit Heartbeat chunks
to satisfy liveness without underlying real activity (i.e. clients
must not lie). Property test enforces this on adapters in repo.
```

### 4.5 Per-attempt FSM

```
                ┌──────────────┐
       start →  │  Awaiting     │ ── ttft_max elapsed ──→ No_first_token
                │  first chunk  │
                └──────┬────────┘
                       │ first chunk arrives
                       ▼
                ┌──────────────┐
                │  Streaming    │ ── inter_chunk_max gap ──→ Inter_chunk_idle
                │              │ ── attempt_wall_max     ──→ Wall_exceeded
                └──────┬────────┘
                       │ Done
                       ▼
                    Success
```

Decision-table form (for property test):

| state         | event              | next state    | output            |
|---------------|--------------------|---------------|-------------------|
| Awaiting      | chunk(any)         | Streaming     | continue          |
| Awaiting      | tick(t≥ttft_max)   | Failed        | No_first_token    |
| Awaiting      | provider_error e   | Failed        | Provider_error e  |
| Streaming     | chunk(any)         | Streaming     | continue          |
| Streaming     | tick(gap≥idle_max) | Failed        | Inter_chunk_idle  |
| Streaming     | tick(wall≥wall_max)| Failed        | Wall_exceeded     |
| Streaming     | chunk(Done)        | Success       | result            |
| Streaming     | provider_error e   | Failed        | Provider_error e  |

### 4.6 Wiring into existing cascade FSM

`cascade_fsm.ml` already has variants for advancing on failure. Wire
`Failed_attempt of {kind; provider}` into the FSM as a new failure
class. The FSM step for `Failed_attempt` is identical to existing
"provider error → advance"; the only difference is the kill class is
now attributable to liveness, not to a wire error.

## 5. Formal specification (sketch)

A small TLA+ module models the per-attempt FSM with a `BugAction`
that absorbs ticks (i.e. fails to advance the clock on chunks). The
clean spec satisfies `LivenessKillsFastEnough`; the buggy spec must
violate it.

```
MODULE CascadeAttemptLiveness

EXTENDS Naturals
CONSTANTS TTFT_MAX, IDLE_MAX, WALL_MAX, NOW_MAX
VARIABLES state, last_chunk_at, started_at, now

TypeOK ==
  /\ state ∈ {"Awaiting", "Streaming", "Failed", "Success"}
  /\ now ∈ Nat /\ now ≤ NOW_MAX

Tick == now' = now + 1 /\ UNCHANGED <<state, last_chunk_at, started_at>>

Chunk(kind) ==
  /\ state ∈ {"Awaiting", "Streaming"}
  /\ state' = (IF kind = "Done" THEN "Success" ELSE "Streaming")
  /\ last_chunk_at' = now
  /\ UNCHANGED <<started_at, now>>

LivenessKill ==
  \/ /\ state = "Awaiting" /\ now - started_at ≥ TTFT_MAX
     /\ state' = "Failed" /\ UNCHANGED <<last_chunk_at, started_at, now>>
  \/ /\ state = "Streaming"
     /\ \/ now - last_chunk_at ≥ IDLE_MAX
        \/ now - started_at    ≥ WALL_MAX
     /\ state' = "Failed" /\ UNCHANGED <<last_chunk_at, started_at, now>>

Next == Tick \/ \E k ∈ ChunkKinds : Chunk(k) \/ LivenessKill

(* Safety: a Failed state is reached strictly before turn-cap *)
LivenessKillsFastEnough ==
  state ∈ {"Failed", "Success"} =>
    now - started_at ≤ Max(TTFT_MAX, WALL_MAX) + 1

Spec == Init /\ [][Next]_vars

(* Bug model: chunk events that fail to update last_chunk_at *)
BugChunk(k) ==
  /\ state ∈ {"Awaiting", "Streaming"}
  /\ state' = "Streaming"
  /\ UNCHANGED last_chunk_at  (* the bug *)
  /\ UNCHANGED <<started_at, now>>

NextBuggy == Next \/ \E k ∈ ChunkKinds : BugChunk(k)
```

Clean spec must pass `INVARIANT LivenessKillsFastEnough`.
Buggy spec must violate it (per
`feedback_fsm_guard_identity_helper_counter_wrap_pattern` two-cfg
mutation testing pattern).

## 6. Provider taxonomy

Not all providers in `big_three` natively stream. Concrete migration
table:

| Provider | Streams natively | First-class chunk | Implementation note |
|---|---|---|---|
| `codex_cli:*` | yes (SSE) | answer_delta | enrol read fiber in switch |
| `gemini_cli:*` | yes (NDJSON) | answer_delta + thinking_delta | inter-chunk gap can be 5-15s on long thinking; calibrate idle_max |
| `kimi_cli:*` | yes | answer_delta | TBD on thinking taxonomy |
| `glm-coding:*` | partial | bulk + delta hybrid | needs adapter; emit Heartbeat from client wrapper if provider goes silent during tool-call planning |
| `claude_code:auto` | yes | thinking_delta + answer_delta + tool_use | well-instrumented |

`ollama` providers (when used) frequently buffer tokens; idle_max may
need a higher value (60-90s) under load.

## 7. Files affected (mli surface)

| File | Change |
|---|---|
| `lib/cascade/cascade_attempt_liveness.ml` (new) | FSM, decision table, telemetry hooks |
| `lib/cascade/cascade_attempt_liveness.mli` (new) | export `liveness_budget`, `step`, `Outcome.t` |
| `lib/cascade/cascade_runtime.ml` | wrap each provider call in liveness gate; report typed `Failed_attempt` |
| `lib/cascade/cascade_fsm.ml` | accept `Failed_attempt` as advance trigger; preserve trust hook |
| `lib/cascade/cascade_health_tracker.ml` | classify attempt-liveness failures into `persistent` vs `transient` per §3 table |
| `lib/cascade/cascade_config.ml` | add `liveness_budget` field per profile |
| `lib/cascade/cascade_config.mli` | surface `liveness_budget` reader |
| `config/cascade.toml` | no liveness class; runtime learns from successful concrete candidates |
| `lib/cascade/cascade_attempt_liveness_config.ml` | bootstrap budget plus recent successful sample store |
| `lib/config/env_config_keeper.ml` | env override hooks for the three thresholds (per profile) |
| `lib/keeper/keeper_hooks_oas.ml` | bridge `Stream_chunk` events to RFC-0012 `record_progress` (Invariant L1) |
| `test/test_cascade_attempt_liveness.ml` (new) | property tests (§9) |
| `tla/CascadeAttemptLiveness.tla` (new) | spec from §5 |
| `tla/CascadeAttemptLiveness.cfg` (new, clean) | INVARIANT LivenessKillsFastEnough |
| `tla/CascadeAttemptLiveness-buggy.cfg` (new, mutation) | NextBuggy |
| `docs/operations/cascade-liveness-tuning.md` (new) | how operators calibrate thresholds against `diag-keeper-cycle.sh` output |

LOC estimate: 350-500 net additions across OCaml + TLA+ + docs.

## 8. Property tests

The decision table in §4.5 is the source of truth. Tests:

1. **Decision-table coverage.** Every (state, event) pair has at
   least one test that asserts `step state event = expected`.
2. **No-double-kill.** ∀ run: at most one liveness kill per attempt.
3. **Layer L1 in lockstep.** Generate random chunk streams, assert
   that for every chunk both the local liveness clock and a mocked
   `Keeper_registry.record_progress` advance at the same monotonic
   time.
4. **Thinking protection.** A 600s thinking-only stream with chunks
   every 5s is *not* killed when the candidate's observed-success
   budget allows that stream shape.
5. **Hung-first-byte.** A provider that holds the connection without
   any chunks is killed at exactly TTFT_MAX (±10ms).
6. **Mid-stream stall.** A provider that sends 3 chunks then stalls
   is killed at last_chunk_at + IDLE_MAX (±10ms).
7. **Wall backstop.** A provider streaming a token every (IDLE_MAX -
   1)s indefinitely is killed at WALL_MAX exactly.
8. **Cancellation cleanup.** After kill, no fiber leak; switch
   release count = +1 per kill (Eio resource ledger).

## 9. Operational rollout

Phase A (historical observation rollout) — **wiring landed (PR-2)**:
- FSM module + tests in PR-1 (`lib/cascade/cascade_attempt_liveness.{ml,mli}`).
- Observer + tick fiber + `oas_worker_named.ml::try_provider` integration in PR-2 (`lib/cascade/cascade_attempt_liveness_observer.{ml,mli}`, `lib/cascade/cascade_attempt_liveness_config.{ml,mli}`).
- Behind `MASC_CASCADE_ATTEMPT_LIVENESS=off|observe|enforce`. Current runtime default is `enforce` when the env var is unset; an empty or unknown value resolves to `observe`.
- `observe`: liveness clock runs, kills emit `masc_cascade_attempt_liveness_kill_total{mode=observe}` and `masc_cascade_attempt_liveness_observed_total{outcome=...}` but no `Switch.fail`; cascade still advances on real wire errors.
- 24h on dev base path; compare `diag-keeper-cycle.sh` MAX_S/P95.

Phase B (enforce with living budgets):
- Flip liveness to `enforce` after observe-mode samples show the bootstrap and observed-success budgets are not producing false positives.
- Watch `cascade_attempt_liveness_kill_total{kind=...}` Prometheus counter.
- Inspect budget source labels (`bootstrap` vs `observed_success`) in
  debug logs and receipts while candidate histories warm up.

Phase C (default `enforce` everywhere):
- After a 2-week soak with no false-positive reports, default flips
  to `enforce`. RFC-0012 progress timeout can then be raised back to
  its design value if the operator chooses, since RFC-0022 catches
  the early case.

## 10. Out of scope

- Flat global lowering of `MASC_KEEPER_TURN_TIMEOUT_SEC` to a single
  value below the per-cascade design floor. RFC-0012 §Out of scope
  explains why a global reduction is rejected (legitimate 27 B
  `900 s+` turns). Note that the env clamp in
  `lib/keeper/keeper_runtime_resolved.ml:73-79` currently caps the
  env value at 600 s — that is a code regression versus the original
  3 600 s design and is resolved separately by per-cascade override
  (Step 2 of goal `oas-bridge-stabilization`).
- **Permitted (per-cascade override, added 2026-05-06)**: a cascade
  profile in `config/cascade.toml` may set its own
  `turn_timeout_sec`. Checked-in remote/CLI profiles (`big_three`,
  `keeper_diverse`, `tier_fast`, `tier_medium`) run at 600 s.
  Operator-populated local-model profiles (not the checked-in
  `[local_recovery]` fallback profile) run at 900 s when they declare
  local providers (for example, `tier_small` with its Ollama entries
  enabled). Promotion to 1 800 s requires a follow-up RFC
  backed by one week of
  `masc_cascade_attempt_liveness_kill_total{mode="observe",kind="wall_exceeded"}`
  + p95 turn-duration data. The budget invariant
  `turn_timeout - oas_guard >= admission_wait + min_useful_run`
  remains a hard regression test (root cause of #10388), with terms
  mapped as follows: `turn_timeout` is the resolved cascade
  `turn_timeout_sec` (or `MASC_KEEPER_TURN_TIMEOUT_SEC` fallback);
  `oas_guard` is `Keeper_turn_cascade_budget.oas_timeout_guard_sec`;
  `admission_wait` is
  `Keeper_runtime_resolved.admission_wait_timeout_sec ()`
  / `MASC_KEEPER_ADMISSION_WAIT_TIMEOUT_SEC`; `min_useful_run` is the
  RFC/test minimum useful post-admission provider run window.
- Provider-side cost metrics (covered by RFC-0009 Phase 3).
- Wholesale replacement of OAS HTTP single-bulk-read with chunked. That is `feedback_oas_execution_uncancellable_mid_turn` ("masc-mcp 단독 fix 영역 zero").
- Per-keeper liveness override (deferred — start with per-candidate
  living budgets).

## 11. Open questions

1. **Thinking-only providers without protocol heartbeat.** If a
   provider thinks for 5min with no chunks at all (pure server-side
   reasoning), Invariant T1 fires `No_first_token` and we kill what
   was actually a healthy long-think. Mitigation: server-side
   heartbeat is standard on all currently-cascaded providers; if a
   future provider lacks it, it needs a dedicated runtime lane or an
   explicit bootstrap override that accounts for that transport.

2. **Inter-chunk vs token-rate.** A provider streaming at 0.5 tok/s
   may pass inter-chunk but still feel dead to a keeper.
   Token-rate-aware liveness is a follow-up RFC; this RFC uses
   inter-chunk only to avoid over-engineering Phase A.

3. **Calibration data freshness.** Defaults in §4.1 are starting
   points. Final values come from `diag-keeper-cycle.sh` after Phase
   A observe; that data is a precondition for Phase B `enforce`.

4. **Backwards compatibility with non-streaming legacy clients.**
   Some adapters return a bulk response. Treated as a single
   `Answer_delta(...)` immediately followed by `Done`; TTFT clock
   counts from request emission to bulk arrival. Adapters MUST NOT
   pre-fabricate `Heartbeat` to "look streamy" (Invariant S3).

## 12. Verification plan

| Gate | Tool | Pass criterion |
|---|---|---|
| Static | `dune build` + `dune runtest` | green |
| Formal | TLC on `CascadeAttemptLiveness.cfg` (clean) | `INVARIANT LivenessKillsFastEnough` pass |
| Formal (mutation) | TLC on `-buggy.cfg` | invariant violated |
| Empirical pre | `diag-keeper-cycle.sh` snapshot | recorded as baseline |
| Empirical post Phase A | `diag-keeper-cycle.sh` 24h | counter `cascade_attempt_liveness_kill_total{mode=observe}` non-zero on at least one provider; no behaviour change |
| Empirical post Phase B | `diag-keeper-cycle.sh` 24h | P95_S for affected keepers drops by ≥30% versus baseline without false-positive kills |
| Soak | 2 weeks Phase B | zero false-positive reports |

## 13. References

- `lib/cascade/cascade_fsm.ml`, `cascade_strategy.ml`, `cascade_runtime.ml` (current cascade modules — `timeout|deadline|with_clock` keyword count: 0)
- `lib/cascade/cascade_health_filter.ml` (104 LOC) — pre-attempt prune; complementary, not overlapping
- `lib/cascade/cascade_health_tracker.ml` (723 LOC) — RFC-0009 trust state, will receive new failure-class taxonomy
- `lib/keeper/keeper_stale_watchdog.ml` — RFC-0012 turn-level watchdog
- `scripts/diag-keeper-cycle.sh` — empirical reproducer (PR #TBD)
