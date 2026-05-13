# RFC 0026 — Work-Conserving Keeper Admission

- Status: Draft
- Author: Vincent (vincent.dev@kidsnote.com)
- Date: 2026-05-05
- Related RFCs (layer hand-offs):
  - RFC-0009 (Cascade Trust Phase 2) — *provider reputation* (orthogonal)
  - **This RFC** — *admission* layer, keeper-turn slot acquisition
  - RFC-0022 (Cascade Attempt Liveness) — *in-attempt* streaming liveness (orthogonal)
  - RFC-0012 (Mid-Turn Progress Probe) — *cross-attempt* turn-level watchdog (orthogonal)
- Related memory:
  - `feedback_keeper_starvation_capacity_vs_turn_duration_mismatch`
  - `feedback_clock_origin_must_match_phase_boundary`
  - `feedback_periodic_scanner_must_transition_state_after_acting`
  - `feedback_helper_default_field_with_caller_override`
- Empirical input: live operational evidence 2026-05-04 ~ 2026-05-05 KST
- Concurrent implementation: PR #12904 (`feat(keeper): per-provider token bucket primitive`) — landed independently with matching I1-I5 invariants. This RFC formalizes the design ground that PR series #12904 + follow-ups operate within. Module paths in §3 are aligned to that PR's chosen layout (`lib/keeper/keeper_*` rather than a separate `lib/admission/` namespace, because of the keeper sublib circular-dependency analysis in `memory/project_keeper_sublib_extraction_analysis.md`).

## 0. TL;DR

The current keeper admission layer is built on three global Eio
semaphores (`turn_semaphore`, `autonomous_turn_semaphore`,
`reactive_turn_semaphore`). Capacity is tuned via env vars
(`MASC_KEEPER_AUTONOMOUS_CONCURRENCY`, `MASC_KEEPER_AUTOBOOT_MAX`).
Real workloads have demonstrated that the semaphore model:

1. Cannot tell *which* of N keepers is starving — only that "peers are
   holding slots".
2. Treats all keepers as fungible — `analyst` (latency-sensitive board
   reaction) and `janitor` (5-min sweep) compete for the same slot.
3. Treats all providers as fungible — Anthropic, GLM, Codex, Gemini
   share one global counter even though their rate limits, latencies,
   and failure modes differ by orders of magnitude.

Result: under N=14 keepers and avg-turn 60-150s the queue length under
concurrency=6 is ≥8 every cycle, producing systematic
`semaphore_wait>60s skip storm` (387 skip-turn / 45 min observed
2026-05-05 02:55-03:40 KST).

This RFC retires the global semaphores and replaces the admission
layer with three pieces:

1. **Per-provider token bucket** (admission gate) — each provider has
   independent capacity, refilled at the provider's published rate.
   `try_acquire` is non-blocking. Failure routes to the next candidate.
2. **Adaptive cascade router** (decision policy) — for each keeper, at
   admission time, produce an *ordered candidate list* `(provider,
   tier)` based on persona preference + live availability. drift
   (preferred → actual) is always logged.
3. **WFQ overflow queue** (fairness fallback) — when *every* candidate
   is throttled, keepers enter a Weighted-Fair-Queue keyed by
   per-persona weight. Wakes on any provider-token refill event.

Liveness invariant **I1**: `∀ keeper k. eventually-progresses(k)`
holds whenever `Σ rate_limit(p) > 0` for at least one provider in
*any* keeper's candidate set. Below that capacity we surface the
shortfall to the operator with structured admission control rather
than silent starvation.

## 1. Layer Separation (Mandatory)

This RFC must not collide with RFC-0009 / RFC-0012 / RFC-0022. Four
layers, disjoint state, disjoint kill classes:

| Layer | RFC | State | Decision input | Effect |
|---|---|---|---|---|
| Provider reputation | 0009 | `Cascade_health_tracker.trust_score` | aggregate failures over time | provider demoted in candidate ordering |
| **Admission (this RFC)** | **0026** | per-provider token bucket + WFQ deficit table | live token availability + persona weight | dispatch / overflow-enqueue / surface |
| In-attempt liveness | 0022 | per-attempt chunk clock | absence of streaming chunks | this attempt fails, FSM advances |
| Cross-attempt watchdog | 0012 | `turn_observation.last_progress_at` | absence of `oas:event` across attempts | watchdog terminates fiber, turn dies |

Invariant **L1 (admission ⊥ liveness)**: admission layer never
*kills* a turn. It only refuses to *start* one.
```
∀ keeper turn t : admission_decision(t) ∈ {Dispatch p, Wait, Surface}
                 — never Killed
```

Invariant **L2 (admission contract for liveness)**: admission must
deliver `Wait` results within bounded time `T_overflow_max`, after
which it must dispatch *some* provider (lowest tier) or escalate to
`Surface` (operator-visible event). This is what removes starvation.

## 2. Problem statement

### 2.1 Operational evidence (2026-05-04 ~ 2026-05-05 KST)

```
window: 17:11:00Z → 17:55:56Z (2026-05-04, KST 02:11~02:55, ~45 min)
top events from tail -2000 system_log_2026-05-04.jsonl:
  1205 other
   387 peers holding slot          <- semaphore_wait >60s skip storm
   383 keepalive                   <- scheduler is alive, admission is dead
    25 cascade
top keeper distribution:
  1994 system
     4 glm-coding-plan             <- only 4 keepers got any turn
     2 executor                    <- 2 turns total in 45 min
     0 [10 other keepers]          <- 0 turns in 45 min
```

Diagnostic facts:

1. **counter `available=N>0` is misleading.**
   `Eio.Semaphore.get_value` is sampled post-release. Operators see
   `autonomous_available=6 turn_available=12` and conclude "queue
   not consuming free slots", when the real story is *acquire is
   queued behind 8 peers*.
2. **Capacity × turn-duration mismatch is mathematical, not a bug.**
   `(N_keeper - concurrency) × avg_turn_duration_sec > T_skip_budget`
   ⟹ systematic skip storm. With N=14, conc=6, avg turn 60-150s,
   T_skip_budget=60-90s the queue head waits 240-1200s. Every cycle
   produces 8 skips.
3. **PR-level fixes do not converge.**
   PR #1087 (cascade ollama_bench gating) merged → stall recurs on
   `cascade=primary`. PR #12863 (slot release at inner cancel)
   merged → stall recurs. PR #12885 / #12894 / #12895 (slot lifecycle
   redesign) all open as drafts. The semaphore abstraction is the
   root, not any individual call site.

### 2.2 Mechanism

```
keeper_heartbeat_loop fires
  └─ schedule_turn(keeper k)
       └─ acquire_bounded ~label:"autonomous" autonomous_turn_semaphore
            (timeout MASC_KEEPER_AUTONOMOUS_SLOT_WAIT_TIMEOUT_SEC)
               ├─ Ok ()           → Eio.Semaphore.acquire turn_semaphore
               │                     → run_keeper_cycle (real work)
               │                     → release pair
               └─ Timeout         → emit "peers holding slot, autonomous_available=N>0"
                                   → keeper.skip_turn()
                                   → next heartbeat tick (60-90s later)
                                   → same path, same outcome
                                   → indefinite starvation under sustained N>conc load
```

The two-semaphore design (`autonomous_turn_semaphore` +
`turn_semaphore`) was added to keep reactive responsiveness while
throttling autonomous turns. It does not solve the work-conserving
problem; it adds a second admission gate the keeper has to win.

### 2.3 User-visible symptom (verbatim, 2026-05-05 KST)

> 어떤 keeper도 절대 막히지 않음. 이 가장 중요한 가치고 그걸 위한 고도의 수학적 설계여야함

> 때문에 semaphore 가 의미가 없어 보이거든. 무족건 가용한 provider, model 로 계속 돌게끔시켜야하고 동적으로 변화해야지

The user invariant is **I1 (universal liveness)** verbatim. This RFC
operationalizes I1.

## 3. Design

### 3.1 Core invariants

**I1 (Universal Liveness)**
```
∀ keeper k.
  ∃ provider p ∈ candidates(k) : token_available(p, t) > 0
  ⟹ eventually(t' > t, dispatched(k, p))
```
At least one candidate provider has tokens ⟹ keeper k will be
dispatched within bounded time.

**I2 (Work-Conserving)**
```
¬∃ t, k, p : waiting(k, t) ∧ idle(p, t) ∧ p ∈ candidates(k)
```
No keeper waits while any of its candidate providers is idle.

**I3 (Rate-Respect)**
```
∀ provider p, sliding-window W :
  dispatched_count(p, W) ≤ rate_limit(p, W)
```
Dispatch count over window W never exceeds provider rate.

**I4 (Bounded Wait)**
```
∀ keeper k :
  Σ rate_limit(p ∈ candidates(k)) > 0
  ⟹ wait_time(k) ≤ T_max
```
Whenever the candidate set has any non-zero rate, wait is bounded.

**I5 (Drift Observability)**
```
∀ dispatch event :
  preferred(k) ≠ actual ⟹ logged(keeper, preferred, actual, reason, tier)
```
Substrate drift is always recorded. The user's "왜 갑자기 GLM 답?"
is answerable by Prometheus query.

### 3.2 Layer 1 — Per-provider token bucket

Module: `lib/keeper/keeper_provider_token_bucket.{ml,mli}`

```ocaml
type provider =
  | Anthropic
  | Codex_cli
  | Codex_api
  | Gemini_cli
  | Gemini_api
  | Glm_coding
  | Glm_text
  | Kimi_cli
  | Ollama_local

type bucket = private {
  capacity : int;
  refill_rate_per_sec : float;
  mutable tokens : float;
  mutable last_refill : float;
  mutable in_flight : int;
}

(** Non-blocking. Returns true on success (token consumed + in_flight
    incremented). Never raises. *)
val try_acquire : provider -> bool

(** Pair with successful try_acquire. Decrements in_flight. *)
val release : provider -> unit

(** Pure inspection — does not mutate. *)
val tokens_available : provider -> float
val in_flight : provider -> int

(** Subscribe to refill events. Callback is invoked from the refill
    fiber after tokens move from 0 → ≥1. Used by overflow queue to
    wake waiters. *)
val on_refill : provider -> (unit -> unit) -> unit
```

Refill loop runs on a single Eio fiber per provider, ticking every
`max(1.0, 1.0 /. refill_rate_per_sec)` seconds. The refill is
deterministic (computed from elapsed time, not tick count) so it
survives scheduling delays.

Capacity / refill_rate values are loaded from
`.masc/config/admission.toml` (new), with hot-reload support
identical to cascade.toml.

### 3.3 Layer 2 — Adaptive cascade router

Module: `lib/keeper/keeper_admission_router.{ml,mli}`

```ocaml
type tier = Preferred | Acceptable | Survival
type candidate = { provider : provider; tier : tier; model : string }

(** Per-persona policy, loaded from
    .masc/personas/<name>.toml [admission] block. *)
type persona_policy = {
  candidates : candidate list;       (* ordered by tier × persona pref *)
  weight : int;                       (* WFQ weight, default 1 *)
  min_tier : tier;                    (* never accept below this *)
}

(** Pure: returns ordered candidate list at decision time. May
    reorder based on live trust_score (RFC-0009) and recent
    success rate. *)
val candidates_for : keeper_id -> world_state -> candidate list

(** Admission decision. NEVER blocks. *)
type decision =
  | Dispatch of candidate
  | Wait                              (* enqueue in WFQ *)
  | Surface of surface_reason         (* min_tier violated → operator alert *)

val schedule : keeper_id -> world_state -> decision
```

Decision algorithm (pseudocode):

```
schedule(k, w):
  for c in candidates_for(k, w):
    if c.tier < persona[k].min_tier: continue
    if Provider_token_bucket.try_acquire(c.provider):
      log_dispatch ~keeper:k ~preferred:(top candidates) ~actual:c
                   ~tier:c.tier ~reason:"token_acquired"
      return Dispatch c
  if any_candidate_above_min_tier_throttled then return Wait
  else return Surface Min_tier_unsatisfiable
```

Note `min_tier`: the user explicitly rejected `strict drift_tolerance`
(would violate I1). `min_tier` is preserved as a quality floor: if
*even Survival tier is unavailable*, the keeper does not silently get
served by an unacceptable model — operator sees a `Surface` event.

### 3.4 Layer 3 — WFQ overflow queue

Module: `lib/keeper/keeper_wfq_overflow.{ml,mli}`

```ocaml
type entry = {
  keeper_id : string;
  weight : int;        (* from persona_policy.weight *)
  enqueued_at : float;
}

(** O(log N) insert via deficit-counter heap. *)
val enqueue : entry -> unit

(** Wake exactly one entry on each provider refill event. The chosen
    entry is the one with highest deficit_counter / weight ratio.
    Returns None if queue empty. *)
val wake_one : unit -> entry option

(** O(N) snapshot for dashboards. *)
val snapshot : unit -> entry list
```

Hooked into Layer 1: `Provider_token_bucket.on_refill (fun () ->
match wake_one () with Some e -> retry_admission e | None -> ())`.

WFQ guarantees (Shreedhar-Varghese 1996): per-flow fairness deviation
≤ 2 × max_packet_size. Translated to admission: `wait(k) ≤
T_overflow_max = 2 × T_max_turn / weight_ratio`. Bounded.

### 3.5 Drift observability

Single Prometheus counter:
```
masc_admission_dispatch_total{keeper, preferred_provider, actual_provider, tier, reason}
```
Where `tier ∈ {preferred, acceptable, survival}` and `reason ∈
{token_acquired, fallback, overflow_wake, recovery}`.

Plus a per-keeper drift log line emitted at INFO level on every
dispatch where `preferred ≠ actual`. The user's "왜 갑자기 GLM 답?"
becomes a one-liner grep.

### 3.6 Capacity-shortfall semantics (Σλ > Σμ)

When *no* keeper-compatible provider has positive long-run rate:

| Strategy | Trigger | Behavior |
|---|---|---|
| **A. Tick stretch** | `wfq_overflow.depth > N_keeper × 2` for 5 min | autonomously increase keeper.tick_interval; turn count drops, but I1 holds |
| **B. Priority shed** | A insufficient | `min_tier=Survival` keepers skip turns first, with surface event |
| **C. Hard surface** | B insufficient | `Surface Capacity_exhausted` to operator, no turn dispatched |

These do not violate I1 — they respect I1 by *changing what
"eventually-progresses" means* (longer interval) rather than silently
dropping turns. All three transitions are operator-visible.

## 4. Migration plan

### 4.1 PR series (5 PRs)

| PR | Scope | LOC est. | Dependencies |
|---|---|---|---|
| PR-A | Provider_token_bucket module + admission.toml schema + unit tests | ~600 | none |
| PR-B | Persona_policy schema + 14 persona migration + parser + tests | ~700 | PR-A |
| PR-C | Admission_router + wfq_overflow + integration tests | ~800 | PR-A, PR-B |
| PR-D | TLA+ KeeperAdmissionLiveness.tla + clean/buggy cfg + bug actions | ~500 | PR-B (depends on persona schema) |
| PR-E | Replace global semaphores in keeper_turn_slot.ml; deprecate env vars; drift-log cutover | ~400 | PR-A, PR-B, PR-C |

Total: ~3000 LOC including tests. 1.5-2 weeks.

Each PR is independently mergeable except PR-E which is the swap-in.

### 4.1.1 PR-E split — actual implementation breakdown

PR-E in §4.1 was scoped as a single swap-in. During implementation
it split along risk boundaries:

| Sub-PR | Scope | LOC | Status | Risk |
|---|---|---|---|---|
| PR-E-1 | Glue module (`keeper_admission_glue.{ml,mli}`) — flag-gated decide entry point | ~100 | MERGED #12939 | Low (additive) |
| PR-E-1.5 | Registry module (`keeper_admission_registry.{ml,mli}`) — JSON loader for `[admission.<keeper>]` blocks | ~110 | MERGED #12939 | Low (additive) |
| **PR-E-1.6** | **Runtime wiring** — registry+bucket singletons, cascade.toml integration, heartbeat call site | **~150** | **PENDING** | **High (live runtime)** |
| PR-E-2 | Semaphore retire — remove `keeper_turn_slot.ml` lines 38/101/114 + acquire_bounded + holder_table | ~200 | After §7 acceptance | High (legacy removal) |

#### PR-E-1.6 — three-step wiring

The merged PR-E modules are *dormant code* until PR-E-1.6 lands. The
flag `MASC_ADMISSION_USE_NEW=true` has no observable effect because
no caller invokes `Keeper_admission_glue.decide`.

PR-E-1.6 wires three things:

1. **Registry init at startup**
   - Hook into `cascade_config_loader` JSON output
   - Build `Keeper_admission_registry.t` once at process start
   - Cache reference accessible from heartbeat loop
   - Re-build on cascade.toml mtime change (existing reload path)

2. **Bucket lookup wiring**
   - Singleton `(string, Keeper_provider_token_bucket.t) Hashtbl.t`
   - Populated from `[admission.<keeper>].candidates[].provider`
     unique provider set + per-provider `[provider.<id>].rate_per_sec`
   - Lookup function `string -> KPTB.t option` plugs into
     `Keeper_admission_glue.decide`

3. **Heartbeat call-site change** at `keeper_heartbeat_loop.ml:591`:
   ```ocaml
   match Keeper_admission_glue.decide
           ~keeper_id:meta_after_triage.name
           ~policies:Keeper_admission_runtime.policy_lookup
           ~buckets:Keeper_admission_runtime.bucket_lookup
   with
   | Legacy_path ->
       (* existing with_keeper_turn_slot path — unchanged *)
       Keeper_turn_slot.with_keeper_turn_slot ~keeper_name ~channel ...
   | New_admission (Dispatch { candidate; drift }) ->
       Keeper_admission_drift.record drift;
       (* run cycle directly without semaphore wait *)
       Keeper_unified_turn.run_keeper_cycle ~candidate ...
   | New_admission Wait ->
       Keeper_wfq_overflow.enqueue ~keeper_id;
       Prometheus.inc_counter metric_keeper_admission_wait;
       skip_turn  (* WFQ wakes us next tick *)
   | New_admission (Surface Min_tier_unsatisfiable) ->
       Log.error "%s: min_tier unsatisfiable, no candidate provider configured" ...;
       Prometheus.inc_counter metric_keeper_admission_surface;
       skip_turn
   ```

#### Layering note (resolved during planning)

`with_keeper_turn_slot` currently bundles three concerns: semaphore
admission, fairness cooldown, watchdog instrumentation. The router
only replaces the *admission* concern. PR-E-1.6 keeps the fairness
+ watchdog wrapping for the `Legacy_path` branch and inlines them
into the `New_admission Dispatch` branch (record_semaphore_wait
→ run_keeper_cycle without the slot acquire). PR-E-2 unifies them
under a thin `Keeper_turn_envelope` wrapper that no longer holds a
semaphore.

#### Rollout order

1. PR-E-1.6 lands as **shadow mode** first: call decide, record
   what it *would have done* via Prometheus counters, but always
   fall through to legacy. ~24h observation period to validate
   registry + bucket wiring is correct.
2. Flip flag for cohort A (7 keepers) → real swap. Cohort B (7
   keepers) stays on legacy as control.
3. 24h A/B per §7 acceptance criterion.
4. PR-E-2 ships once acceptance met.

### 4.2 Backward compatibility

PR-A through PR-D add new modules without touching existing code
paths. The system runs on the old semaphore model until PR-E lands.

PR-E removes:
- `keeper_turn_slot.ml` semaphore creation (lines 38, 101, 114)
- `MASC_KEEPER_AUTONOMOUS_CONCURRENCY` / `MASC_KEEPER_AUTOBOOT_MAX` /
  `MASC_KEEPER_REACTIVE_CONCURRENCY` / `MASC_KEEPER_AUTONOMOUS_SLOT_WAIT_TIMEOUT_SEC`
  → tag deprecated with `Log.warn` if set; ignored at runtime.
- `acquire_bounded`, `holder_table`, `peers holding slot` log path.

Adds:
- `admission_router.schedule` as the single entry point.
- new `.masc/config/admission.toml` (template + example shipped).

### 4.3 Validation gate (PR-D, mandatory before PR-E)

TLA+ spec mirrors `KeeperOASAdvanced.tla` pattern (memory:
`feedback_fsm_guard_identity_helper_counter_wrap_pattern`):

- `KeeperAdmissionLiveness.tla` — clean spec, must satisfy
  `LivenessInvariant == \A k. []<>(state[k] = "Dispatched")`.
- `KeeperAdmissionLiveness-buggy.cfg` — `Next \/ BugAction_GreedyKeeper`,
  must violate LivenessInvariant. BugAction = "one keeper monopolises
  acquisition by skipping WFQ enqueue".
- `KeeperAdmissionLiveness-buggy-2.cfg` — `Next \/ BugAction_LeakedToken`,
  models token bucket release omission. Must violate I3 (Rate-Respect).

Both buggy cfgs MUST violate. If any passes, the invariant is too
weak and the spec rejected.

## 5. Risks and trade-offs

### 5.1 Hot-reload of admission.toml may produce mid-flight inconsistency

**Mitigation**: copy-on-write. Reload allocates a new bucket table;
in-flight tokens drain against the old table; new admissions hit the
new table. Crossover is one-time and side-effect-free.

### 5.2 Per-provider token bucket assumes provider rate is known

In practice, rate limits are vendor-published but vary by tier and
time-of-day. PR-A ships static config; PR-F (out of scope) may add
dynamic rate inference from 429 / RetryAfter headers.

Static config is a *floor* — buckets refilled below the real rate
under-utilise the provider but never exceed quota. Conservative.

### 5.3 WFQ deficit counter unbounded growth

In OCaml `int` is 63-bit. Even at 1M dispatch/sec the counter wraps
in ~290,000 years. Not a concern. We use signed int and assert
no negative.

### 5.4 PR-E is a semaphore-removal swap. Risk = high.

Mitigations:
- PR-E ships behind `MASC_ADMISSION_USE_NEW=true` env flag, defaulting
  to *off* for one week.
- A/B test: 7 of 14 keepers on new admission, 7 on legacy semaphore.
  Skip-turn rate measured side-by-side.
- TLA+ spec is the precondition for PR-E (PR-D blocks PR-E).

### 5.5 Memory `feedback_observability-and-test-layers-emerge-during-implementation`

History: RFC §6 plan of 7 PRs grew to 11 PRs in implementation. We
expect this RFC's 5 PRs to grow to 7-8. Reserved scope: telemetry
PR (Prometheus dashboard JSON) and decision-table property tests.

## 6. Out of scope

- Provider authentication / credential rotation (RFC-0019)
- Cascade attempt streaming liveness (RFC-0022)
- Mid-turn watchdog (RFC-0012)
- Provider trust score aging (RFC-0009)
- Dynamic rate inference from 429 responses (deferred PR-F)
- Cross-cluster admission (single-host only)
- Cost-aware routing (deferred — orthogonal to liveness)

## 7. Acceptance

This RFC is accepted when:
- A reviewer has signed off on §3 design (boundaries + invariants).
- TLA+ spec PR-D is drafted and discussed (need not be merged before §3 review).
- `MASC_ADMISSION_USE_NEW=true` A/B comparison shows skip-turn rate
  reduced by ≥ 95% over 24h on the experimental fleet vs control.
