(** Keeper_registry — Single source of truth for keeper state.

    Replaces scattered state across keeper_keepalive Hashtbl,
    keeper_supervisor Hashtbl, and file-based meta lookups.
    All keeper state queries and mutations go through this module.

    Thread-safety: all operations are non-yielding (in-memory map/ref
    ops only).  In single-domain Eio, non-yielding code runs atomically
    w.r.t. other fibers, so no mutex is needed. *)

open Keeper_types

(** Failure-reason + turn_phase clusters live in Keeper_registry_types
    (intra-library file split, 2026-05-16). Re-exported here so existing
    126 callers keep using [Keeper_registry.failure_reason] /
    [Keeper_registry.packed_turn_phase] etc. unchanged. *)
include module type of Keeper_registry_types

(** [validate_turn_phase_transition] and [validate_cascade_transition]
    stay in Keeper_registry because their implementations depend on
    [Keeper_fsm_guard_runtime], not a pure type-level dependency. *)
val validate_turn_phase_transition
  :  from:packed_turn_phase
  -> to_:packed_turn_phase
  -> unit

val validate_cascade_transition
  :  from:packed_cascade_state
  -> to_:packed_cascade_state
  -> unit


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

(** Persist the last cascade provider attempt in keeper runtime meta.
    Best-effort: missing keepers or meta write failures are ignored. *)
val record_cascade_attempt :
  base_path:string -> keeper_name:string -> cascade_attempt_record -> unit

(** Add [provider=<id> http=<status>] to [fiber_unresolved] outcomes when
    keeper runtime meta has a recorded cascade attempt. Other outcomes are
    returned unchanged. *)
val enrich_fiber_unresolved_outcome :
  base_path:string -> keeper_name:string -> string -> string

(** Record a restart. Increments restart_count and updates last_restart_ts. *)
val record_restart : base_path:string -> string -> unit

(** Record an error message. *)
val record_error :
  base_path:string ->
  ?details:Yojson.Safe.t ->
  string ->
  string ->
  unit

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

(** Refresh the live turn's progress timestamp without changing its FSM
    projection.  No-op when no turn is active.  [event_kind] must be a
    low-cardinality diagnostic label. *)
val record_turn_progress :
  base_path:string -> string -> event_kind:string -> unit

(** Mark the beginning of an SDK turn within an existing keeper turn.

    The Agent SDK [run_loop] iterates N SDK turns inside a single MASC
    keeper-turn window. Each SDK turn fires [before_turn_params] which
    leads to [prepare_agent_setup] writing
    [Cascade_selecting]/[Decision_tool_policy_selected]/[Turn_prompting].
    Without this boundary signal, the second-and-later SDK turn writes
    transition from the previous SDK turn's terminal phase
    ([Turn_finalizing] after [Cascade_done]/[Cascade_exhausted]), which
    [validate_turn_phase_transition] rejects with
    [Turn_phase_transition_violation].

    This function resets the in-turn FSM fields ([turn_phase],
    [cascade_state], [decision_stage]) on the existing observation, the
    same way [mark_turn_started] bypasses the validator with a fresh
    install. [turn_id], [started_at], [selected_model], [measurement],
    [measurement_bind_count], and progress timestamp are preserved across
    SDK turns inside one keeper turn (they are keeper-turn-scoped, not
    SDK-turn-scoped).

    No-op when [current_turn_observation = None] (defensive: should not
    happen in normal flow because [mark_turn_started] runs first).

    See RFC-0045 (SDK turn boundary alignment with MASC keeper FSM). *)
val mark_sdk_turn_started : base_path:string -> string -> unit

(** Attach the most recent [Context_measured] snapshot to the live turn.
    No-op if no turn is active or no pending measurement exists. *)
val mark_turn_measurement : base_path:string -> string -> unit

(** Advance the live turn's projected decision stage. No-op if idle.
    Input type [decision_stage_active] excludes [Decision_undecided];
    the 3 spec-forbidden [<active>_to_undecided] transitions are therefore
    unrepresentable at the call site (replaces prior runtime [invalid_arg]). *)
val set_turn_decision_stage :
  base_path:string -> string -> decision_stage_active -> unit

(** Advance the live turn's projected cascade state. No-op if idle.
    Sets [turn_phase] to [Turn_executing] for [Cascade_trying] and to
    [Turn_finalizing] for terminal cascade states. *)
val set_turn_cascade_state :
  base_path:string -> string -> packed_cascade_state -> unit

(** Mark cascade exhaustion on the live turn.

    When provider selection fails before the tool-disclosure hook runs, the
    live cascade axis can still be [Cascade_idle]. This helper materializes the
    spec-valid pre-terminal path ([idle -> selecting -> trying -> exhausted])
    instead of allowing callers to jump directly to [Cascade_exhausted]. No-op
    when no turn is active. *)
val mark_turn_cascade_exhausted : base_path:string -> string -> unit

(** Mark cascade success on the live turn.

    When provider execution returns before the tool-disclosure hook advances the
    registry projection, the live cascade axis can still be [Cascade_idle]. This
    helper materializes the spec-valid pre-terminal path ([idle -> selecting ->
    trying -> done]) instead of allowing callers to jump directly to
    [Cascade_done]. No-op when no turn is active. *)
val mark_turn_cascade_done : base_path:string -> string -> unit

(** Mark that the live turn has entered a provider attempt.

    This materializes the registry-side projection that corresponds to
    [Keeper_turn_fsm.Streaming]: [Cascade_idle] advances through
    [Cascade_selecting] into [Cascade_trying], and [turn_phase] follows to
    [Turn_executing]. No-op when no turn is active or the cascade is already
    trying/terminal. *)
val mark_turn_provider_attempt_started : base_path:string -> string -> unit

(** Update the live turn's phase directly. No-op if idle. *)
val set_turn_phase :
  base_path:string -> string -> packed_turn_phase -> unit

(** Runtime transition guards against the TLA+ transition matrix.
    [validate_turn_phase_transition] dispatches through
    [resolve_turn_phase_transition] and raises the typed
    [Turn_phase_transition_violation] on a forbidden pair (RFC-0072
    Phase 4b + 5).  [validate_compaction_transition] is an exhaustive
    3×3 match raising the typed [Compaction_transition_violation] on a
    forbidden pair (RFC-0072 Phase 6 — no GADT/resolver indirection,
    the axis has 3 states and a single consumer).  Both bump
    [Prometheus.metric_fsm_guard_violation] via
    [Keeper_fsm_guard_runtime.wrap_unit]. *)
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

(** Closed reason for a keeper launch/admission denial. *)
type spawn_slot_denial_reason =
  | Fd_pressure_active
  | Disk_pressure_active
  | Fd_admission_blocked
  | Disk_admission_blocked
  | Max_active_keepers of { running_count : int; max_keepers : int }

val spawn_slot_denial_reason_to_label : spawn_slot_denial_reason -> string
val spawn_slot_denial_reason_to_detail : spawn_slot_denial_reason -> string

(** Check if there are available spawn slots and return the denial reason when blocked.
    [base_path] enables disk admission probing for the target runtime root. *)
val spawn_slots_decision : ?base_path:string -> unit -> (unit, spawn_slot_denial_reason) result

(** Compatibility bool wrapper over [spawn_slots_decision]. *)
val spawn_slots_available : ?base_path:string -> unit -> bool

(** Emit the durable signal for a denied keeper launch/admission. *)
val record_spawn_slot_denied :
  keeper_name:string -> surface:string -> spawn_slot_denial_reason -> unit

module For_testing : sig
  val spawn_slots_decision :
    ?fd_admitted:bool ->
    ?disk_admitted:bool ->
    unit ->
    (unit, spawn_slot_denial_reason) result

  val spawn_slots_available :
    ?fd_admitted:bool ->
    ?disk_admitted:bool ->
    unit ->
    bool
end

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
  base_path:string ->
  ?origin:lifecycle_event_origin ->
  string -> Keeper_state_machine.event ->
  (Keeper_state_machine.transition_result, Keeper_state_machine.transition_error) result

(** Like [dispatch_event], but preserves richer audit metadata when the event
    causes a phase transition. *)
val dispatch_event_with_audit :
  base_path:string ->
  ?origin:lifecycle_event_origin ->
  ?snapshot:Keeper_measurement.measurement_snapshot ->
  ?events_fired:Keeper_state_machine.event list ->
  ?selected_event:Keeper_state_machine.event ->
  string -> Keeper_state_machine.event ->
  (Keeper_state_machine.transition_result, Keeper_state_machine.transition_error) result

(** Like [dispatch_event], but logs and emits a Prometheus counter on
    [Error] so silent-failure call sites do not lose the signal.
    Same return type — callers that need the result can still match. *)
val dispatch_event_and_log :
  base_path:string ->
  ?origin:lifecycle_event_origin ->
  string -> Keeper_state_machine.event ->
  (Keeper_state_machine.transition_result, Keeper_state_machine.transition_error) result

(** [dispatch_event_unit] wraps [dispatch_event_and_log] and logs a warning
    on [Error] instead of returning the result. Replaces [ignore (...)] call sites
    that previously swallowed transition errors silently. *)
val dispatch_event_unit :
  base_path:string ->
  ?origin:lifecycle_event_origin ->
  string -> Keeper_state_machine.event -> unit
(** Like [dispatch_event_with_audit], but logs and emits a Prometheus
    counter on [Error]. *)
val dispatch_event_with_audit_and_log :
  base_path:string ->
  ?origin:lifecycle_event_origin ->
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
