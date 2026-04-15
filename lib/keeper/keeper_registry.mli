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

type failure_reason =
  | Heartbeat_consecutive_failures of int
  | Turn_consecutive_failures of int
  | Ambiguous_partial_commit of ambiguous_partial_commit
  | Fiber_unresolved
  | Exception of string

val ambiguous_partial_commit_kind_to_string :
  ambiguous_partial_commit_kind -> string

val failure_reason_to_string : failure_reason -> string

(** Pure control-flow signal for immediate fiber termination (RFC-0002).
    Carries no state — failure reason must be pre-stored via
    [set_failure_reason] before raising. *)
exception Keeper_fiber_crash

type turn_phase =
  | Turn_idle
  | Turn_prompting
  | Turn_executing
  | Turn_compacting
  | Turn_finalizing

type decision_stage =
  | Decision_undecided
  | Decision_guard_ok
  | Decision_gate_rejected
  | Decision_tool_policy_selected

type cascade_state =
  | Cascade_idle
  | Cascade_selecting
  | Cascade_trying
  | Cascade_done
  | Cascade_exhausted

type compaction_stage =
  | Compaction_accumulating
  | Compaction_compacting
  | Compaction_done

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
  compaction_stage : compaction_stage;
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
  turn_phase : turn_phase;
  decision_stage : decision_stage;
  cascade_state : cascade_state;
  measurement : turn_measurement option;
  selected_model : string option;
}

and completed_turn_observation = {
  ct_turn_id : int;
  ct_started_at : float;
  ct_ended_at : float;
  ct_decision_stage : decision_stage;
  ct_cascade_state : cascade_state;
  ct_selected_model : string option;
}

(** Register a keeper with an already-live fiber. Primarily used by tests and
    direct fixtures that want a keeper to begin in [Running]. *)
val register : base_path:string -> string -> keeper_meta -> registry_entry

(** Register a fresh keeper before its first keepalive fiber launch.
    The entry starts in [Offline] and must receive [Fiber_started] when the
    runtime actually launches the fiber. *)
val register_offline : base_path:string -> string -> keeper_meta -> registry_entry

(** Register a keeper that is about to relaunch after a crash.
    The entry starts in [Restarting] and must receive [Fiber_started] when the
    replacement fiber launches. *)
val register_restarting : base_path:string -> string -> keeper_meta -> registry_entry

(** Unregister a keeper (removes from registry). *)
val unregister : base_path:string -> string -> unit

(** Look up a keeper by name. *)
val get : base_path:string -> string -> registry_entry option

(** Return all registered keepers. *)
val all : ?base_path:string -> unit -> registry_entry list

(** Update the meta for a registered keeper. No-op if not found. *)
val update_meta : base_path:string -> string -> keeper_meta -> unit

(** @deprecated Use [dispatch_event]. No external callers remain. *)

(** Record a restart. Increments restart_count and updates last_restart_ts. *)
val record_restart : base_path:string -> string -> unit

(** Record an error message. *)
val record_error : base_path:string -> string -> string -> unit

(** Set the structured failure reason for cohort detection. *)
val set_failure_reason : base_path:string -> string -> failure_reason option -> unit

(** Store the OAS Event_bus [correlation_id] from the most recent turn. *)
val set_last_correlation_id : base_path:string -> string -> string -> unit

(** Mark the beginning of a keeper turn. Installs a fresh
    [current_turn_observation] with [turn_id = usage.total_turns + 1].
    Must be paired with [mark_turn_finished] (or [mark_turn_failed]). *)
val mark_turn_started : base_path:string -> string -> unit

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
  base_path:string -> string -> cascade_state -> unit

(** Update the live turn's phase directly. No-op if idle. *)
val set_turn_phase :
  base_path:string -> string -> turn_phase -> unit

(** Record the surface model selected for the current turn. No-op if idle. *)
val set_turn_selected_model :
  base_path:string -> string -> string option -> unit

(** Cross-registry convenience for hooks that only know the keeper name. *)
val mark_turn_gate_rejected_by_name : string -> unit

(** Mark the end of a keeper turn. Clears [current_turn_observation]
    so the composite observer reverts to idle. Idempotent — safe to
    call in finally blocks even if [mark_turn_started] was not called. *)
val mark_turn_finished : base_path:string -> string -> unit

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

(** Get tool usage by keeper name (scans all base_paths). *)
val tool_usage_of_by_name : string ->
  (string * Keeper_types.tool_call_entry) list

(** Resolve config for a keeper tool dispatch.
    Tries scoped lookup first (O(1) map lookup), then falls back to
    cross-base_path scan (O(n)) when not found in the caller's scope.
    Returns config with the keeper's actual base_path, or the original
    config unchanged if the keeper is not in the registry. *)
val resolve_config : Room_utils_backend_setup.config -> string -> Room_utils_backend_setup.config

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

(** Get the fine-grained phase of a keeper. *)
val get_phase : base_path:string -> string -> Keeper_state_machine.phase option

(** Get the observable conditions of a keeper. *)
val get_conditions : base_path:string -> string -> Keeper_state_machine.conditions option
