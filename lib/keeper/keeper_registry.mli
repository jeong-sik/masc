(** Keeper_registry — Single source of truth for keeper state.

    Replaces scattered state across keeper_keepalive Hashtbl,
    keeper_supervisor Hashtbl, and file-based meta lookups.
    All keeper state queries and mutations go through this module.

    Thread-safety: all operations are non-yielding (in-memory map/ref
    ops only).  In single-domain Eio, non-yielding code runs atomically
    w.r.t. other fibers, so no mutex is needed. *)

open Keeper_types

module StringMap : Map.S with type key = string

(** Structured failure reason for crash cohort detection. *)
type ambiguous_partial_commit_kind =
  | Post_commit_timeout
  | Post_commit_failure

type ambiguous_partial_commit = {
  kind : ambiguous_partial_commit_kind;
  detail : string;
}

(** Phase B PR-6 (2026-04-28): the stale watchdog's three distinct kill
    causes used to collapse into a single [Stale_turn_timeout of float]
    variant.  Operators / dashboards could not tell whether a kill was an
    idle stall (turn never started), an active turn hang (turn running
    too long), or a no-op failure loop (turn fired but produced no tool
    calls) — three different root causes that need different operator
    actions.  Splitting the payload preserves the [Stale_turn_timeout]
    cohort key so existing dashboards keep working, while exposing the
    typed sub-class to anything that wants to discriminate. *)
type stale_kill_class =
  | Idle_turn of { stall_seconds : float }
      (** [last_turn_ts] older than the idle threshold while the keeper
          phase is [Running] but no [current_turn_observation] is
          recorded. *)
  | In_turn_hung of {
      active_seconds : float;
      timeout_threshold : float;
    }
      (** A turn started ([current_turn_observation = Some]) and ran past
          [timeout_threshold] seconds. *)
  | Noop_failure_loop of { noop_count : int }
      (** Turns kept firing but produced no tool calls; the keepalive's
          [consecutive_noop_count] reached the watchdog threshold. *)

val stale_kill_class_to_string : stale_kill_class -> string
(** Operator-facing label.  Used in [failure_reason_to_string] for the
    [Stale_turn_timeout] arm and exposed for dashboards / metrics that
    want to attribute kills by class. *)

type failure_reason =
  | Heartbeat_consecutive_failures of int
  | Turn_consecutive_failures of int
  | Stale_turn_timeout of stale_kill_class
  | Stale_termination_storm of { count : int }
      (** #10765 Phase 2: latched when [record_stale_termination] returns a
          window count >= [escalation_threshold]. The supervisor's
          [`Crashed] branch checks this variant and skips [to_restart],
          persisting [meta.paused = true] instead so an operator must
          investigate the underlying cascade/provider/fd issue before
          resuming the keeper. *)
  | Stale_fleet_batch of { distinct_count : int }
      (** Latched when the stale watchdog observes several distinct keepers
          terminating inside the fleet batch window. This is a systemic
          cascade/provider/runtime signal, so the supervisor pauses affected
          keepers with auto-resume backoff instead of restarting each keeper
          independently into the same failure mode. *)
  | Oas_timeout_budget_loop of { count : int }
      (** Latched when the same keeper exhausts the OAS turn budget on
          consecutive cycles. This is a provider/cascade/runtime throughput
          failure, so the supervisor pauses instead of restarting into the
          same slow model and burning another multi-minute budget. *)
  | Provider_runtime_error of { code : string; detail : string }
      (** Latched from the keeper turn terminal reason when the provider,
          adapter, or cascade fails before useful keeper progress. A later
          idle watchdog should preserve this root cause instead of recasting
          the keeper as generically stale. *)
  | Tool_required_unsatisfied of { code : string; detail : string }
      (** Latched when an actionable required-tool turn returned no useful
          keeper tool progress. *)
  | Ambiguous_partial_commit of ambiguous_partial_commit
  | Fiber_unresolved
  | Exception of string

val ambiguous_partial_commit_kind_to_string :
  ambiguous_partial_commit_kind -> string

val failure_reason_to_string : failure_reason -> string

(** #10584: cohort key for grouping failures by variant (ignores
    parameters). [None] returns ["unknown"]. New variants added to
    [failure_reason] force a same-PR update of this function via
    OCaml's exhaustive-match check — Option B mitigation for the
    recurring P0 pattern (#10490, #10574). *)
val failure_reason_cohort_key : failure_reason option -> string

val stale_watchdog_failure_reason :
  prior:failure_reason option -> kill_class:stale_kill_class -> failure_reason option
(** Preserve authoritative terminal failure reasons when the stale watchdog
    fires after a failed turn, but do not carry stale-watchdog cohort labels
    across fresh watchdog kills. Storm/fleet labels are relatched only by the
    current threshold or batch detector. *)

(** Pure control-flow signal for immediate fiber termination (RFC-0002).
    Carries no state — failure reason must be pre-stored via
    [set_failure_reason] before raising. *)
exception Keeper_fiber_crash

type turn_phase =
  | Turn_idle [@tla.idle]
  | Turn_prompting [@tla.active]
  | Turn_routing [@tla.active]
  | Turn_executing [@tla.active]
  | Turn_compacting [@tla.active]
  | Turn_finalizing [@tla.active]
  | Turn_exhausted [@tla.terminal]
[@@deriving tla]

(** {1 Turn phase GADT infrastructure (Cycle 21 / Tier B5)} *)

type turn_idle
type turn_prompting
type turn_routing
type turn_executing
type turn_compacting
type turn_finalizing
type turn_exhausted

type 'a turn_phase_witness =
  | Turn_idle : turn_idle turn_phase_witness
  | Turn_prompting : turn_prompting turn_phase_witness
  | Turn_routing : turn_routing turn_phase_witness
  | Turn_executing : turn_executing turn_phase_witness
  | Turn_compacting : turn_compacting turn_phase_witness
  | Turn_finalizing : turn_finalizing turn_phase_witness
  | Turn_exhausted : turn_exhausted turn_phase_witness

type packed_turn_phase = Packed : 'a turn_phase_witness -> packed_turn_phase

val witness_to_turn_phase : packed_turn_phase -> turn_phase
val turn_phase_to_witness : turn_phase -> packed_turn_phase

(** Diagnostic label using the constructor name (e.g. ["Turn_routing"]).
    Used by [validate_turn_phase_transition] to embed the rejected pair
    in [Invalid_argument] messages.  Distinct from
    [Keeper_composite_observer.turn_phase_to_string] which emits a
    snake_case form for dashboards. *)
val packed_turn_phase_label : packed_turn_phase -> string

val validate_turn_phase_transition : from:packed_turn_phase -> to_:packed_turn_phase -> unit

module Turn_phase_transition : sig
  type ('from, 'to_) t =
    | Idle_to_idle : (turn_idle, turn_idle) t
    | Idle_to_prompting : (turn_idle, turn_prompting) t
    | Prompting_to_prompting : (turn_prompting, turn_prompting) t
    | Prompting_to_routing : (turn_prompting, turn_routing) t
    | Prompting_to_executing : (turn_prompting, turn_executing) t
    | Prompting_to_finalizing : (turn_prompting, turn_finalizing) t
    | Prompting_to_exhausted : (turn_prompting, turn_exhausted) t
    | Routing_to_prompting : (turn_routing, turn_prompting) t
    | Routing_to_routing : (turn_routing, turn_routing) t
    | Routing_to_executing : (turn_routing, turn_executing) t
    | Routing_to_exhausted : (turn_routing, turn_exhausted) t
    | Executing_to_prompting : (turn_executing, turn_prompting) t
    | Executing_to_routing : (turn_executing, turn_routing) t
    | Executing_to_executing : (turn_executing, turn_executing) t
    | Executing_to_compacting : (turn_executing, turn_compacting) t
    | Executing_to_finalizing : (turn_executing, turn_finalizing) t
    | Executing_to_exhausted : (turn_executing, turn_exhausted) t
    | Compacting_to_prompting : (turn_compacting, turn_prompting) t
    | Compacting_to_compacting : (turn_compacting, turn_compacting) t
    | Compacting_to_finalizing : (turn_compacting, turn_finalizing) t
    | Compacting_to_exhausted : (turn_compacting, turn_exhausted) t
    | Finalizing_to_prompting : (turn_finalizing, turn_prompting) t
    | Finalizing_to_routing : (turn_finalizing, turn_routing) t
    | Finalizing_to_executing : (turn_finalizing, turn_executing) t
    | Finalizing_to_finalizing : (turn_finalizing, turn_finalizing) t
    | Finalizing_to_exhausted : (turn_finalizing, turn_exhausted) t
    | Exhausted_to_prompting : (turn_exhausted, turn_prompting) t
    | Exhausted_to_routing : (turn_exhausted, turn_routing) t
    | Exhausted_to_executing : (turn_exhausted, turn_executing) t
    | Exhausted_to_exhausted : (turn_exhausted, turn_exhausted) t

  val to_tag : ('from, 'to_) t -> string
end

type decision_stage =
  | Decision_undecided [@tla.idle]
  | Decision_guard_ok [@tla.active]
  | Decision_gate_rejected [@tla.terminal]
  | Decision_tool_policy_selected [@tla.active]
[@@deriving tla]

(** {1 Decision stage GADT infrastructure (Cycle 21 / Tier B5)} *)

type decision_undecided
type decision_guard_ok
type decision_gate_rejected
type decision_tool_policy_selected

type 'a decision_stage_witness =
  | Decision_undecided : decision_undecided decision_stage_witness
  | Decision_guard_ok : decision_guard_ok decision_stage_witness
  | Decision_gate_rejected : decision_gate_rejected decision_stage_witness
  | Decision_tool_policy_selected : decision_tool_policy_selected decision_stage_witness

type packed_decision_stage = Packed : 'a decision_stage_witness -> packed_decision_stage

val witness_to_stage : 'a decision_stage_witness -> decision_stage
val stage_to_witness : decision_stage -> packed_decision_stage

(** Diagnostic label using the constructor name (e.g.
    ["Decision_guard_ok"]).  Used by [validate_decision_transition] for
    [Invalid_argument] messages. *)
val packed_decision_stage_label : packed_decision_stage -> string

val validate_decision_transition : from:decision_stage -> to_:decision_stage -> unit

module Decision_transition : sig
  type ('from, 'to_) t =
    | Undecided_to_guard_ok : (decision_undecided, decision_guard_ok) t
    | Undecided_to_gate_rejected : (decision_undecided, decision_gate_rejected) t
    | Undecided_to_tool_policy_selected : (decision_undecided, decision_tool_policy_selected) t
    | Guard_ok_to_gate_rejected : (decision_guard_ok, decision_gate_rejected) t
    | Guard_ok_to_tool_policy_selected : (decision_guard_ok, decision_tool_policy_selected) t
    | Gate_rejected_to_guard_ok : (decision_gate_rejected, decision_guard_ok) t
    | Gate_rejected_to_tool_policy_selected : (decision_gate_rejected, decision_tool_policy_selected) t
    | Tool_policy_selected_to_guard_ok : (decision_tool_policy_selected, decision_guard_ok) t
    | Tool_policy_selected_to_gate_rejected : (decision_tool_policy_selected, decision_gate_rejected) t

  val to_tag : ('from, 'to_) t -> string
end

type cascade_state =
  | Cascade_idle [@tla.idle]
  | Cascade_selecting [@tla.active]
  | Cascade_trying [@tla.active]
  | Cascade_done [@tla.terminal]
  | Cascade_exhausted [@tla.terminal]
[@@deriving tla]

(** {1 Cascade state GADT infrastructure (Cycle 21 / Tier B5)} *)

type cascade_idle
type cascade_selecting
type cascade_trying
type cascade_done
type cascade_exhausted

type 'a cascade_state_witness =
  | Cascade_idle : cascade_idle cascade_state_witness
  | Cascade_selecting : cascade_selecting cascade_state_witness
  | Cascade_trying : cascade_trying cascade_state_witness
  | Cascade_done : cascade_done cascade_state_witness
  | Cascade_exhausted : cascade_exhausted cascade_state_witness

type packed_cascade_state =
  | Packed : 'a cascade_state_witness -> packed_cascade_state

val cascade_state_to_witness : cascade_state -> packed_cascade_state
val witness_to_cascade_state : packed_cascade_state -> cascade_state

(** Diagnostic label using the constructor name (e.g.
    ["Cascade_exhausted"]).  Used by [validate_cascade_transition] for
    [Invalid_argument] messages. *)
val packed_cascade_state_label : packed_cascade_state -> string

val validate_cascade_transition : from:packed_cascade_state -> to_:packed_cascade_state -> unit

type compaction_stage =
  | Compaction_accumulating [@tla.idle]
  | Compaction_compacting [@tla.active]
  | Compaction_done [@tla.terminal]
[@@deriving tla]

(** {1 Compaction stage GADT infrastructure (Cycle 21 / Tier B5)} *)

type compaction_accumulating
type compaction_compacting
type compaction_done

type 'a compaction_stage_witness =
  | Compaction_accumulating : compaction_accumulating compaction_stage_witness
  | Compaction_compacting : compaction_compacting compaction_stage_witness
  | Compaction_done : compaction_done compaction_stage_witness

type packed_compaction_stage =
  | Packed : 'a compaction_stage_witness -> packed_compaction_stage

val compaction_stage_to_witness : compaction_stage -> packed_compaction_stage
val witness_to_compaction_stage : packed_compaction_stage -> compaction_stage

type turn_measurement = {
  tm_captured_at : float;
  tm_auto_rules : Keeper_state_machine.auto_rule_summary;
}

type registry_entry = {
  base_path : string;
  name : string;
  meta : keeper_meta;
  phase : Keeper_state_machine.phase;
      (** Keeper lifecycle phase (RFC-0002 11-state machine). *)
  conditions : Keeper_state_machine.conditions;
      (** Observable conditions that derive [phase]. *)
  fiber_stop : bool Atomic.t;
  fiber_wakeup : bool Atomic.t;
  event_queue : Keeper_event_queue.t Atomic.t;
      (** Event Layer queue for incoming stimuli. Independent of
          [fiber_wakeup] (which remains a hint signal). The Policy
          Layer turn must consult this queue at the start of every
          [emit] tick — see [specs/keeper-state-machine/KeeperEventQueue.tla]
          and the [TurnDequeue] action. *)
  started_at : float;
  grpc_close : (unit -> unit) option Atomic.t;
  done_p : [ `Stopped | `Crashed of string ] Eio.Promise.t;
  done_r : [ `Stopped | `Crashed of string ] Eio.Promise.u;
      (** Exposed so keeper lifecycle coordinators can resolve stop/crash exactly once.
          Callers must preserve a single terminal outcome per keeper run. *)
  restart_count : int;
  last_restart_ts : float;
  dead_since_ts : float option;
  crash_log : (float * string) list;
  last_error : string option;
  last_failure_reason : failure_reason option;
  turn_consecutive_failures : int;
  last_agent_count : int;
  board_wakeups : float StringMap.t;
  board_cursor_ts : float;
  board_cursor_post_id : string option;
  tool_usage : Keeper_types.tool_call_entry StringMap.t;
  transition_seq : int;
  waiting_for_inference : bool Atomic.t;
      (** Ephemeral flag: true when keeper is blocked in admission queue.
          Does not affect state machine phase derivation. *)
  last_auto_rules :
    (float * Keeper_state_machine.auto_rule_summary) option;
      (** Snapshot of the most recent [Context_measured] auto-rule summary.
          Stored as [(wall_clock, summary)] so the composite observer
          (RFC-0003 §6) can surface the last measurement without reading
          history files. [None] until the first [Context_measured] event
          has been dispatched. *)
  last_event_bus_correlation : string option;
      (** Most recent OAS Event_bus [correlation_id] extracted after a
          keeper turn via [Event_bus.drain]. [None] until the first
          successful drain. Stable per session (= [meta.runtime.trace_id]
          as passed to OAS). *)
  pending_turn_measurement : turn_measurement option;
      (** Fresh measurement captured by [Context_measured] and reserved
          for the next [mark_turn_measurement] call. Hidden from idle
          observers so the composite snapshot stays turn-scoped. *)
  current_turn_observation : turn_observation option;
      (** Live, turn-scoped observation record (issue #7122 Phase 1).
          [Some _] while a turn is actively executing. [None] outside
          any turn. Anti-stale barrier: sub-FSM live states are only
          observable while [Some]. *)
  last_completed_turn : completed_turn_observation option;
      (** Frozen snapshot of the most recently completed turn
          (RFC-0003 Phase 2 design A3). Populated by
          [mark_turn_finished] when [current_turn_observation] is
          [Some]; carries terminal data for the composite observer's
          [last_outcome] snapshot field.

          Distinct from [current_turn_observation] so the observer
          can distinguish "live in-turn state" from "previous turn
          result": idle keepers never surface stale terminal states
          on the live sub-FSM fields, but operators can still see
          the most recent outcome in [last_outcome]. *)
  last_skip_observation : (float * string list) option;
      (** Most recent [keeper_cycle_decision] skip outcome captured by
          the keepalive loop (#10940 follow-up).  The [Prometheus]
          [proactive_skip_reason_metric] aggregates skip reasons over
          time, but at stale-watchdog kill the operator wants to see
          *which* reasons were active *just before* the 300s idle
          timeout fired.  [Some (ts, reasons)] = wall clock + verdict
          reason strings ([cooldown_pending], [no_signal],
          [scheduled_autonomous_disabled], etc.) from the last skip;
          [None] until the first skip is observed.  Read by
          [Keeper_stale_watchdog] to enrich the kill warn line so an
          [idle_stale=true] termination is no longer indistinguishable
          from a *stuck* fiber. *)
  compaction_stage : packed_compaction_stage;
      (** Explicit KMC projection owned by the runtime, not derived from
          parent phase on read. This lets the observer surface
          [done] without guessing from conditions. *)
}

and turn_observation = {
  turn_id : int;
      (** Per-keeper turn counter at turn start (matches
          [meta.runtime.usage.total_turns] + 1). *)
  started_at : float;
      (** Unix timestamp when this turn record was installed. *)
  turn_phase : packed_turn_phase;
  decision_stage : packed_decision_stage;
  cascade_state : packed_cascade_state;
  measurement : turn_measurement option;
  measurement_bind_count : int;
      (** Number of [Context_measured] snapshots bound to this live turn.
          The composite observer's [event_priority_monotone] invariant
          requires this to stay <= 1. *)
  selected_model : string option;
}

and completed_turn_observation = {
  ct_turn_id : int;
  ct_started_at : float;
  ct_ended_at : float;
  ct_decision_stage : packed_decision_stage;
  ct_cascade_state : packed_cascade_state;
  ct_selected_model : string option;
}

(** Resolve a keeper run completion promise at most once.
    Returns [false] if another fiber won the resolve race. *)
val try_resolve_done :
  registry_entry -> [ `Stopped | `Crashed of string ] -> bool

(** Register a keeper with an already-live fiber. Primarily used by tests and
    direct fixtures that want a keeper to begin in [Running]. *)
val register : base_path:string -> string -> keeper_meta -> registry_entry

(** Register a fresh keeper before its first keepalive fiber launch.
    The entry starts in [Offline] and must receive [Fiber_started] when the
    runtime actually launches the fiber. *)
val register_offline : base_path:string -> string -> keeper_meta -> registry_entry

(** R-A-6.a — error variant for [register_restarting].
    [Budget_already_exhausted] is returned (not raised — the API is
    Result-based) when the caller attempts to revive a keeper whose
    [restart_budget_remaining] was previously cleared, which would
    violate TLA+ §S3 BudgetNeverRevives. *)
type register_restarting_error =
  | Budget_already_exhausted of { name : string }

(** Register a keeper that is about to relaunch after a crash.
    The entry starts in [Restarting] and must receive [Fiber_started] when the
    replacement fiber launches.

    Refuses to revive a keeper whose [restart_budget_remaining] was
    previously cleared — preserves the TLA+ §S3 BudgetNeverRevives
    invariant.  See [docs/tla-audit/ksm-a6-budget-never-revives-2026-05-12.md]
    for the three revival vectors this guard closes. *)
val register_restarting :
  base_path:string -> string -> keeper_meta ->
  (registry_entry, register_restarting_error) result

(** Prepare a registry entry for a newly launched keepalive fiber.
    Clears stale per-fiber atomic latches before applying [Fiber_started] so
    the runtime stop flag matches the state machine's restart semantics. *)
val prepare_fiber_launch :
  base_path:string -> string ->
  (Keeper_state_machine.transition_result, Keeper_state_machine.transition_error) result

(** Unregister a keeper (removes from registry). *)
val unregister : base_path:string -> string -> unit

(** Look up a keeper by name. *)
val get : base_path:string -> string -> registry_entry option

(** Return all registered keepers. *)
val all : ?base_path:string -> unit -> registry_entry list

(** Update the meta for a registered keeper. No-op if not found. *)
val update_meta : base_path:string -> string -> keeper_meta -> unit

(** Record a restart. Increments restart_count and updates last_restart_ts. *)
val record_restart : base_path:string -> string -> unit

(** Record an error message. *)
val record_error : base_path:string -> string -> string -> unit

(** Clear the last recorded error for a keeper. *)
val clear_error : base_path:string -> string -> unit

(** Set the structured failure reason for cohort detection. *)
val set_failure_reason : base_path:string -> string -> failure_reason option -> unit

(** Store the OAS Event_bus [correlation_id] from the most recent turn. *)
val set_last_correlation_id : base_path:string -> string -> string -> unit

(** Mark the beginning of a keeper turn. Installs a fresh
    [current_turn_observation] with [turn_id = usage.total_turns + 1].
    Must be paired with [mark_turn_finished] (or [mark_turn_failed]). *)
val mark_turn_started : base_path:string -> string -> unit

(** Mark the beginning of an SDK turn within an existing keeper turn.

    The Agent SDK [run_loop] iterates N SDK turns inside a single MASC
    keeper-turn window. Each SDK turn fires [before_turn_params] which
    leads to [prepare_agent_setup] writing
    [Cascade_selecting]/[Decision_tool_policy_selected]/[Turn_prompting].
    Without this boundary signal, the second-and-later SDK turn writes
    transition from the previous SDK turn's terminal phase
    ([Turn_finalizing] after [Cascade_done]/[Cascade_exhausted]), which
    [validate_turn_phase_transition] rejects with [Invalid_argument].

    This function resets the in-turn FSM fields ([turn_phase],
    [cascade_state], [decision_stage]) on the existing observation, the
    same way [mark_turn_started] bypasses the validator with a fresh
    install. [turn_id], [started_at], [selected_model], [measurement],
    and [measurement_bind_count] are preserved across SDK turns inside
    one keeper turn (they are keeper-turn-scoped, not SDK-turn-scoped).

    No-op when [current_turn_observation = None] (defensive: should not
    happen in normal flow because [mark_turn_started] runs first).

    See RFC-0045 (SDK turn boundary alignment with MASC keeper FSM). *)
val mark_sdk_turn_started : base_path:string -> string -> unit

(** Attach the most recent [Context_measured] snapshot to the live turn.
    No-op if no turn is active or no pending measurement exists. *)
val mark_turn_measurement : base_path:string -> string -> unit

(** Advance the live turn's projected decision stage. No-op if idle. *)
val set_turn_decision_stage :
  base_path:string -> string -> decision_stage -> unit

(** Advance the live turn's projected cascade state. No-op if idle.
    Sets [turn_phase] to [Turn_executing] for [Cascade_trying] and to
    [Turn_finalizing] for terminal cascade states. *)
val set_turn_cascade_state :
  base_path:string -> string -> packed_cascade_state -> unit

(** Update the live turn's phase directly. No-op if idle. *)
val set_turn_phase :
  base_path:string -> string -> packed_turn_phase -> unit

(** Runtime transition guards for the 4 sub-FSM axes.
    Each validates a (from, to) pair against the TLA+ transition matrix.
    Invalid transitions raise [Invalid_argument] with a message of the
    form ["<validator>: invalid transition <from> -> <to>"] and bump
    [Prometheus.metric_fsm_guard_violation]. *)
val validate_turn_phase_transition :
  from:packed_turn_phase -> to_:packed_turn_phase -> unit

val validate_compaction_transition :
  from:packed_compaction_stage -> to_:packed_compaction_stage -> unit

(** Record the surface model selected for the current turn. No-op if idle. *)
val set_turn_selected_model :
  base_path:string -> string -> string option -> unit

(** Reset a live turn into the post-compaction retry posture used by
    overflow recovery. Preserves the bound measurement, but clears the
    previous cascade attempt and selected model so the next retry starts
    from [Prompting + Guard_ok + Cascade_idle]. *)
val prepare_turn_retry_after_compaction :
  base_path:string -> string -> unit

(** Cross-registry convenience for hooks that only know the keeper name. *)
val mark_turn_gate_rejected_by_name : string -> unit

(** Mark the end of a keeper turn. Clears [current_turn_observation]
    so the composite observer reverts to idle and stamps
    [runtime.usage.last_turn_ts] for the completed turn. Idempotent —
    safe to call in finally blocks even if [mark_turn_started] was not
    called. *)
val mark_turn_finished : base_path:string -> string -> unit

(** Record the verdict reasons from a [keeper_cycle_decision] that
    chose to skip the next turn.  Stamps [last_skip_observation] with
    [(now, reasons)] so the stale watchdog can surface *why* a keeper
    was deliberately skipping turns when an [idle_stale=true]
    termination fires.  No-op if no entry is registered for [name]. *)
val record_skip_reasons :
  base_path:string -> string -> reasons:string list -> unit

(** Touch [last_turn_ts] in the registry entry so the stale watchdog
    sees the keeper as recently active.  Called from the heartbeat
    skip branch when a proactive keeper legitimately has no work to do.
    No-op if no entry is registered for [name]. *)
val touch_last_turn_ts : base_path:string -> string -> unit

(** Increment turn consecutive failure counter. *)
val increment_turn_failures : base_path:string -> string -> unit

(** Reset turn consecutive failure counter (on success). *)
val reset_turn_failures : base_path:string -> string -> unit

(** Get current turn consecutive failure count. *)
val get_turn_failures : base_path:string -> string -> int

(** Record a crash entry in the crash log (keeps last 5). *)
val record_crash : base_path:string -> string -> float -> string -> unit

(** Set or clear the gRPC close callback. *)
val set_grpc_close : base_path:string -> string -> (unit -> unit) option -> unit

(** Check if a keeper is in Running state. *)
val is_running : base_path:string -> string -> bool

(** Check if a keeper has ANY registry entry (regardless of state).
    Used by reconcile to skip Crashed/Dead keepers. *)
val is_registered : base_path:string -> string -> bool

(** Mark a keeper as dead tombstone and record the transition timestamp. *)
val mark_dead : base_path:string -> string -> at:float -> unit

(** Return the started_at timestamp, or None if not registered. *)
val started_at : base_path:string -> string -> float option

(** Test-only: override [started_at] for registry fixtures that need to
    model a long-running fiber without waiting for wall-clock time. *)
val set_started_at_for_test : base_path:string -> string -> float -> unit

(** Count keepers in Running state. *)
val count_running : ?base_path:string -> unit -> int

(** Check if there are available spawn slots (respects max_active_keepers). *)
val spawn_slots_available : unit -> bool

(** Set fiber_wakeup for a specific keeper. *)
val wakeup : base_path:string -> string -> unit

(** Set fiber_wakeup for all running keepers. *)
val wakeup_all : ?base_path:string -> unit -> unit

(** Fiber-level health based on Promise resolution state.
    Returns Fiber_unknown if the keeper is not registered. *)
val fiber_health_of : base_path:string -> string -> fiber_health

(** Recent crash entries (up to 5) for a keeper. *)
val crash_log_of : base_path:string -> string -> (float * string) list

(** Restore supervisor state on a freshly registered entry (used by restart). *)
val restore_supervisor_state :
  base_path:string -> string ->
  restart_count:int -> last_restart_ts:float ->
  crash_log:(float * string) list -> unit

(** Last known agent count for roster-change detection. Returns 0 if not found. *)
val get_last_agent_count : base_path:string -> string -> int

(** Update last agent count for a keeper. No-op if not found. *)
val set_last_agent_count : base_path:string -> string -> int -> unit

(** Check if a board-reactive wakeup is allowed (debounce).
    Records timestamp if allowed. Returns true for unregistered keepers. *)
val board_wakeup_allowed :
  base_path:string -> string -> post_id:string -> debounce_sec:float -> bool

(** Clear all board wakeup timestamps for a keeper. No-op if not found. *)
val clear_board_wakeups : base_path:string -> string -> unit

(** Reset tracking state (agent count + board wakeups) for a keeper. *)
val cleanup_tracking : base_path:string -> string -> unit

(** Clear the registry. For testing only. *)
val clear : unit -> unit

(** Get board event cursor timestamp. Returns 0.0 if not found. *)
val get_board_cursor_ts : base_path:string -> string -> float

(** Update board event cursor timestamp. No-op if not found. *)
val set_board_cursor_ts : base_path:string -> string -> float -> unit

(** Get board event cursor token. Returns [(0.0, None)] if not found. *)
val get_board_cursor : base_path:string -> string -> float * string option

(** Update board event cursor token. No-op if not found. *)
val set_board_cursor :
  base_path:string -> string -> float -> string option -> unit

(** Record a tool call for a keeper. No-op if not found. *)
val record_tool_use :
  base_path:string -> string -> tool_name:string -> success:bool -> unit

(** Get tool usage sorted by call count descending. *)
val tool_usage_of : base_path:string -> string ->
  (string * Keeper_types.tool_call_entry) list

(** Look up a keeper by name across all base_paths (O(n) scan). *)
val find_by_name : string -> registry_entry option

(** Look up a keeper by agent_name across all base_paths (O(n) scan). *)
val find_by_agent_name : string -> registry_entry option

(** Look up a keeper by stable UID across all base_paths (O(n) scan). *)
val find_by_id : Keeper_id.Uid.t -> registry_entry option

(** Get tool usage by keeper name (scans all base_paths). *)
val tool_usage_of_by_name : string ->
  (string * Keeper_types.tool_call_entry) list

(** Resolve config for a keeper tool dispatch.
    Tries scoped lookup first (O(1) map lookup), then falls back to
    cross-base_path scan (O(n)) when not found in the caller's scope.
    Returns config with the keeper's actual base_path, or the original
    config unchanged if the keeper is not in the registry. *)
val resolve_config : Coord_utils_backend_setup.config -> string -> Coord_utils_backend_setup.config

(** Flush in-memory tool usage stats to disk for persistence across restarts. *)
val flush_tool_usage : base_path:string -> string -> unit

(** Restore tool usage stats from disk after keeper re-registration. *)
val restore_tool_usage : base_path:string -> string -> unit

(** {1 RFC-0002 Event Dispatch} *)

(** Dispatch a typed event through the state machine.
    Updates conditions, derives new phase, syncs legacy state.
    Returns the transition result or an error for invalid transitions.
    Prefer this over [set_state] for new code. *)
val dispatch_event :
  base_path:string -> string -> Keeper_state_machine.event ->
  (Keeper_state_machine.transition_result, Keeper_state_machine.transition_error) result

(** Like [dispatch_event], but preserves richer audit metadata when the event
    causes a phase transition. *)
val dispatch_event_with_audit :
  base_path:string ->
  ?snapshot:Keeper_measurement.measurement_snapshot ->
  ?events_fired:Keeper_state_machine.event list ->
  ?selected_event:Keeper_state_machine.event ->
  string -> Keeper_state_machine.event ->
  (Keeper_state_machine.transition_result, Keeper_state_machine.transition_error) result

(** Like [dispatch_event], but logs and emits a Prometheus counter on
    [Error] so silent-failure call sites do not lose the signal.
    Same return type — callers that need the result can still match. *)
val dispatch_event_and_log :
  base_path:string -> string -> Keeper_state_machine.event ->
  (Keeper_state_machine.transition_result, Keeper_state_machine.transition_error) result

(** [dispatch_event_unit] wraps [dispatch_event_and_log] and logs a warning
    on [Error] instead of returning the result. Replaces [ignore (...)] call sites
    that previously swallowed transition errors silently. *)
val dispatch_event_unit :
  base_path:string -> string -> Keeper_state_machine.event -> unit
(** Like [dispatch_event_with_audit], but logs and emits a Prometheus
    counter on [Error]. *)
val dispatch_event_with_audit_and_log :
  base_path:string ->
  ?snapshot:Keeper_measurement.measurement_snapshot ->
  ?events_fired:Keeper_state_machine.event list ->
  ?selected_event:Keeper_state_machine.event ->
  string -> Keeper_state_machine.event ->
  (Keeper_state_machine.transition_result, Keeper_state_machine.transition_error) result

(** Get the fine-grained phase of a keeper. *)
val get_phase : base_path:string -> string -> Keeper_state_machine.phase option

(** Get the observable conditions of a keeper. *)
val get_conditions : base_path:string -> string -> Keeper_state_machine.conditions option

(** Append a stimulus to the keeper's Event Layer queue.

    Always succeeds when the keeper is registered. Lock-free CAS
    loop on [entry.event_queue]; concurrent [enqueue_event] callers
    do not block. Stimuli arrive in the order observed by the CAS
    winner, which the Policy Layer respects via [Keeper_event_queue.dequeue].

    Logs a warning when [name] is not in the registry — calling sites
    should not depend on enqueue success for missing keepers. *)
val enqueue_event :
  base_path:string -> string -> Keeper_event_queue.stimulus -> unit

(** Snapshot the keeper's Event Layer queue. Returns [Keeper_event_queue.empty]
    when the keeper is missing. Read-only — does not consume stimuli. *)
val event_queue_snapshot :
  base_path:string -> string -> Keeper_event_queue.t

(** Consume at most one stimulus from the keeper's Event Layer queue.

    Returns [Some stim] when the queue had work (and the stimulus is
    removed from the queue), [None] when the queue is empty or the
    keeper is not registered. Lock-free CAS retry on
    [entry.event_queue]; concurrent callers do not block.

    The Policy Layer (turn entry) calls this once per [Emit] tick to
    drain one stimulus per turn. See RFC-0020 §3 (Rule 4: per-turn
    dequeue) and KeeperEventQueue.tla Conservation invariant
    ([dequeued_total <= enqueued_total]). *)
val dequeue_event :
  base_path:string -> string -> Keeper_event_queue.stimulus option

val drain_board_events :
  ?window_sec:float ->
  base_path:string -> string -> Keeper_event_queue.stimulus list
(** Drain all board-signal stimuli within [window_sec] from the keeper's
    event queue using a CAS loop.  Returns the coalesced board signals
    (urgency-sorted) and updates the queue atomically.  Returns []
    when the keeper is not found or the queue has no board signals. *)
