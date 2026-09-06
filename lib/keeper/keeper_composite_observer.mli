(** Keeper Composite Lifecycle Observer — pure projection.

    Projects a [Keeper_registry.registry_entry] into a composite snapshot
    spanning Decision / Runtime / Memory sub-FSMs as
    specified in RFC-0003.

    Contract:
    - Pure read. No mutation, no I/O, no event emission.
    - Never calls [Keeper_state_machine.apply_event],
      [Keeper_runtime_routing.select_runtime], or any routine that would
      shift keeper lifecycle state.
    - Does not read provider names, token counts, or context bytes —
      those belong to AGENT_CORE (see [feedback_masc-agent_core-layer-boundary]).

    Current scope: all projected sub-FSM live states are written directly
    into [Keeper_registry.registry_entry]. The observer no longer infers
    decision/runtime state from coarse parent conditions.

    @since RFC-0003 — Composite observer v0. *)

type turn_phase = Keeper_registry.turn_phase =
  | Turn_idle
  | Turn_prompting
  | Turn_routing
  | Turn_executing
  | Turn_finalizing
  | Turn_exhausted

type decision_stage = Keeper_registry.decision_stage =
  | Decision_undecided
  | Decision_guard_ok
  | Decision_tool_policy_selected

type runtime_state = string


(** Named composite invariants, one variant per {!invariants_check} field. *)
type invariant_key =
  | Invariant_no_runtime_before_measurement
  | Invariant_event_priority_monotone
  | Invariant_phase_derivation_agreement

(** Composite-level safety invariants.
    Each field is [true] when the invariant holds for the observed
    snapshot. A [false] value signals a composite-level safety violation
    that the dashboard should surface to the operator. *)
type invariants_check = {
  no_runtime_before_measurement : bool;
  event_priority_monotone : bool;
  phase_derivation_agreement : bool;
}

(** Increment [masc_keeper_invariant_violations_total\{keeper, invariant\}]
    once per violated invariant. No-op when all invariants hold. Called
    automatically from [observe]; exposed so unit tests can assert the
    counter bump without going through the full snapshot pipeline. *)
(** {2 Pure invariant predicates}

    The [check_*] functions below are the conjuncts of the composite
    safety invariant plus the runtime phase-derivation agreement check.
    They are exposed so tests can drive state combinations through the
    same predicates production [compute_invariants] uses, without having
    to construct a full {!Keeper_registry.registry_entry} value.
    [test/test_event_priority_monotone_pbt.ml] does this for
    {!check_event_priority_monotone_pure}; the other four have no test of
    their own.

    Pure: no side effects, no clock, no I/O. *)



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

(** Pure predicate for [EventPriorityMonotone]: at most one measurement
    binding per turn, and a live measurement excludes a pending one. *)
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
    is quiet ([keeper_paused], [reactive_disabled],
    [scheduled_autonomous_disabled]) without reading the aggregate
    Otel skip counter. [None] until the first skip is observed. *)
type last_skip = {
  ls_ts : float;
  ls_reasons : string list;
}

(** Objective turn-attempt history mirrored from
    [registry_entry.turn_attempt_state]. It is observability-only and never
    controls execution. *)
type turn_attempt = {
  ta_turn_id : int;
  ta_attempts : int;
  ta_first_started_at : float;
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
      (** Raw Keeper lifecycle phase. Previously
          collapsed to a 7-state projection for dashboard brevity; now exposed
          raw so the fleet matrix renders every state with its own chip colour.
          The lifecycle alphabet matches
          [specs/keeper-state-machine/KeeperStateMachine.tla] exactly. *)
  ktc_turn_phase : Keeper_registry.packed_turn_phase;
  kdp_decision : Keeper_registry.packed_decision_stage;
  kcl_runtime_state : runtime_state;
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
  turn_attempt : turn_attempt option;
      (** Current turn-attempt observation. *)
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
  idle_seconds : int;
      (** Wall-clock seconds since the keeper last did something the
          metrics layer treated as substantive. Observation only. *)
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
    observer is driven from a known event envelope (AGENT_CORE event_bus
    envelope, PR agent-core boundary). When absent, the snapshot uses
    [keeper:<name>:<transition_seq>] as a stable identifier so repeated
    reads within the same keeper transition return the same id. *)

val observe :
  ?correlation_id:string ->
  ?run_id:string ->
  ?now:float ->
  Keeper_registry.registry_entry ->
  snapshot

val turn_phase_to_string : Keeper_registry.packed_turn_phase -> string

(** Stringify [decision_stage]. Mirrors KeeperDecisionPipeline.tla. *)
(** Stringify the runtime-state compatibility field. *)

(** Serialise a snapshot as the [/api/keepers/:name/composite] payload
    documented in RFC-0003 §7. *)
val snapshot_to_json : snapshot -> Yojson.Safe.t
