(** Keeper_registry — Single source of truth for keeper state.

    Replaces scattered state across keeper_keepalive Hashtbl,
    keeper_supervisor Hashtbl, and file-based meta lookups.
    All keeper state queries and mutations go through this module.

    Thread-safety: all operations are non-yielding (in-memory map/ref
    ops only).  In single-domain Eio, non-yielding code runs atomically
    w.r.t. other fibers, so no mutex is needed. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(** Failure-reason + turn_phase clusters live in Keeper_registry_types
    (intra-library file split, 2026-05-16). Re-exported here so existing
    126 callers keep using [Keeper_registry.failure_reason] /
    [Keeper_registry.packed_turn_phase] etc. unchanged. *)
include module type of Keeper_registry_types

(** [validate_turn_phase_transition] stays in Keeper_registry because its
    implementation depends on [Keeper_fsm_guard_runtime], not a pure type-level
    dependency. *)
val validate_turn_phase_transition
  :  from:packed_turn_phase
  -> to_:packed_turn_phase
  -> unit


(** Register a keeper with an already-live fiber. Primarily used by tests and
    direct fixtures that want a keeper to begin in [Running]. *)
val register : base_path:string -> string -> keeper_meta -> registry_entry

(** Register a fresh keeper before its first keepalive fiber launch.
    The entry starts in [Offline] and must receive [Fiber_started] when the
    runtime actually launches the fiber. *)
val register_offline : base_path:string -> string -> keeper_meta -> registry_entry

type registration_error =
  | Registration_shutdown_reserved of Keeper_shutdown_types.Operation_id.t
  | Registration_lifecycle_reserved of Keeper_lifecycle_reservation.snapshot
  | Registration_invalid of registry_entry_validation_error
  | Registration_event_queue_unavailable of
      { keeper_name : string
      ; detail : string
      }

(** Production registration gate: the final registry CAS is serialized with
    Keeper shutdown reservation. Event-queue loading remains outside the
    non-yielding fence critical section. *)
val register_offline_if_admitted :
  base_path:string ->
  string ->
  keeper_meta ->
  (registry_entry, registration_error) result

val register_offline_if_admitted_for_lifecycle :
  Keeper_lifecycle_reservation.token ->
  base_path:string ->
  string ->
  keeper_meta ->
  (registry_entry, registration_error) result

type register_restarting_error =
  | Restart_shutdown_reserved of Keeper_shutdown_types.Operation_id.t
  | Restart_lifecycle_reserved of Keeper_lifecycle_reservation.snapshot
  | Restart_event_queue_unavailable of
      { keeper_name : string
      ; detail : string
      }

(** Register a keeper that is about to relaunch after a crash.
    The entry starts in [Restarting] and must receive [Fiber_started] when the
    replacement fiber launches. Durable pause or Dead-tombstone admission is
    checked by the caller before this registration CAS. *)
val register_restarting :
  base_path:string -> string -> keeper_meta ->
  (registry_entry, register_restarting_error) result

(** Prepare a registry entry for a newly launched keepalive fiber.
    Clears stale per-fiber atomic latches before applying [Fiber_started] so
    the runtime stop flag matches the state machine's restart semantics. *)
val prepare_fiber_launch :
  base_path:string -> string ->
  (Keeper_state_machine.transition_result, Keeper_state_machine.transition_error) result

val prepare_fiber_launch_for_lifecycle :
  Keeper_lifecycle_reservation.token ->
  registry_entry ->
  (Keeper_state_machine.transition_result, Keeper_state_machine.transition_error) result

(** Unregister a keeper (removes from registry). *)
val unregister : base_path:string -> string -> unit

type unregister_exact_result =
  | Exact_unregistered
  | Exact_entry_missing
  | Exact_entry_replaced
  | Exact_unregister_lifecycle_reserved of Keeper_lifecycle_reservation.snapshot

(** Remove [entry] only if its typed lane identity still owns the
    [(base_path, name)] key. Immutable registry field updates may replace the
    record value while preserving the same lane; a newer same-name lane has a
    different identity and is retained. *)
val unregister_exact : registry_entry -> unregister_exact_result

val unregister_exact_for_lifecycle :
  Keeper_lifecycle_reservation.token ->
  registry_entry ->
  unregister_exact_result

type restore_entry_result =
  | Entry_restored
  | Entry_restore_occupied of registry_entry
  | Entry_restore_invalid of registry_entry_validation_error
  | Entry_restore_lifecycle_reserved of Keeper_lifecycle_reservation.snapshot

(** Restore a transaction's original registry snapshot only when the key is
    still absent and [token] owns the reservation. A newer lane is returned
    untouched as [Entry_restore_occupied]. *)
val restore_entry_if_absent_for_lifecycle :
  Keeper_lifecycle_reservation.token ->
  registry_entry ->
  restore_entry_result

(** Look up a keeper by name. *)
val get : base_path:string -> string -> registry_entry option

(** Return all registered keepers. *)
val all : ?base_path:string -> unit -> registry_entry list

val registry_entry_validation_error_to_string :
  registry_entry_validation_error -> string

val validate_registry_entry :
  base_path:string ->
  string ->
  registry_entry ->
  (unit, registry_entry_validation_error) result

(** Health verdict for a single entry.  Pure: does not read the registry. *)
val health_of_entry :
  base_path:string -> string -> registry_entry -> registry_entry_health

(** Like [get] but returns the entry together with its health verdict.
    Returns [Some _] even when the entry is corrupted, so callers can decide
    whether to consume it. *)
val get_with_health :
  base_path:string -> string -> (registry_entry * registry_entry_health) option

(** Insert or replace a registry entry.  Validates [entry] before installing;
    on validation error returns the health reason and emits
    [RegistryInvalidEntry] with [operation="put"]. *)
val put_entry :
  base_path:string ->
  string ->
  registry_entry ->
  (unit, registry_entry_validation_error) result

(** Result-returning update: validates [f entry] before installing.  On
    validation error returns the health reason, emits
    [RegistryInvalidEntry] with [operation="update"], and leaves the original
    entry untouched.  Only CAS conflicts retry. *)
val update_entry :
  base_path:string ->
  string ->
  (registry_entry -> registry_entry) ->
  (unit, registry_entry_validation_error) result

type exact_update_result =
  | Exact_updated
  | Exact_update_missing
  | Exact_update_replaced
  | Exact_update_invalid of registry_entry_validation_error

(** Update only while the lane identity captured in [expected] still owns the
    registry key. CAS conflicts within that lane retry against the latest
    immutable entry; a same-name replacement is never mutated. *)
val update_entry_exact :
  registry_entry ->
  (registry_entry -> registry_entry) ->
  exact_update_result

val update_entry_exact_for_lifecycle :
  Keeper_lifecycle_reservation.token ->
  registry_entry ->
  (registry_entry -> registry_entry) ->
  exact_update_result

(** Update a registered entry and return [true] only when a validated write
    was installed.  Missing keepers, no-op closures, and validation failures
    return [false]. *)
val update_entry_if_registered :
  base_path:string ->
  string ->
  (registry_entry -> registry_entry * bool) ->
  bool

(** Update the meta for a registered keeper. No-op if not found. *)
val update_meta : base_path:string -> string -> keeper_meta -> unit

(** Reload a registered keeper's meta from disk and replace the in-memory
    registry copy. Returns [Ok None] when the keeper is not registered or has
    no persisted meta. *)
val reload_meta_from_disk :
  base_path:string -> string -> (registry_entry option, string) result

(* Runtime-attempt persistence + enrichment moved to
   Keeper_registry_runtime_attempt (record / enrich_fiber_unresolved_outcome). *)

(** Record a restart. Increments restart_count and updates last_restart_ts. *)
val record_restart : base_path:string -> string -> unit

(* [record_error] moved to [Keeper_registry_error_recording.record]. *)

(** CAS-write the [last_error] slot for keeper [name]. Exposed for
    [Keeper_registry_error_recording.record] which holds the dedup
    logic. *)
val set_last_error_entry : base_path:string -> name:string -> string -> unit

(** Clear the last recorded error for a keeper. *)
val clear_error : base_path:string -> string -> unit

(** Set the structured failure reason for cohort detection. *)
val set_failure_reason : base_path:string -> string -> failure_reason option -> unit

(** Store the OAS Event_bus [correlation_id] from the most recent turn. *)
val set_last_correlation_id : base_path:string -> string -> string -> unit

(** Mark the beginning of a keeper turn. Installs a fresh
    [current_turn_observation] with [turn_id = usage.total_turns + 1] and
    [wake] frozen for the turn's lifetime (#16, 38-bug campaign PR-5).
    Must be paired with [mark_turn_finished] (or [mark_turn_failed]). *)
val mark_turn_started : base_path:string -> wake:wake_reason -> string -> unit

(** Refresh the live turn's progress timestamp without changing its FSM
    projection.  No-op when no turn is active.  [event_kind] must be a
    low-cardinality diagnostic label. *)
val record_turn_progress :
  base_path:string -> string -> event_kind:string -> unit

(** Write-through observation of the turn event bus [pending_tool_count] in the
    live turn's [active_tool_count]. No-op when no turn is active. This is
    telemetry only and has no timeout or lifecycle authority. *)
val record_turn_tool_inflight : base_path:string -> string -> count:int -> unit

(** Mark the beginning of an SDK turn within an existing keeper turn.

    The Agent SDK [run_loop] iterates N SDK turns inside a single MASC
    keeper-turn window. Each SDK turn fires [before_turn_params] which
    leads to [prepare_agent_setup] writing
    [Decision_tool_policy_selected]/[Turn_prompting].
    Without this boundary signal, the second-and-later SDK turn writes
    transition from the previous SDK turn's terminal phase
    ([Turn_finalizing]), which [validate_turn_phase_transition] rejects with
    [Turn_phase_transition_violation].

    This function resets the in-turn FSM fields ([turn_phase],
    [decision_stage]) on the existing observation, the
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

(** Mark runtime exhaustion on the live turn. *)
val mark_turn_runtime_exhausted : base_path:string -> string -> unit

(** Mark runtime success on the live turn. *)
val mark_turn_runtime_done : base_path:string -> string -> unit

(** Mark that the live turn has entered a provider attempt.

    This materializes the registry-side projection that corresponds to
    [Keeper_turn_fsm.Streaming]: [turn_phase] advances to [Turn_executing].
    No-op when no turn is active. *)
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
    [Otel_metric_store.metric_fsm_guard_violation] via
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
    previous runtime attempt and selected model so the next retry starts
    from [Prompting + Guard_ok + Runtime_idle]. *)
val prepare_turn_retry_after_compaction :
  base_path:string -> string -> unit

(** Mark the end of a keeper turn. Clears [current_turn_observation]
    so the composite observer reverts to idle and stamps
    [runtime.usage.last_turn_ts] for the completed turn. Idempotent —
    safe to call in finally blocks even if [mark_turn_started] was not
    called. *)
val mark_turn_finished : base_path:string -> string -> unit

(** Store or clear the live [Eio.Switch.t] for the current turn.
    The switch is used by [interrupt_current_turn] to cancel an
    in-flight turn from the dashboard or operator tooling. *)
val set_turn_switch :
  base_path:string -> string -> Eio.Switch.t option -> unit

(** Reset [current_turn_switch] to [None]. Idempotent no-op if the
    keeper is not registered. *)
val clear_turn_switch : base_path:string -> string -> unit

(** Cancel the keeper's in-flight turn by failing its [Eio.Switch.t].
    Returns [`Cancelled turn_id] when a live switch was held and
    cancelled, or [`No_turn_in_flight] when there is no active turn or
    no registered switch. *)
val interrupt_current_turn :
  base_path:string -> string -> [ `Cancelled of int | `No_turn_in_flight ]

type exact_turn_interrupt_result =
  | Exact_turn_cancelled of int
  | Exact_no_turn_in_flight
  | Exact_turn_cancel_failed of
      { turn_id : int option
      ; detail : string
      }

(** Cancel the turn switch retained by this exact registry entry. Unlike the
    name-based compatibility API, failure is returned explicitly. *)
val interrupt_current_turn_exact :
  registry_entry -> exact_turn_interrupt_result

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

(** Failure mutations scoped to the exact lane captured by [entry]. *)
val set_failure_reason_exact :
  registry_entry -> failure_reason option -> exact_update_result

val set_last_error_exact : registry_entry -> string -> exact_update_result

val record_crash_exact :
  registry_entry -> float -> string -> exact_update_result

(** Observe an exact-lane update without discarding why it did not commit.
    Returns [true] only for [Exact_updated]; all other outcomes are logged with
    [site], and a newer same-name lane is never mutated. *)
val exact_update_succeeded :
  registry_entry -> site:string -> exact_update_result -> bool

(** Set or clear the gRPC close callback. *)
val set_grpc_close : base_path:string -> string -> (unit -> unit) option -> unit

(** Check if a keeper is in Running state. *)
val is_running : base_path:string -> string -> bool

(** Check if a keeper is already live for boot idempotency.
    Returns [true] when the keeper has a live fiber, is not
    stop-requested, and its phase is [Running] or [Paused].
    All other phases (including [Failing] and [Offline]) return [false]
    so that [/boot] can restart the keeper instead of silently
    doing nothing (Issue #17218). *)
val is_boot_already_live : base_path:string -> string -> bool

(** Check if a keeper has ANY registry entry (regardless of state).
    Used by reconcile to skip Crashed/Dead keepers. *)
val is_registered : base_path:string -> string -> bool

(** Restore an already-authoritative durable Dead tombstone into the in-memory
    registry. Runtime failures, cancellation, retry exhaustion, and resource
    observations must never call this function. *)
val mark_dead : base_path:string -> string -> at:float -> unit

(** Return the started_at timestamp, or None if not registered. *)
val started_at : base_path:string -> string -> float option

(** Test-only: override [started_at] for registry fixtures that need to
    model a long-running fiber without waiting for wall-clock time. *)
val set_started_at_for_test : base_path:string -> string -> float -> unit

(** Count keepers in Running state. *)
val count_running : ?base_path:string -> unit -> int

module For_testing : sig
  (** Test-only bypass: install an entry without validation so tests can seed
      corrupted registry state. *)
  val unsafe_put_entry :
    base_path:string -> string -> registry_entry -> unit

end

type wakeup_intent =
  | Reactive_signal
  | Scheduled_signal
  | Goal_signal
  | Supervisor_resume
  | Hitl_resolution
  | Broadcast_signal

type wakeup_outcome =
  | Signaled
  | Deferred_unregistered
  | Deferred_not_running of Keeper_state_machine.phase
  | Deferred_lifecycle of Keeper_lifecycle_admission.autonomous_denial

(** Signal a registered keeper without requiring a Running phase. Lifecycle
    admission is still mandatory: paused and dead-tombstone lanes are never
    made runnable by a hint signal. The typed intent is observability data,
    not a policy bypass. *)
val wakeup :
  intent:wakeup_intent -> base_path:string -> string -> wakeup_outcome

val wakeup_running :
  intent:wakeup_intent -> base_path:string -> string -> wakeup_outcome
(** Signal a registered Keeper only while its fiber phase is [Running]. The
    typed deferred outcomes let durable event producers distinguish an absent
    or inactive live hint without treating the already-committed payload as a
    delivery failure. *)

(** Set fiber_wakeup for all running keepers. *)
val wakeup_all : intent:wakeup_intent -> ?base_path:string -> unit -> unit

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

(** Check if a board-reactive wakeup is allowed (debounce). [dedup_key] is the
    key under which the wake is deduped — RFC-0239 R4 passes a content
    fingerprint rather than the raw post_id, so identical re-posts with fresh
    post_ids collapse. Records timestamp if allowed. Returns true for
    unregistered keepers. *)
val board_wakeup_allowed :
  base_path:string -> string -> dedup_key:string -> debounce_sec:float -> bool

(** Clear all board wakeup timestamps for a keeper. No-op if not found. *)
val clear_board_wakeups : base_path:string -> string -> unit

(** Reset tracking state (agent count + board wakeups) for a keeper. *)
val cleanup_tracking : base_path:string -> string -> unit

(** Reset tracking only if [entry]'s lane still owns its registry key. *)
val cleanup_tracking_exact : registry_entry -> exact_update_result

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

(* Lookup API moved to Keeper_registry_lookup:
   find_by_name / find_by_agent_name / find_by_id /
   tool_usage_of_by_name. *)

(* Tool usage persistence (flush_tool_usage / restore_tool_usage /
   tool_usage_path) moved to Keeper_registry_tool_usage_persistence.
   The CAS-bound write path is exposed below for that module's use. *)

(** Replace (or insert) a single per-tool usage entry on a registered keeper.
    Goes through the registry's CAS retry loop. Used by
    [Keeper_registry_tool_usage_persistence.restore] to replay persisted
    counters on re-registration. *)
val set_tool_usage_entry :
  base_path:string -> name:string -> tool_name:string
  -> Keeper_types.tool_call_entry -> unit

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

(** Dispatch only while [entry]'s lane still owns the registry key. The event
    is recomputed after same-lane CAS conflicts and is rejected before mutating
    a same-name replacement lane. *)
val dispatch_event_exact :
  registry_entry ->
  ?origin:lifecycle_event_origin ->
  Keeper_state_machine.event ->
  (Keeper_state_machine.transition_result, Keeper_state_machine.transition_error) result

val dispatch_event_exact_for_lifecycle :
  Keeper_lifecycle_reservation.token ->
  registry_entry ->
  ?origin:lifecycle_event_origin ->
  Keeper_state_machine.event ->
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

(** Like [dispatch_event], but logs and emits a Otel_metric_store counter on
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
(** Like [dispatch_event_with_audit], but logs and emits a Otel_metric_store
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

(* Event-queue access (enqueue_event / event_queue_snapshot / dequeue_event /
   drain_board_events) moved to Keeper_registry_event_queue. *)
