(** Keeper Composite Lifecycle Observer — pure projection.

    Projects a [Keeper_registry.registry_entry] into a composite snapshot
    spanning Decision / Runtime / Memory / Compaction sub-FSMs as
    specified in RFC-0003 and
    [specs/keeper-state-machine/KeeperCompositeLifecycle.tla].

    Contract:
    - Pure read. No mutation, no I/O, no event emission.
    - Never calls [Keeper_state_machine.apply_event],
      [Keeper_runtime_routing.select_runtime], or any routine that would
      shift keeper lifecycle state.
    - Does not read provider names, token counts, or context bytes —
      those belong to OAS (see [feedback_masc-oas-layer-boundary]).

    Current scope: all projected sub-FSM live states are written directly
    into [Keeper_registry.registry_entry]. The observer no longer infers
    decision/runtime/compaction state from coarse parent conditions.

    @since RFC-0003 — Composite observer v0. *)

type turn_phase = Keeper_registry.turn_phase =
  | Turn_idle
  | Turn_prompting
  | Turn_routing
  | Turn_executing
  | Turn_compacting
  | Turn_finalizing
  | Turn_exhausted

val all_turn_phases : Keeper_registry.packed_turn_phase list

type decision_stage = Keeper_registry.decision_stage =
  | Decision_undecided
  | Decision_guard_ok
  | Decision_gate_rejected
  | Decision_tool_policy_selected

val all_decision_stages : Keeper_registry.packed_decision_stage list

type runtime_state = string

val all_runtime_states : runtime_state list

type compaction_stage = Keeper_registry.compaction_stage =
  | Compaction_accumulating
  | Compaction_compacting
  | Compaction_done

val all_compaction_stages : Keeper_registry.packed_compaction_stage list

(** Named TLA actions mirrored as OCaml variants so the observer contract
    can stay 1:1 with [KeeperCompositeLifecycle.tla]. *)
type tla_action =
  | Action_start_turn
  | Action_measurement_broadcast
  | Action_decide_guard
  | Action_select_tool_policy
  | Action_start_runtime_selection
  | Action_select_runtime
  | Action_gate_rejected
  | Action_runtime_done
  | Action_runtime_exhausted
  | Action_finish_turn
  | Action_start_compaction
  | Action_finish_compaction
  | Action_enter_failing
  | Action_clear_failing
  | Action_enter_overflowed
  | Action_overflowed_auto_compact

val all_tla_actions : tla_action list

(** Named TLA invariants mirrored as OCaml variants. *)
type invariant_key =
  | Invariant_phase_turn_alignment
  | Invariant_no_runtime_before_measurement
  | Invariant_compaction_atomicity
  | Invariant_event_priority_monotone
  | Invariant_phase_derivation_agreement

val all_invariant_keys : invariant_key list

(** Safety invariants from KeeperCompositeLifecycle.tla.
    Each field is [true] when the invariant holds for the observed
    snapshot. A [false] value signals a composite-level safety violation
    that the dashboard should surface to the operator. *)
type invariants_check = {
  phase_turn_alignment : bool;
  no_runtime_before_measurement : bool;
  compaction_atomicity : bool;
  event_priority_monotone : bool;
  phase_derivation_agreement : bool;
}

(** Increment [masc_keeper_invariant_violations_total\{keeper, invariant\}]
    once per violated invariant. No-op when all invariants hold. Called
    automatically from [observe]; exposed so unit tests can assert the
    counter bump without going through the full snapshot pipeline. *)
val bump_invariant_violations :
  keeper_name:string -> invariants_check -> unit

(** {2 Pure invariant predicates}

    The [check_*] functions below mirror the composite TLA+
    [SafetyInvariant] conjuncts and the runtime phase-derivation
    agreement check. They are exposed so cross-FSM joint tests
    ([test/test_keeper_fsm_joints.ml]) can drive realistic state
    combinations through the same predicates that production
    [compute_invariants] uses, without having to construct a full
    {!Keeper_registry.registry_entry} value.

    Pure: no side effects, no clock, no I/O. *)

(** Mirror of TLA+ I1 [PhaseTurnAlignment] (KeeperCompositeLifecycle.tla:354):
    when KSM is in [Compacting], the turn phase must also be
    [Turn_compacting]; conversely no other KSM phase may carry a live
    [Turn_compacting]. *)
val check_phase_turn_alignment : Keeper_state_machine.phase -> Keeper_registry.packed_turn_phase -> bool

(** Mirror of TLA+ I3 [CompactionAtomicity] (KeeperCompositeLifecycle.tla:368):
    [(kmc_compaction = compacting) <=> (phase = Compacting)]. *)
val check_compaction_atomicity : Keeper_state_machine.phase -> Keeper_registry.packed_compaction_stage -> bool

(** Mirror of TLA+ I2 [NoRuntimeBeforeMeasurement]
    (KeeperCompositeLifecycle.tla:361): runtime selection past [idle]
    requires a captured measurement. *)
val check_no_runtime_before_measurement :
  runtime_state:runtime_state -> measurement_captured:bool -> bool

val check_phase_derivation_agreement :
  Keeper_registry.registry_entry -> bool
(** Runtime-visible mirror of
    [Keeper_invariant_check.DerivePhaseAgreement]: the recorded registry
    phase must equal [Keeper_state_machine.derive_phase conditions]. *)

(** Minimal state extracted from {!Keeper_registry.registry_entry} for
    the [EventPriorityMonotone] invariant. Separating this type allows
    QCheck property tests to exercise the predicate without constructing
    a full registry entry (~20 fields). *)
type event_priority_state = {
  ep_measurement_bind_count : int;
  ep_has_measurement : bool;
  ep_has_pending_measurement : bool;
}

(** Pure predicate for TLA+ I4 [EventPriorityMonotone]
    (KeeperCompositeLifecycle.tla:374): at most one measurement binding
    per turn, and a live measurement excludes a pending one. *)
val check_event_priority_monotone_pure : event_priority_state -> bool

(** Frozen outcome of the most recently completed turn (RFC-0003
    Phase 2). Surfaces terminal data ([Done]/[Guard_ok]/...) without
    polluting the live sub-FSM fields. [None] until the first turn
    has finished after registration. *)
type last_outcome = {
  turn_id : int;
  ended_at : float;
  decision_stage : Keeper_registry.packed_decision_stage;
  runtime_state : runtime_state;
  selected_model : string option;
}

(** Live turn timing, surfaced separately from [last_outcome] so dashboard
    enrichers can tell whether a terminal receipt belongs to the current
    turn or to a previous one. *)
type live_turn = {
  turn_id : int;
  started_at : float;
      (** Unix timestamp when the current turn observation was installed. *)
  last_progress_at : float;
      (** Unix timestamp of the most recent in-turn progress signal. *)
  last_progress_kind : string option;
      (** Low-cardinality label for the signal that refreshed
          [last_progress_at]. *)
  selected_model : string option;
      (** Surface model selected for the live turn, mirrored from
          [turn_observation.selected_model]. Exposed so the dashboard can
          show what model a running turn is on, not only the post-turn
          [last_outcome]. [None] before runtime selection. *)
  active_tool_count : int;
      (** Tools issued but not yet completed on the live turn, mirrored
          from [turn_observation.active_tool_count]. [0] outside any tool
          call. *)
  wake : Keeper_registry.wake_reason;
      (** What triggered this turn, mirrored from [turn_observation.wake]
          (#16, 38-bug campaign PR-5). *)
}

(** Most recent deliberate skip verdict, mirrored from
    [registry_entry.last_skip_observation]. Surfaces {i why} an idle keeper
    is quiet ([cooldown_pending], [no_signal],
    [scheduled_autonomous_disabled], ...) without reading the aggregate
    Otel skip counter. [None] until the first skip is observed. *)
type last_skip = {
  ls_ts : float;
  ls_reasons : string list;
}

(** Turn-livelock retry history, mirrored from
    [registry_entry.livelock_state]. [Some _] while the turn-livelock guard
    is tracking retries for the current turn; [None] when no livelock is in
    progress. *)
type livelock = {
  ll_turn_id : int;
  ll_attempts : int;
  ll_first_started_at : float;
}

(** Board consumption cursor, mirrored from
    [registry_entry.board_cursor_ts] / [board_cursor_post_id]. Lets
    operators see how far a keeper has consumed the shared board. *)
type board_cursor = {
  bc_ts : float;
  bc_post_id : string option;
}

(** Total run-state classification (#16, 38-bug campaign PR-5). Previously
    the dashboard collapsed "actively executing a turn", "idle waiting for
    proactive cadence", and "reactively woken (and by what stimulus)" into
    a single "진행 중 / 실행 중" label. Precedence: [phase <> Running]
    always yields [Suspended] (the phase itself explains why the keeper is
    not runnable); otherwise a live turn yields [In_turn]; otherwise
    [Waiting]. *)
type run_state =
  | In_turn of {
      rs_wake : Keeper_registry.wake_reason;
      rs_started_at : float;
      rs_active_tool_count : int;
    }
  | Waiting of {
      rs_queue_depth : int;
          (** [Keeper_event_queue.length] of the entry's event queue at
              observation time — stimuli already enqueued but not yet
              drained by a turn. *)
      rs_last_skip : last_skip option;
    }
  | Suspended of Keeper_state_machine.phase

val run_state_of_entry :
  Keeper_registry.registry_entry -> last_skip:last_skip option -> run_state
(** Pure derivation, exposed so other server surfaces (Bonsai
    keepers/summary row, [masc_keeper_list] detailed rows) can classify a
    registry entry directly instead of re-deriving a full {!snapshot}. *)

val run_state_to_json : run_state -> Yojson.Safe.t
(** [{"kind": "in_turn" | "waiting" | "suspended"; ...}]. See [.ml] for the
    exact per-kind shape. *)

val wake_reason_kind_and_stimuli : Keeper_registry.wake_reason -> string * string list
(** [("proactive_tick", [])] or [("woken", <stimulus kind labels>)].
    Exposed so non-JSON consumers (Bonsai [keepers/summary] row, which has
    its own typed wire record) can project a {!run_state}'s wake without
    round-tripping through {!run_state_to_json}. *)

type fsm_guard_violation_bucket = {
  action : string;
      (** Low-cardinality [action] label from
          [masc_fsm_guard_violation_total]. *)
  stage : string;
      (** Low-cardinality [stage] label from
          [masc_fsm_guard_violation_total]. *)
  count : int;
      (** Current counter value for the [(action, stage)] label pair. *)
}

type snapshot = {
  keeper_name : string;
      (** Canonical keeper identity from the registry entry. This is separate
          from [correlation_id], which may come from an external event envelope
          and is not a stable row key for fleet dashboards. *)
  correlation_id : string;
  run_id : string;
  ts : float;
  phase : Keeper_state_machine.phase;
      (** Full 13-state keeper phase (RFC-0002, post-Zombie #14707). Previously
          collapsed to a 7-state projection for dashboard brevity; now exposed
          raw so the fleet matrix renders every state with its own chip colour.
          The 13-state alphabet matches
          [specs/keeper-state-machine/KeeperStateMachine.tla] exactly. *)
  ktc_turn_phase : Keeper_registry.packed_turn_phase;
  kdp_decision : Keeper_registry.packed_decision_stage;
  kcl_runtime_state : runtime_state;
  kmc_compaction : Keeper_registry.packed_compaction_stage;
  kcb_state : Keeper_failure_circuit_breaker.display_state;
      (** 6th axis (LT-16-KCB). Observable circuit-breaker state —
          never [Tripped] because the mutator resets [consecutive_count]
          before snapshots can see it. See
          {!Keeper_failure_circuit_breaker.display_state}. *)
  shared_measurement : Keeper_state_machine.context_actions option;
  invariants : invariants_check;
  conditions : Keeper_state_machine.conditions;
      (** Raw observable conditions that derive [raw_phase]. Exposed for
          dashboard diagnostics; callers should not infer composite state from
          this when the dedicated axes above are present. *)
  is_live : bool;
      (** [true] when [current_turn_observation] is [Some] — a turn is
          actively executing and the live sub-FSM fields reflect its
          state. [false] indicates an idle keeper; sub-FSM fields
          revert to [Idle]/[Undecided]. *)
  live_turn : live_turn option;
      (** Current live turn timing. [Some _] iff [is_live = true]. This is
          the causality boundary used by dashboard enrichers before treating
          the latest terminal receipt as a current blocker. *)
  run_state : run_state;
      (** Total classification of what the keeper is doing right now
          (#16, 38-bug campaign PR-5): actively executing a turn (and why
          it woke), idle waiting for the proactive cadence, or suspended by
          a non-[Running] phase. Never [In_turn] without [live_turn = Some
          _], and vice versa. *)
  last_outcome : last_outcome option;
      (** Most recent completed turn, surfaced separately from live
          state so operators can see "what just finished" without
          confusing it with "what's running now". *)
  last_skip : last_skip option;
      (** Most recent deliberate skip verdict from the keepalive cycle.
          [None] until the first skip is observed. Lets operators diagnose
          {i why} a quiet keeper is idle instead of only seeing that it is. *)
  livelock : livelock option;
      (** Turn-livelock retry state. [None] when no livelock is in
          progress. *)
  board_cursor : board_cursor;
      (** Board consumption cursor (ts + last consumed post id). Always
          present; [ts = 0.0] / [post_id = None] before the keeper has
          consumed any board post. *)
  board_wakeups : int;
      (** Number of distinct board-wakeup dedup keys currently held.
          The registry keeps a content-fingerprint debounce ledger
          ([board_wakeups : float StringMap.t], cleared per turn); this
          field projects its cardinality so the dashboard can show how many
          board stimuli woke the keeper in the current window without
          leaking the high-cardinality fingerprint keys. *)
  fiber_stop_flag : bool;
      (** Snapshot of [registry_entry.fiber_stop] at observation time.
          When [true] without a corresponding stopped/dead phase, the
          keepalive loop will exit on its next iteration — used to
          discriminate fiber-supervisor wedge from cycle-gate wedge in
          fleet silence diagnoses. *)
  fiber_wakeup_flag : bool;
      (** Snapshot of [registry_entry.fiber_wakeup]. [true] means a
          wake signal is queued; the next [interruptible_sleep] chunk
          will return early. Stale [true] points at a wake source
          that was set but never consumed. *)
  consecutive_noop_count : int;
      (** Lifetime [consecutive_noop_count] from the proactive runtime.
          Increments per cycle that produced no text and only used
          observation-only tools; resets on substantive output. Reaching
          ≥2 caps the noop backoff multiplier at 4x. *)
  idle_seconds : int;
      (** Wall-clock seconds since the keeper last did something the
          metrics layer treated as substantive. Compared against
          [proactive.idle_sec] to gate scheduled-autonomous turns. *)
  last_turn_ts : float;
      (** Raw [runtime.usage.last_turn_ts] from the registry entry.
          Exposed for watchdog staleness diagnosis — the stale watchdog
          in [Keeper_supervisor] reads this exact field. A value of [0.0]
          means the registry never recorded a completed turn. *)
  fsm_guard_violations : int;
      (** Runtime [@@fsm_guard] assertion violations observed fleet-wide
          since process start. Bumped by
          [Keeper_fsm_guard_runtime.wrap_unit] on every invariant breach.
          Exposed in the dashboard FSM matrix top strip so operators can
          spot spec-drift without reading logs. *)
  fsm_guard_violation_breakdown : fsm_guard_violation_bucket list;
      (** Bounded fleet-wide breakdown of [fsm_guard_violations] by
          [(action, stage)] label. The total is still fleet-wide because
          [@@fsm_guard] call sites do not all carry a keeper label; this
          field makes the runtime monitor actionable by identifying the
          specific guard source that is currently firing. *)
}

(** Derive a composite snapshot from a live registry entry.

    [correlation_id] and [run_id] may be supplied by the caller when the
    observer is driven from a known event envelope (OAS event_bus
    envelope, PR OAS#845). When absent, the snapshot uses
    [keeper:<name>:<transition_seq>] as a stable identifier so repeated
    reads within the same keeper transition return the same id. *)

val observe :
  ?correlation_id:string ->
  ?run_id:string ->
  ?now:float ->
  Keeper_registry.registry_entry ->
  snapshot

(** Observe every registered keeper under [base_path] once. Used by
    [GET /api/v1/keepers/composite] to render fleet-level matrices
    (LT-16a). Preserves registry iteration order. *)
val all_snapshots : base_path:string -> unit -> snapshot list

val turn_phase_to_string : Keeper_registry.packed_turn_phase -> string
val turn_phase_of_string : string -> turn_phase option

(** Stringify [decision_stage]. Mirrors KeeperDecisionPipeline.tla. *)
val decision_stage_to_string : Keeper_registry.packed_decision_stage -> string
val decision_stage_of_string : string -> decision_stage option

(** Stringify the runtime-state compatibility field. *)
val runtime_state_to_string : runtime_state -> string
val runtime_state_of_string : string -> runtime_state option

(** Stringify [compaction_stage]. Mirrors KeeperCompactionLifecycle.tla. *)
val compaction_stage_to_string : Keeper_registry.packed_compaction_stage -> string
val compaction_stage_of_string : string -> compaction_stage option

val tla_action_to_string : tla_action -> string
val tla_action_of_string : string -> tla_action option

val invariant_key_to_string : invariant_key -> string
val invariant_key_of_string : string -> invariant_key option

(** Serialise a snapshot as the [/api/keepers/:name/composite] payload
    documented in RFC-0003 §7. *)
val snapshot_to_json : snapshot -> Yojson.Safe.t
