(** Keeper_registry — Single source of truth for keeper state.

    Core registry ops, atoms, entry management — extracted to
    [Keeper_registry_setup] (godfile decomp). *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

include Keeper_registry_setup

let set_turn_phase ~base_path name (turn_phase : packed_turn_phase) =
  (* RFC-0072 Phase 4b + Phase 5: dispatch via [resolve_turn_phase_transition]
     (PR #14912) instead of the [validate_turn_phase_transition] call.
     Mirrors the runtime-side wiring (PR #14908) — idempotent self-loops no
     longer flip [changed] or emit a broadcast, and forbidden transitions
     raise the typed [Turn_phase_transition_violation] (Phase 5) carrying
     the [turn_phase_transition_spec_violation] payload directly.  The
     violation branch stays wrapped by [Keeper_fsm_guard_runtime.wrap_unit]
     (PR #14926 pattern) so direct setter rejections keep incrementing
     [masc_fsm_guard_violation_total] — see the [Resolved_turn_violation]
     arm below. *)
  let now = Time_compat.now () in
  let changed =
    update_entry_if_registered ~base_path name (fun e ->
      let e', changed =
        update_current_turn e (fun obs ->
          match resolve_turn_phase_transition ~from:obs.turn_phase ~target:turn_phase with
          | Resolved_turn_idempotent -> obs
          | Resolved_turn_transition _ ->
            { (stamp_turn_progress ~now ~event_kind:"turn_phase" obs) with
              turn_phase
            }
          | Resolved_turn_violation violation ->
            (* #14926: route the violation raise through [wrap_unit] so the
               guard's Otel_metric_store counter [metric_fsm_guard_violation]
               (action=turn_phase_transition, stage=guard) keeps firing for
               forbidden transitions reached via this setter — prior to
               RFC-0072 Phase 4b (#14918) the instrumentation was transitive
               through [validate_turn_phase_transition], and the resolver swap
               dropped it.  Phase 5: the inner raise is now the typed
               [Turn_phase_transition_violation]; [wrap_unit]'s catch was
               widened to all exceptions so it still bumps the counter.  The
               trailing [obs] is unreachable (a no-op transition is the
               correct fallback should [wrap_unit] ever return). *)
            Keeper_fsm_guard_runtime.wrap_unit
              ~action:"turn_phase_transition"
              ~stage:"guard"
              (fun () ->
                 raise_turn_phase_transition_violation
                   ~where:"set_turn_phase"
                   ~from:obs.turn_phase
                   ~to_:turn_phase
                   ~violation);
            obs)
      in
      e', changed)
  in
  if changed then broadcast_composite_changed ~name ~ts_unix:now
;;

let mark_turn_provider_attempt_started ~base_path name =
  match get ~base_path name with
  | None | Some { current_turn_observation = None; _ } -> ()
  | Some _ ->
    set_turn_decision_stage
      ~base_path
      name
      Decision_active_tool_policy_selected;
    set_turn_phase ~base_path name (Packed Turn_executing)
;;

let set_turn_selected_model ~base_path name selected_model =
  let now = Time_compat.now () in
  let changed =
    update_entry_if_registered ~base_path name (fun e ->
      let e', changed =
        update_current_turn e (fun obs ->
          { (stamp_turn_progress ~now ~event_kind:"selected_model" obs) with
            selected_model
          })
      in
      e', changed)
  in
  if changed then broadcast_composite_changed ~name ~ts_unix:now
;;

let prepare_turn_retry_after_compaction ~base_path name =
  (* Routed through [set_turn_phase_with] so the compaction-retry reset uses
     the same resolver / guard / broadcast pathway as [set_turn_phase]. *)
  set_turn_phase_with
    ~base_path
    name
    ~event_kind:"retry_after_compaction"
    ~target:(Packed Turn_prompting)
    ~update_obs:(fun obs ->
      { obs with
        decision_stage = Packed Decision_guard_ok
      ; selected_model = None
      })
;;

let mark_turn_finished ~base_path name =
  (* Terminal turn lifecycle step: freeze [current_turn_observation] into
     [last_completed_turn] and clear the live observation.  This is
     intentionally NOT routed through [set_turn_phase_with]: it mutates the
     turn container (Some -> None) rather than transitioning the turn_phase
     sub-FSM.  It remains a separate, justified channel; the drift audit
     concern is the phase-transition setters that were duplicating resolver
     logic. *)
  let completed_turn_to_record = ref None in
  let now = Time_compat.now () in
  let changed =
    update_entry_if_registered ~base_path name (fun e ->
      let had_live_turn =
        match e.current_turn_observation with
        | Some _ -> true
        | None -> false
      in
      let last_completed_turn =
        match e.current_turn_observation with
        | Some obs ->
          let ended_at = now in
          completed_turn_to_record
          := Some
               { Keeper_transition_audit.turn_id = obs.turn_id
               ; started_at = obs.started_at
               ; ended_at
               ; outcome = completed_turn_outcome_of_observation obs
               };
          Some
            { ct_turn_id = obs.turn_id
            ; ct_started_at = obs.started_at
            ; ct_ended_at = ended_at
            ; ct_decision_stage = obs.decision_stage
            ; ct_selected_model = obs.selected_model
            ; ct_wake = obs.wake
            }
        | None -> e.last_completed_turn (* no live turn → preserve previous *)
      in
      let meta =
        if had_live_turn
        then
          { e.meta with
            runtime =
              { e.meta.runtime with
                usage = { e.meta.runtime.usage with last_turn_ts = now }
              }
          }
        else e.meta
      in
      { e with meta; current_turn_observation = None; last_completed_turn }, had_live_turn)
  in
  Option.iter
    (Keeper_transition_audit.record_completed_turn ~keeper_name:name)
    !completed_turn_to_record;
  (* IR-1 belt-and-suspenders: reset wakeup after turn completes so a stale
     true cannot suppress the next wakeup signal.  The primary consumer is
     [interruptible_sleep]'s CAS, but an explicit reset here guarantees the
     flag is clean regardless of whether the heartbeat loop's sleep path ran. *)
  (match get ~base_path name with
   (* tla-lint: allow-mutation: fiber signal — clear stale wakeup flag, paired with [interruptible_sleep] CAS *)
   | Some entry -> Atomic.set entry.fiber_wakeup false
   | None -> ());
  if changed then broadcast_composite_changed ~name ~ts_unix:now
;;

let record_skip_reasons ~base_path name ~reasons =
  (* Only stamp when there's at least one reason — empty lists from a
     [Run] verdict path would otherwise overwrite the last legitimate
     skip stamp with a no-op. *)
  if reasons <> []
  then (
    let now = Time_compat.now () in
    match
      update_entry ~base_path name (fun e ->
        { e with last_skip_observation = Some (now, reasons) })
    with
    | Ok () -> ()
    | Error err ->
      Log.Keeper.warn
        "%s: failed to record skip reasons: %s"
        name
        (registry_entry_validation_error_to_string err))
;;

let touch_last_turn_ts ~base_path name =
  let now = Time_compat.now () in
  match
    update_entry ~base_path name (fun e ->
      let runtime = e.meta.runtime in
      let usage = runtime.usage in
      { e with
        meta =
          { e.meta with
            runtime = { runtime with usage = { usage with last_turn_ts = now } }
          }
      })
  with
  | Ok () -> ()
  | Error err ->
    Log.Keeper.warn
      "%s: failed to touch last_turn_ts: %s"
      name
      (registry_entry_validation_error_to_string err)
;;

let increment_turn_failures ~base_path name =
  match
    update_entry ~base_path name (fun e ->
      { e with turn_consecutive_failures = e.turn_consecutive_failures + 1 })
  with
  | Ok () -> ()
  | Error err ->
    Log.Keeper.warn
      "%s: failed to increment turn failures: %s"
      name
      (registry_entry_validation_error_to_string err)
;;

let reset_turn_failures ~base_path name =
  match update_entry ~base_path name (fun e -> { e with turn_consecutive_failures = 0 }) with
  | Ok () -> ()
  | Error err ->
    Log.Keeper.warn
      "%s: failed to reset turn failures: %s"
      name
      (registry_entry_validation_error_to_string err)
;;

let get_turn_failures ~base_path name =
  match get ~base_path name with
  | Some e -> e.turn_consecutive_failures
  | None -> 0
;;

let is_running ~base_path name =
  (* Enumerate every [Keeper_state_machine.phase] variant so the
     compiler flags any new phase added to the FSM.

     This predicate is intentionally narrower than
     [Keeper_state_machine.can_execute_turn] (defined alongside the
     phase type): [can_execute_turn] returns [true] for both [Running]
     and [Failing] because a keeper in [Failing] may still complete
     its in-flight turn before the recovery transition; [is_running]
     answers the operator-facing question "is this keeper currently
     running?" and treats only [Running] as such. The 12 other phases
     (Offline, Failing, Overflowed, Compacting, HandingOff, Draining,
     Paused, Stopped, Crashed, Restarting, Dead) yield [false]
     here. A future phase variant (e.g. a hypothetical [Migrating] or
     [Healing]) would silently inherit [false] under the previous
     [Some _ -> false] catch-all without a review point on whether
     the new phase should count as "running" for any downstream
     consumer.

     Same FSM Sparse Match anti-pattern fix as PRs #14716, #14790,
     #14806, #14810, #14816, #14823, #14829, #14842, #14849. *)
  match get ~base_path name with
  | Some { phase = Running; _ } -> true
  | Some
      { phase =
          ( Offline
          | Failing
          | Overflowed
          | Compacting
          | HandingOff
          | Draining
          | Paused
          | Stopped
          | Crashed
          | Restarting
          | Dead )
      ; _
      } -> false
  | None -> false
;;

let is_boot_already_live ~base_path name =
  match get ~base_path name with
  | Some entry
    when entry.conditions.fiber_alive
         && not entry.conditions.stop_requested
         && (entry.phase = Running || entry.phase = Paused) ->
    true
  | Some _ | None -> false
;;

(** True if the keeper has ANY registry entry (regardless of state).
    Used by reconcile to avoid re-launching Crashed/Dead keepers. *)
let is_registered ~base_path name = Option.is_some (get ~base_path name)

let count_running ?base_path () =
  match base_path with
  | None -> Atomic.get running_count_atomic
  | Some expected ->
    let expected = canonical_base_path_exn expected in
    StringMap.fold
      (fun _k v acc ->
         if String.equal expected v.base_path && v.phase = Running then acc + 1 else acc)
      (Atomic.get registry)
      0
;;

let record_crash ~base_path name ts msg =
  let update_entry_unit ~base_path name f =
    ignore (update_entry ~base_path name f)
  in
  Error_tracking.record_crash ~base_path name ts msg ~update_entry:update_entry_unit
;;

let set_failure_reason_exact entry reason =
  update_entry_exact entry (fun current -> { current with last_failure_reason = reason })
;;

let set_last_error_exact entry err =
  update_entry_exact entry (fun current -> { current with last_error = Some err })
;;

let record_crash_exact entry ts msg =
  Log.Keeper.error "registry: recording exact-lane crash name=%s msg=%s" entry.name msg;
  update_entry_exact entry (fun current ->
    Error_tracking.record_crash_entry current ts msg)
;;

let exact_update_succeeded entry ~site = function
  | Exact_updated -> true
  | Exact_update_missing ->
    Log.Keeper.warn
      "%s: exact registry update skipped because lane is no longer registered site=%s"
      entry.name
      site;
    false
  | Exact_update_replaced ->
    Log.Keeper.warn
      "%s: exact registry update retained newer same-name lane site=%s"
      entry.name
      site;
    false
  | Exact_update_invalid validation_error ->
    Log.Keeper.warn
      "%s: exact registry update validation failed site=%s error=%s"
      entry.name
      site
      (registry_entry_validation_error_to_string validation_error);
    false
;;

let set_grpc_close ~base_path name close_fn =
  match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
  | Some entry -> Atomic.set entry.grpc_close close_fn
  | None -> ()
;;

let started_at ~base_path name =
  match get ~base_path name with
  | Some entry -> Some entry.started_at
  | None -> None
;;

let set_started_at_for_test ~base_path name started_at =
  match update_entry ~base_path name (fun entry -> { entry with started_at }) with
  | Ok () -> ()
  | Error err ->
    Log.Keeper.warn
      "%s: failed to set started_at test fixture: %s"
      name
      (registry_entry_validation_error_to_string err)
;;

module For_testing = struct
  let unsafe_put_entry = unsafe_put_entry
end

type wakeup_intent =
  | Reactive_signal
  | Scheduled_signal
  | Goal_signal
  | Supervisor_resume
  | Hitl_resolution
  | Broadcast_signal

let wakeup_intent_to_wire = function
  | Reactive_signal -> "reactive_signal"
  | Scheduled_signal -> "scheduled_signal"
  | Goal_signal -> "goal_signal"
  | Supervisor_resume -> "supervisor_resume"
  | Hitl_resolution -> "hitl_resolution"
  | Broadcast_signal -> "broadcast_signal"
;;

type wakeup_outcome =
  | Signaled
  | Deferred_unregistered
  | Deferred_not_running of Keeper_state_machine.phase
  | Deferred_lifecycle of Keeper_lifecycle_admission.autonomous_denial

let record_lifecycle_wakeup_denial ~intent (entry : registry_entry) denial =
  let reason = Keeper_lifecycle_admission.autonomous_denial_to_wire denial in
  let intent = wakeup_intent_to_wire intent in
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string LifecycleDispatchRejections)
    ~labels:
      [ "keeper", entry.name
      ; "event", "registry_wakeup"
      ; "reason", reason
      ; "intent", intent
      ]
    ();
  Log.Keeper.info
    "%s: registry wake deferred by lifecycle admission intent=%s reason=%s"
    entry.name
    intent
    reason
;;

let wakeup_entry ~intent ~require_running (entry : registry_entry) =
  let lifecycle_state =
    Keeper_lifecycle_admission.state
      ~paused:entry.meta.paused
      ~latched_reason:entry.meta.latched_reason
  in
  match Keeper_lifecycle_admission.admit_autonomous lifecycle_state with
  | Keeper_lifecycle_admission.Autonomous_denied denial ->
    record_lifecycle_wakeup_denial ~intent entry denial;
    Deferred_lifecycle denial
  | Keeper_lifecycle_admission.Autonomous_admitted ->
    if require_running && entry.phase <> Keeper_state_machine.Running
    then Deferred_not_running entry.phase
    else (
      (* tla-lint: allow-mutation: lifecycle-admitted fiber hint signal *)
      Atomic.set entry.fiber_wakeup true;
      Signaled)
;;

let wakeup ~intent ~base_path name =
  match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
  | None -> Deferred_unregistered
  | Some entry -> wakeup_entry ~intent ~require_running:true entry
;;

let wakeup_running ~intent ~base_path name =
  match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
  | None -> Deferred_unregistered
  | Some entry -> wakeup_entry ~intent ~require_running:true entry
;;

let wakeup_all ~intent ?base_path () =
  let base_path = Option.map canonical_base_path_exn base_path in
  StringMap.iter
    (fun _k entry ->
       match base_path with
       | Some expected when not (String.equal expected entry.base_path) -> ()
       | _ ->
         if entry.phase = Running
         then
           let (_ : wakeup_outcome) =
             wakeup_entry ~intent ~require_running:true entry
           in
           ())
    (Atomic.get registry)
;;

let fiber_health_of ~base_path name =
  match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
  | None -> Fiber_unknown
  | Some entry ->
    (match entry.phase with
     | Dead -> Fiber_dead
     | Crashed | Restarting -> Fiber_zombie
     | Stopped ->
       if lane_has_exited entry then Fiber_unknown else Fiber_alive
     | Offline -> Fiber_unknown
     | Running | Paused | Failing | Overflowed | Compacting | HandingOff | Draining ->
       (match Eio.Promise.peek entry.done_p with
        | None -> Fiber_alive
        | Some `Stopped ->
          if lane_has_exited entry then Fiber_unknown else Fiber_alive
        | Some (`Crashed _) ->
          if not (lane_has_exited entry) then Fiber_alive else Fiber_zombie))
;;

let crash_log_of ~base_path name =
  match get ~base_path name with
  | Some entry -> entry.crash_log
  | None -> []
;;

let restore_supervisor_state ~base_path name ~restart_count ~last_restart_ts ~crash_log =
  Error_tracking.restore_supervisor_state
    ~base_path
    name
    ~restart_count
    ~last_restart_ts
    ~crash_log
    ~update_entry:update_entry_unit
;;

(* [dedup_key] is the key under which a board wakeup is deduped. RFC-0239 R4
   keys it on a content fingerprint rather than the raw post_id, so identical
   re-posts (each with a fresh post_id) collapse into one wake per window. The
   map is otherwise a generic (key -> last_ts) debounce. *)
let board_wakeup_allowed ~base_path name ~dedup_key ~debounce_sec =
  (* RFC-0303 Phase 3: the no-progress wake-tombstone gate is removed (the
     detector that fed it is retired). The per-key debounce (dedup) below is a
     separate concern and stays: identical re-posts still collapse into one wake
     per window. *)
  match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
  | None -> true
  | Some entry ->
    let now_ts = Time_compat.now () in
    (match StringMap.find_opt dedup_key entry.board_wakeups with
     | Some last_ts when now_ts -. last_ts < debounce_sec -> false
     | _ ->
       (match
          update_entry ~base_path name (fun e ->
            { e with board_wakeups = StringMap.add dedup_key now_ts e.board_wakeups })
        with
        | Ok () -> ()
        | Error err ->
          Log.Keeper.warn
            "%s: failed to record board wakeup dedupe key: %s"
            name
            (registry_entry_validation_error_to_string err));
       true)
;;

let clear_board_wakeups ~base_path name =
  match update_entry ~base_path name (fun e -> { e with board_wakeups = StringMap.empty }) with
  | Ok () -> ()
  | Error err ->
    Log.Keeper.warn
      "%s: failed to clear board wakeups: %s"
      name
      (registry_entry_validation_error_to_string err)
;;

let cleanup_tracking ~base_path name =
  let key = registry_key ~base_path name in
  match StringMap.find_opt key (Atomic.get registry) with
  | Some entry ->
    (match
       put_entry
         ~base_path
         name
         { entry with
           board_wakeups = StringMap.empty
         ; tool_usage = StringMap.empty
         ; board_cursor_ts = 0.0
         ; board_cursor_post_id = None
         }
     with
     | Ok () -> ()
     | Error err ->
       Log.Keeper.warn
         "%s: failed to cleanup registry tracking: %s"
         name
         (registry_entry_validation_error_to_string err))
  | None -> ()
;;

let cleanup_tracking_exact (entry : registry_entry) =
  update_entry_exact entry (fun current ->
    { current with
      board_wakeups = StringMap.empty
    ; tool_usage = StringMap.empty
    ; board_cursor_ts = 0.0
    ; board_cursor_post_id = None
    })
;;

let clear () =
  Atomic.set registry StringMap.empty;
  Atomic.set running_count_atomic 0
;;

(* -- Board cursor -------------------------------------------------- *)

let get_board_cursor_ts ~base_path name =
  match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
  | Some entry -> entry.board_cursor_ts
  | None -> 0.0
;;

let set_board_cursor_ts ~base_path name ts =
  match
    update_entry ~base_path name (fun e ->
      let board_cursor_post_id =
        if Float.compare ts e.board_cursor_ts = 0 then e.board_cursor_post_id else None
      in
      { e with board_cursor_ts = ts; board_cursor_post_id })
  with
  | Ok () -> ()
  | Error err ->
    Log.Keeper.warn
      "%s: failed to set board cursor timestamp: %s"
      name
      (registry_entry_validation_error_to_string err)
;;

let get_board_cursor ~base_path name =
  match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
  | Some entry -> entry.board_cursor_ts, entry.board_cursor_post_id
  | None -> 0.0, None
;;

let set_board_cursor ~base_path name ts post_id =
  match
    update_entry ~base_path name (fun e ->
      { e with board_cursor_ts = ts; board_cursor_post_id = post_id })
  with
  | Ok () -> ()
  | Error err ->
    Log.Keeper.warn
      "%s: failed to set board cursor: %s"
      name
      (registry_entry_validation_error_to_string err)
;;

(* -- Tool usage tracking ------------------------------------------- *)

(* Safe without a mutex: updates go through [update_entry]'s CAS loop, so
   keeper-turn OAS callbacks and runtime MCP server callbacks can both
   record usage for the same keeper without clobbering each other. *)
let record_tool_use ~base_path name ~tool_name ~disposition =
  match
    update_entry ~base_path name (fun entry ->
      let e =
        match StringMap.find_opt tool_name entry.tool_usage with
        | Some e -> e
        | None ->
          { count = 0; successes = 0; deferred = 0; failures = 0; last_used_at = 0.0 }
      in
      let updated =
        { count = e.count + 1
        ; successes =
            (match disposition with
             | Tool_result.Completed _ -> e.successes + 1
             | Tool_result.Deferred _ | Tool_result.Failed _ -> e.successes)
        ; deferred =
            (match disposition with
             | Tool_result.Deferred _ -> e.deferred + 1
             | Tool_result.Completed _ | Tool_result.Failed _ -> e.deferred)
        ; failures =
            (match disposition with
             | Tool_result.Failed _ -> e.failures + 1
             | Tool_result.Completed _ | Tool_result.Deferred _ -> e.failures)
        ; last_used_at = Time_compat.now ()
        }
      in
      { entry with tool_usage = StringMap.add tool_name updated entry.tool_usage })
  with
  | Ok () -> ()
  | Error err ->
    Log.Keeper.warn
      "%s: failed to record tool use for %s: %s"
      name
      tool_name
      (registry_entry_validation_error_to_string err)
;;

let tool_usage_of ~base_path name =
  match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
  | None -> []
  | Some entry ->
    StringMap.fold (fun n e acc -> (n, e) :: acc) entry.tool_usage []
    |> List.sort (fun (_, a) (_, b) -> Int.compare b.Keeper_types.count a.Keeper_types.count)
;;

(* Lookup API (find_by_name / find_by_agent_name / find_by_id /
   tool_usage_of_by_name) moved to Keeper_registry_lookup.

   Tool usage persistence (tool_usage_path / flush_tool_usage /
   restore_tool_usage) moved to Keeper_registry_tool_usage_persistence;
   the CAS-bound write path is exposed below as
   [set_tool_usage_entry]. *)

let set_tool_usage_entry ~base_path ~name ~tool_name (e : tool_call_entry) =
  match
    update_entry ~base_path name (fun ent ->
      { ent with tool_usage = StringMap.add tool_name e ent.tool_usage })
  with
  | Ok () -> ()
  | Error err ->
    Log.Keeper.warn
      "%s: failed to restore tool usage for %s: %s"
      name
      tool_name
      (registry_entry_validation_error_to_string err)
;;

(* ── RFC-0002 Event Dispatch ───────────────────────────── *)

let validate_paired_lifecycle_origin = Keeper_registry_event_validators.paired_lifecycle_origin

(* Entry-action dispatch observability helpers
   (execute_entry_action_observability / followup_event_of_entry_action /
   record_followup_dispatch_rejection) moved to
   Keeper_registry_entry_action_dispatch. *)
let execute_entry_action_observability =
  Keeper_registry_entry_action_dispatch.execute_observability
;;
let followup_event_of_entry_action =
  Keeper_registry_entry_action_dispatch.followup_event_of_action
;;
let record_followup_dispatch_rejection =
  Keeper_registry_entry_action_dispatch.record_dispatch_rejection
;;

let validate_compaction_transition = Keeper_registry_event_validators.compaction_transition

let compaction_stage_after_event entry event =
  let old_stage = entry.compaction_stage in
  let new_stage = compaction_stage_of_event entry event in
  validate_compaction_transition ~from:old_stage ~to_:new_stage;
  new_stage
;;

(** Registry mutation is still non-yielding (StringMap lookup + CAS).
    Entry actions run only after [install_entry_if_current], so any
    observability or follow-up state transitions happen after the registry
    state is consistent. *)
let rec dispatch_event_with_audit_internal
          ~base_path
          ?lifecycle_token
          ?expected_lane
          ?(origin = Generic_dispatch)
          ?snapshot
          ?events_fired
          ?selected_event
          name
          (event : Keeper_state_machine.event)
  =
  let key = registry_key ~base_path name in
  match StringMap.find_opt key (Atomic.get registry) with
  | None ->
    Error
      (Keeper_state_machine.Invalid_transition
         { from_phase = Keeper_state_machine.Offline
         ; to_phase = Keeper_state_machine.Offline
         ; reason = Printf.sprintf "keeper %s not registered" name
         })
  | Some entry
    when (match expected_lane with
          | None -> false
          | Some lane_id ->
            not (Keeper_lane.Id.equal lane_id (Keeper_lane.id entry.lane))) ->
    Error
      (Keeper_state_machine.Invalid_transition
         { from_phase = entry.phase
         ; to_phase = entry.phase
         ; reason = Printf.sprintf "keeper %s lane ownership changed" name
         })
  | Some entry ->
    let now = Time_compat.now () in
    (* Retain the last auto-rule summary emitted with a [Context_measured]
       event so downstream read-only observers (RFC-0003 composite
       observer) can project it without reading history files. Other
       events leave the field untouched. *)
    let last_context_actions =
      match event with
      | Keeper_state_machine.Context_measured { context_actions; _ } -> Some (now, context_actions)
      | _ -> entry.last_context_actions
    in
    let origin_result = validate_paired_lifecycle_origin origin event in
    let pending_turn_measurement = pending_measurement_after_event now entry event in
    let compaction_stage =
      match origin_result with
      | Error _ -> entry.compaction_stage
      | Ok () -> compaction_stage_after_event entry event
    in
    let result =
      match origin_result with
      | Error _ as err -> err
      | Ok () ->
        Keeper_state_machine.apply_event
          ~current_phase:entry.phase
          ~conditions:entry.conditions
          ~event
          ~now
    in
    let record_transition_attribution tr =
      Dashboard_attribution.record
        (Keeper_state_machine.attribution_of_transition ~event (Ok tr))
    in
    let registry_write_error ~from_phase ~to_phase err =
      Keeper_state_machine.Invalid_transition
        { from_phase
        ; to_phase
        ; reason =
            Printf.sprintf
              "registry write validation failed for event=%s: %s"
              (Keeper_state_machine.event_to_string event)
              (registry_entry_validation_error_to_string err)
        }
    in
    let reject_dispatch e =
      Dashboard_attribution.record
        (Keeper_state_machine.attribution_of_transition ~event (Error e));
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string LifecycleDispatchRejections)
        ~labels:[ "event", Keeper_state_machine.event_to_string event ]
        ();
      let event_str = Keeper_state_machine.event_to_string event in
      let error_str = Keeper_state_machine.transition_error_to_string e in
      Log.Keeper.emit
        Log.Warn
        ~category:Log.Fsm
        ~details:
          (`Assoc
            [ "event", `String event_str
            ; "error", `String error_str
            ])
        (Printf.sprintf "registry: dispatch_event rejected name=%s error=%s" name error_str);
      Error e
    in
    (match result with
     | Ok tr when tr.new_phase <> tr.prev_phase ->
       let from_phase_str = Keeper_state_machine.phase_to_string tr.prev_phase in
       let to_phase_str = Keeper_state_machine.phase_to_string tr.new_phase in
       let event_str = Keeper_state_machine.event_to_string event in
       (* Update dead_since_ts: always set to now on Dead transition *)
       let dead_since_ts =
         match tr.new_phase with
         | Keeper_state_machine.Dead -> Some now
         | _ -> None
       in
       let new_seq = entry.transition_seq + 1 in
       (match
          install_entry_if_current_internal
            ?lifecycle_token
            ~observed:entry
            { entry with
              phase = tr.new_phase
            ; conditions = tr.updated_conditions
            ; dead_since_ts
            ; transition_seq = new_seq
            ; last_context_actions
            ; pending_turn_measurement
            ; compaction_stage
            }
        with
        | Entry_install_invalid err ->
          reject_dispatch
            (registry_write_error
               ~from_phase:tr.prev_phase
               ~to_phase:tr.new_phase
               err)
        | Entry_install_conflict ->
          dispatch_event_with_audit_internal
            ~base_path
            ?lifecycle_token
            ?expected_lane
            ~origin
            ?snapshot
            ?events_fired
            ?selected_event
            name
            event
        | Entry_install_missing ->
          reject_dispatch
            (Keeper_state_machine.Invalid_transition
               { from_phase = tr.prev_phase
               ; to_phase = tr.prev_phase
               ; reason = Printf.sprintf "keeper %s was unregistered during dispatch" name
               })
        | Entry_install_replaced ->
          reject_dispatch
            (Keeper_state_machine.Invalid_transition
               { from_phase = tr.prev_phase
               ; to_phase = tr.prev_phase
               ; reason = Printf.sprintf "keeper %s lane ownership changed during dispatch" name
               })
        | Entry_installed ->
          record_transition_attribution tr;
          Log.Keeper.emit
            Log.Info
            ~category:Log.Fsm
            ~details:
              (`Assoc
                [ "from_phase", `String from_phase_str
                ; "to_phase", `String to_phase_str
                ; "event", `String event_str
                ])
            (Printf.sprintf
               "registry: phase transition name=%s old=%s new=%s event=%s"
               name
               from_phase_str
               to_phase_str
               event_str);
          (* Record transition in audit ring buffer for dashboard API. *)
          (* DET-OK: absent audit selection falls back to this dispatch event. *)
          let audit_events_fired = Option.value events_fired ~default:[ event ] in
          let audit_selected_event = Option.value selected_event ~default:event in
          Keeper_transition_audit.record_transition
            ~keeper_name:name
            { snapshot
            ; events_fired = audit_events_fired
            ; selected_event = audit_selected_event
            ; prev_phase = tr.prev_phase
            ; new_phase = tr.new_phase
            ; transition_outcome = "applied"
            ; wall_clock_at_decision = now
            };
          Keeper_lifecycle_hooks.run
            ~base_dir:base_path
            ~meta:entry.meta
            ~keeper_id:name
            (Keeper_lifecycle_hooks.Phase_transition
               { from_phase = tr.prev_phase; to_phase = tr.new_phase });
          (* Broadcast phase transition to SSE subscribers *)
          (try
             Sse.broadcast
               (`Assoc
                   [ "type", `String "keeper_phase_changed"
                   ; "name", `String name
                   ; ( "prev_phase"
                     , `String (Keeper_state_machine.phase_to_string tr.prev_phase) )
                   ; "new_phase", `String (Keeper_state_machine.phase_to_string tr.new_phase)
                   ; "event", `String (Keeper_state_machine.event_to_string event)
                   ; "ts_unix", `Float now
                   ])
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn -> record_phase_broadcast_failure ~name exn);
          (* Update running count based on phase transition *)
          (match tr.prev_phase, tr.new_phase with
           | Running, phase when phase <> Running -> decr_running_count_clamped ()
           | phase, Running when phase <> Running -> Atomic.incr running_count_atomic
           | _ -> ());
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string LifecycleTransitions)
            ~labels:
              [ "keeper", name
              ; "from_phase", Keeper_state_machine.phase_to_string tr.prev_phase
              ; "to_phase", Keeper_state_machine.phase_to_string tr.new_phase
              ]
            ();
          (* TLA+ trace emission (MASC_TLA_TRACE=1) *)
          if Keeper_trace_emit.enabled ()
          then
            Keeper_trace_emit.emit_transition
              ~keeper_name:name
              ~base_path
              ~seq:new_seq
              ~event
              ~prev_phase:tr.prev_phase
              ~new_phase:tr.new_phase
              ~conditions_after:tr.updated_conditions
              ~restart_count:entry.restart_count;
          List.iter
            (execute_entry_action_observability ~name ~phase:tr.new_phase ~ts_unix:now)
            tr.entry_actions;
          List.iter
            (fun followup_event ->
               match
                 dispatch_event_with_audit_internal
                   ~base_path
                   ?lifecycle_token
                   ?expected_lane
                   name
                   followup_event
               with
            | Ok _ -> ()
            | Error
                (Keeper_state_machine.Invalid_transition { from_phase; to_phase; reason })
              ->
              record_followup_dispatch_rejection followup_event;
              let from_phase_str = Keeper_state_machine.phase_to_string from_phase in
              let to_phase_str = Keeper_state_machine.phase_to_string to_phase in
              Log.Keeper.emit
                Log.Error
                ~category:Log.Fsm
                ~details:
                  (`Assoc
                    [ "from_phase", `String from_phase_str
                    ; "to_phase", `String to_phase_str
                    ; "reason", `String reason
                    ])
                (Printf.sprintf
                   "registry(%s): followup dispatch failed: %s -> %s (%s)"
                   name
                   from_phase_str
                   to_phase_str
                   reason)
            | Error (Keeper_state_machine.Terminal_state { current; attempted_event }) ->
              record_followup_dispatch_rejection followup_event;
              let current_phase_str = Keeper_state_machine.phase_to_string current in
              Log.Keeper.emit
                Log.Warn
                ~category:Log.Fsm
                ~details:
                  (`Assoc
                    [ "current_phase", `String current_phase_str
                    ; "attempted_event", `String attempted_event
                    ])
                (Printf.sprintf
                   "registry(%s): followup skipped, already terminal: %s (event: %s)"
                   name
                   current_phase_str
                   attempted_event)
            | Error (Keeper_state_machine.Precondition_violation { event = ev; reason })
              ->
              record_followup_dispatch_rejection followup_event;
              Log.Keeper.emit
                Log.Warn
                ~category:Log.Fsm
                ~details:(`Assoc [ "event", `String ev; "reason", `String reason ])
                (Printf.sprintf
                   "registry(%s): followup skipped, precondition violated: %s (%s)"
                   name
                   ev
                   reason))
            (List.filter_map
               (followup_event_of_entry_action ~phase:tr.new_phase)
               tr.entry_actions);
          (* Composite-lifecycle SSE envelope — RFC-0003 §6.
             The body carries only the keeper name and observation timestamp;
             subscribers re-fetch [/api/v1/keepers/:name/composite] for the
             full snapshot so the spec's "single writer, pull observers"
             invariant is preserved. *)
          broadcast_composite_changed ~name ~ts_unix:now;
          Ok tr)
     | Ok tr ->
       (* No phase change — still update conditions *)
       let new_seq = entry.transition_seq + 1 in
       (match
          install_entry_if_current_internal
            ?lifecycle_token
            ~observed:entry
            { entry with
              conditions = tr.updated_conditions
            ; transition_seq = new_seq
            ; last_context_actions
            ; pending_turn_measurement
            ; compaction_stage
            }
        with
        | Entry_install_invalid err ->
          reject_dispatch
            (registry_write_error
               ~from_phase:tr.prev_phase
               ~to_phase:tr.new_phase
               err)
        | Entry_install_conflict ->
          dispatch_event_with_audit_internal
            ~base_path
            ?lifecycle_token
            ?expected_lane
            ~origin
            ?snapshot
            ?events_fired
            ?selected_event
            name
            event
        | Entry_install_missing ->
          reject_dispatch
            (Keeper_state_machine.Invalid_transition
               { from_phase = tr.prev_phase
               ; to_phase = tr.prev_phase
               ; reason = Printf.sprintf "keeper %s was unregistered during dispatch" name
               })
        | Entry_install_replaced ->
          reject_dispatch
            (Keeper_state_machine.Invalid_transition
               { from_phase = tr.prev_phase
               ; to_phase = tr.prev_phase
               ; reason = Printf.sprintf "keeper %s lane ownership changed during dispatch" name
               })
        | Entry_installed ->
          record_transition_attribution tr;
          if Keeper_trace_emit.enabled ()
          then
            Keeper_trace_emit.emit_transition
              ~keeper_name:name
              ~base_path
              ~seq:new_seq
              ~event
              ~prev_phase:tr.prev_phase
              ~new_phase:tr.new_phase
              ~conditions_after:tr.updated_conditions
              ~restart_count:entry.restart_count;
          broadcast_composite_changed ~name ~ts_unix:now;
          Ok tr)
     | Error e -> reject_dispatch e)
;;

let dispatch_event_with_audit
      ~base_path
      ?(origin = Generic_dispatch)
      ?snapshot
      ?events_fired
      ?selected_event
      name
      event
  =
  dispatch_event_with_audit_internal
    ~base_path
    ~origin
    ?snapshot
    ?events_fired
    ?selected_event
    name
    event
;;

let dispatch_event_exact
      (entry : registry_entry)
      ?(origin = Generic_dispatch)
      event
  =
  dispatch_event_with_audit_internal
    ~base_path:entry.base_path
    ~expected_lane:(Keeper_lane.id entry.lane)
    ~origin
    entry.name
    event
;;

let dispatch_event_exact_for_lifecycle
      token
      (entry : registry_entry)
      ?(origin = Generic_dispatch)
      event
  =
  dispatch_event_with_audit_internal
    ~base_path:entry.base_path
    ~lifecycle_token:token
    ~expected_lane:(Keeper_lane.id entry.lane)
    ~origin
    entry.name
    event
;;

let dispatch_event ~base_path ?(origin = Generic_dispatch) name event =
  dispatch_event_with_audit ~base_path ~origin name event
;;

let dispatch_event_and_log ~base_path ?(origin = Generic_dispatch) name event =
  match dispatch_event ~base_path ~origin name event with
  | Ok tr -> Ok tr
  | Error e ->
    let reason_label =
      match e with
      | Keeper_state_machine.Terminal_state _ -> "terminal_state"
      | Keeper_state_machine.Invalid_transition _ -> "invalid_transition"
      | Keeper_state_machine.Precondition_violation _ -> "precondition_violation"
    in
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string DispatchEventFailures)
      ~labels:[ "keeper", name; "reason", reason_label ]
      ();
    Error e
;;

let dispatch_event_unit ~base_path ?(origin = Generic_dispatch) name event =
  match dispatch_event_and_log ~base_path ~origin name event with
  | Ok _ -> ()
  | Error e ->
    let error_str = Keeper_state_machine.transition_error_to_string e in
    Log.Keeper.emit
      Log.Warn
      ~category:Log.Fsm
      ~details:
        (`Assoc
          [ "event", `String (Keeper_state_machine.event_to_string event)
          ; "error", `String error_str
          ])
      (Printf.sprintf "%s: dispatch_event failed: %s" name error_str)
;;

let dispatch_event_with_audit_and_log
      ~base_path
      ?(origin = Generic_dispatch)
      ?snapshot
      ?events_fired
      ?selected_event
      name
      event
  =
  match
    dispatch_event_with_audit
      ~base_path
      ~origin
      ?snapshot
      ?events_fired
      ?selected_event
      name
      event
  with
  | Ok tr -> Ok tr
  | Error e ->
    let reason_label =
      match e with
      | Keeper_state_machine.Terminal_state _ -> "terminal_state"
      | Keeper_state_machine.Invalid_transition _ -> "invalid_transition"
      | Keeper_state_machine.Precondition_violation _ -> "precondition_violation"
    in
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string DispatchEventFailures)
      ~labels:[ "keeper", name; "reason", reason_label ]
      ();
    Error e
;;

let prepare_fiber_launch ~base_path name =
  (match get ~base_path name with
   | Some entry ->
     (* tla-lint: allow-mutation: fiber signal — initialise per-fiber Atomic flags before keeper launch *)
     Atomic.set entry.fiber_stop false;
     Atomic.set entry.fiber_wakeup false;
     Atomic.set entry.waiting_for_inference false
   | None ->
     (* P3 cleanup: previously this was a silent no-op when the
          keeper was not yet registered.  The dispatch_event call
          below still fires even in this case, which can leave a
          Fiber_started event with no corresponding atomic-flag
          reset.  Log so the race is at least visible — caller
          (server_runtime_bootstrap.ml) is responsible for ensuring
          register_with_state has happened before this point. *)
     Log.Keeper.emit
       Log.Warn
       ~category:Log.Fsm
       ~details:(`Assoc [ "keeper", `String name; "base_path", `String base_path ])
       (Printf.sprintf
          "registry: prepare_fiber_launch name=%s base_path=%s: entry not registered, \
           skipping flag reset"
          name
          base_path));
  dispatch_event ~base_path name Keeper_state_machine.Fiber_started
;;

let prepare_fiber_launch_for_lifecycle token (entry : registry_entry) =
  Atomic.set entry.fiber_stop false;
  Atomic.set entry.fiber_wakeup false;
  Atomic.set entry.waiting_for_inference false;
  dispatch_event_exact_for_lifecycle token entry Keeper_state_machine.Fiber_started
;;

let get_phase ~base_path name =
  match get ~base_path name with
  | Some entry -> Some entry.phase
  | None -> None
;;

let get_conditions ~base_path name =
  match get ~base_path name with
  | Some entry -> Some entry.conditions
  | None -> None
;;

(* Event-queue access (enqueue_event / event_queue_snapshot / dequeue_event /
   drain_board_events) moved to Keeper_registry_event_queue. *)
