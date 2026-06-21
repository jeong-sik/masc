(** Keeper_registry — SSOT for keeper state. Atomic.t + persistent StringMap; no mutex needed in single-domain Eio. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile

(** Failure-reason cluster re-included from Keeper_registry_types for backward compatibility. *)
include Keeper_registry_types

let registry : registry_entry StringMap.t Atomic.t = Atomic.make StringMap.empty
let running_count_atomic = Atomic.make 0
module Orphan_drops = Keeper_registry_orphan_drops
module Spawn_slots = Keeper_registry_spawn_slots
module Error_tracking = Keeper_registry_error_tracking

(** CAS loop for clamped decrement.  [Atomic.fetch_and_add _ (-1)] can leave the counter negative if increment/decrement paths interleave, so we retry until we successfully install [max 0 (cur - 1)]. *)
let decr_running_count_clamped () =
  let rec loop () =
    let cur = Atomic.get running_count_atomic in
    let next = max 0 (cur - 1) in
    if not (Atomic.compare_and_set running_count_atomic cur next) then loop ()
  in
  loop ()
;;

(** Lock-free CAS loop for registry writes. Atomic.t used instead of Eio.Mutex for non-Eio context compatibility (#7011 pattern). *)

let put_entry key entry =
  let rec loop () =
    let current = Atomic.get registry in
    let updated = StringMap.add key entry current in
    if not (Atomic.compare_and_set registry current updated) then loop ()
  in
  loop ()
;;

(** Apply [f entry] and write back.  No-op if key absent.  The find + apply + write is serialised via CAS so that concurrent [update_entry] calls on the same key cannot both operate on a stale [entry] ... *)
let update_entry ~base_path name f =
  let key = registry_key ~base_path name in
  let rec loop () =
    let current = Atomic.get registry in
    match StringMap.find_opt key current with
    | None ->
      let count, breached = Orphan_drops.record ~base_path name in
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string RegistryUpdateDropped)
        ~labels:[ "name", name ]
        ();
      if breached
      then (
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string RegistryOrphanThresholdBreached)
          ~labels:[ "name", name ]
          ();
        Log.Keeper.warn
          "registry: orphan threshold breached name=%s base_path=%s drops=%d \
           window=%.0fs — turn fiber may be racing post-deregistration; check \
           masc_keeper_status and watchdog"
          name
          base_path
          count
          Orphan_drops.window_sec)
      else
        Log.Keeper.debug
          "registry: update_entry name=%s base_path=%s: entry not found, update dropped \
           (count=%d)"
          name
          base_path
          count
    | Some entry ->
      let updated = StringMap.add key (f entry) current in
      if not (Atomic.compare_and_set registry current updated)
      then loop ()
      else Orphan_drops.clear ~base_path name
  in
  loop ()
;;

let update_entry_if_registered ~base_path name f =
  let key = registry_key ~base_path name in
  let rec loop () =
    let current = Atomic.get registry in
    match StringMap.find_opt key current with
    | None -> ()
    | Some entry ->
      let updated = StringMap.add key (f entry) current in
      if Atomic.compare_and_set registry current updated
      then Orphan_drops.clear ~base_path name
      else loop ()
  in
  loop ()
;;

let rec queue_contains_stimulus queue stimulus =
  match Keeper_event_queue.dequeue queue with
  | None -> false
  | Some (head, rest) -> head = stimulus || queue_contains_stimulus rest stimulus
;;

let enqueue_missing_stimulus queue stimulus =
  if queue_contains_stimulus queue stimulus
  then queue
  else Keeper_event_queue.enqueue queue stimulus
;;

let merge_event_queues ~durable ~live =
  let rec loop acc queue =
    match Keeper_event_queue.dequeue queue with
    | None -> acc
    | Some (stimulus, rest) -> loop (enqueue_missing_stimulus acc stimulus) rest
  in
  loop durable live
;;

let refresh_entry_event_queue_from_persistence ~base_path name entry =
  let durable = Keeper_event_queue_persistence.load ~base_path ~keeper_name:name in
  let rec loop () =
    let live = Atomic.get entry.event_queue in
    let merged = merge_event_queues ~durable ~live in
    if merged = live
    then ()
    else if Atomic.compare_and_set entry.event_queue live merged
    then
      Keeper_event_queue_persistence.persist_snapshot
        ~base_path
        ~keeper_name:name
        (fun () -> Atomic.get entry.event_queue)
    else loop ()
  in
  loop ()
;;

let register_with_state
      ~base_path
      name
      meta
      ~(phase : Keeper_state_machine.phase)
      ~(conditions : Keeper_state_machine.conditions)
  =
  Log.Keeper.info
    "registry: registering keeper name=%s base_path=%s phase=%s"
    name
    base_path
    (Keeper_state_machine.phase_to_string phase);
  let done_p, done_r = Eio.Promise.create () in
  let key = registry_key ~base_path name in
  (match StringMap.find_opt key (Atomic.get registry) with
   | Some entry when entry.phase = Running ->
     Otel_metric_store.inc_counter
       Keeper_metrics.(to_string LifecycleDispatchRejections)
       ~labels:[ "keeper", name; "event", "register_overwrite_running" ]
       ();
     Log.Keeper.warn "registry: overwriting running keeper during register name=%s" name;
     decr_running_count_clamped ()
   | _ -> ());
  let initial_event_queue =
    Keeper_event_queue_persistence.load ~base_path ~keeper_name:name
  in
  let entry =
    { base_path
    ; name
    ; meta
    ; phase
    ; conditions
    ; fiber_stop = Atomic.make false
    ; fiber_wakeup = Atomic.make false
    ; event_queue = Atomic.make initial_event_queue
    ; started_at = Time_compat.now ()
    ; grpc_close = Atomic.make None
    ; done_p
    ; done_r
    ; restart_count = 0
    ; last_restart_ts = 0.0
    ; dead_since_ts = None
    ; crash_log = []
    ; last_error = None
    ; last_failure_reason = None
    ; turn_consecutive_failures = 0
    ; livelock_state = Atomic.make None
    ; board_wakeups = StringMap.empty
    ; board_cursor_ts = 0.0
    ; board_cursor_post_id = None
    ; tool_usage = StringMap.empty
    ; transition_seq = 0
    ; waiting_for_inference = Atomic.make false
    ; last_auto_rules = None
    ; last_event_bus_correlation = None
    ; pending_turn_measurement = None
    ; current_turn_observation = None
    ; last_completed_turn = None
    ; last_skip_observation = None
    ; compaction_stage = Packed Compaction_accumulating
    }
  in
  put_entry key entry;
  if phase = Running then Atomic.incr running_count_atomic;
  Log.Keeper.debug
    "registry: keeper registered name=%s running_count=%d"
    name
    (Atomic.get running_count_atomic);
  refresh_entry_event_queue_from_persistence ~base_path name entry;
  entry
;;

let register ~base_path name meta =
  let conditions =
    { Keeper_state_machine.default_conditions with
      fiber_alive = true
    ; restart_budget_remaining = true
    }
  in
  let phase = Keeper_state_machine.derive_phase conditions in
  register_with_state ~base_path name meta ~phase ~conditions
;;

let register_offline ~base_path name meta =
  let conditions =
    { Keeper_state_machine.default_conditions with
      launch_pending = true
    ; restart_budget_remaining = true
    }
  in
  let phase = Keeper_state_machine.derive_phase conditions in
  register_with_state ~base_path name meta ~phase ~conditions
;;

(** R-A-6.a — refuse to revive a keeper whose restart_budget was previously exhausted.  Pairs with TLA+ §S3 BudgetNeverRevives:  []( ~restart_budget_remaining => []( ~restart_budget_remaining ))  Witho... *)
type register_restarting_error = Budget_already_exhausted of { name : string }

let register_restarting ~base_path name meta
  : (registry_entry, register_restarting_error) result
  =
  let key = registry_key ~base_path name in
  let conditions =
    { Keeper_state_machine.default_conditions with
      restart_budget_remaining = true
    ; backoff_elapsed = true
    }
  in
  let phase = Keeper_state_machine.derive_phase conditions in
  (* Build fresh entry once — its per-fiber atomics are independent of the
     registry contents, so a CAS retry can re-use the same record without
     re-allocating. Pending Event Layer stimuli are restored from the durable
     queue snapshot instead of being reset across restart. *)
  let done_p, done_r = Eio.Promise.create () in
  let initial_event_queue =
    Keeper_event_queue_persistence.load ~base_path ~keeper_name:name
  in
  let new_entry =
    { base_path
    ; name
    ; meta
    ; phase
    ; conditions
    ; fiber_stop = Atomic.make false
    ; fiber_wakeup = Atomic.make false
    ; event_queue = Atomic.make initial_event_queue
    ; started_at = Time_compat.now ()
    ; grpc_close = Atomic.make None
    ; done_p
    ; done_r
    ; restart_count = 0
    ; last_restart_ts = 0.0
    ; dead_since_ts = None
    ; crash_log = []
    ; last_error = None
    ; last_failure_reason = None
    ; turn_consecutive_failures = 0
    ; livelock_state = Atomic.make None
    ; board_wakeups = StringMap.empty
    ; board_cursor_ts = 0.0
    ; board_cursor_post_id = None
    ; tool_usage = StringMap.empty
    ; transition_seq = 0
    ; waiting_for_inference = Atomic.make false
    ; last_auto_rules = None
    ; last_event_bus_correlation = None
    ; pending_turn_measurement = None
    ; current_turn_observation = None
    ; last_completed_turn = None
    ; last_skip_observation = None
    ; compaction_stage = Packed Compaction_accumulating
    }
  in
(* Guard + write in a single CAS loop so a concurrent budget-exhaust update between our read and write cannot be overwritten back to [restart_budget_remaining = true].  Without this loop, two threads ... *)
  let rec loop () =
    let current = Atomic.get registry in
    match StringMap.find_opt key current with
    | Some prior when not prior.conditions.restart_budget_remaining ->
      Error (Budget_already_exhausted { name })
    | _ ->
      let updated = StringMap.add key new_entry current in
      if Atomic.compare_and_set registry current updated
      then (
        Log.Keeper.info
          "registry: registering keeper name=%s base_path=%s phase=%s"
          name
          base_path
          (Keeper_state_machine.phase_to_string phase);
        refresh_entry_event_queue_from_persistence ~base_path name new_entry;
        Ok new_entry)
      else loop ()
  in
  loop ()
;;

let unregister ~base_path name =
  Log.Keeper.info "registry: unregistering keeper name=%s base_path=%s" name base_path;
  let key = registry_key ~base_path name in
  let rec loop () =
    let current = Atomic.get registry in
    let before = StringMap.find_opt key current in
    let updated = StringMap.remove key current in
    if not (Atomic.compare_and_set registry current updated) then loop () else before
  in
  let signal_fibers_to_stop entry =
(* The watchdog and heartbeat fibers hold their own reference to [entry] via the closure they were forked with, so removing the entry from the registry map does not stop them. Without an explicit fibe... *)
    Atomic.set entry.fiber_stop true;
    Atomic.set entry.fiber_wakeup true
  in
  match loop () with
  | Some entry when entry.phase = Running ->
    signal_fibers_to_stop entry;
    decr_running_count_clamped ();
    Log.Keeper.debug
      "registry: unregistered running keeper name=%s running_count=%d"
      name
      (Atomic.get running_count_atomic)
  | Some entry ->
    signal_fibers_to_stop entry;
    Log.Keeper.debug
      "registry: unregistered non-running keeper name=%s state=%s"
      name
      (Keeper_state_machine.phase_to_string entry.phase)
  | None ->
    Log.Keeper.warn "registry: attempted to unregister non-existent keeper name=%s" name
;;

let get ~base_path name =
  let result = StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) in
  (match result with
   | None -> Log.Keeper.debug "registry: lookup miss name=%s base_path=%s" name base_path
   | Some _ -> ());
  result
;;

let all ?base_path () =
  StringMap.fold
    (fun _k v acc ->
       match base_path with
       | Some expected when not (String.equal expected v.base_path) -> acc
       | _ -> v :: acc)
    (Atomic.get registry)
    []
;;

let update_meta ~base_path name meta =
  update_entry ~base_path name (fun e -> { e with meta })
;;

(* Runtime-attempt cluster (runtime_attempt_merge / meta_for_runtime_attempt / record_runtime_attempt / runtime_attempt_suffix / last_runtime_attempt / runtime_attempt_freshness_threshold_sec / enrich... *)

let sync_meta_if_registered ~base_path name meta =
  let key = registry_key ~base_path name in
  let rec loop () =
    let current = Atomic.get registry in
    match StringMap.find_opt key current with
    | None -> ()
    | Some entry ->
      let updated = StringMap.add key { entry with meta } current in
      if not (Atomic.compare_and_set registry current updated) then loop ()
  in
  loop ()
;;

let () =
  register_runtime_meta_write_sync (fun config meta ->
    sync_meta_if_registered ~base_path:config.base_path meta.name meta)
;;

let mark_dead ~base_path name ~at =
  Error_tracking.mark_dead
    ~base_path
    name
    ~at
    ~decr_running_count_clamped
    ~update_entry
;;

let record_restart ~base_path name =
  Error_tracking.record_restart ~base_path name ~update_entry
;;

let set_last_error_entry ~base_path ~name err =
  Error_tracking.set_last_error_entry ~base_path ~name err ~update_entry
;;

(* record_error (MASC/OAS Error-Warn Reduction Goal §P6 dedup logic) moved to Keeper_registry_error_recording. No alias here — it would create a cycle via [Keeper_registry.set_last_error_entry], so ca... *)

let clear_error ~base_path name =
  Error_tracking.clear_error ~base_path name ~update_entry
;;

let set_failure_reason ~base_path name reason =
  Error_tracking.set_failure_reason ~base_path name reason ~update_entry
;;

let set_last_correlation_id ~base_path name cid =
  Error_tracking.set_last_correlation_id ~base_path name cid ~update_entry
;;

(* SSE broadcast helpers (broadcast_composite_changed / record_phase_broadcast_failure) moved to Keeper_registry_broadcast. *)
let broadcast_composite_changed = Keeper_registry_broadcast.composite_changed
let record_phase_broadcast_failure = Keeper_registry_broadcast.record_phase_failure

let update_current_turn e f =
  let current_turn_observation =
    match e.current_turn_observation with
    | None -> None
    | Some obs -> Some (f obs)
  in
  { e with current_turn_observation }
;;

let stamp_turn_progress ~now ~event_kind obs =
  { obs with
    last_progress_at = now
  ; last_progress_kind = Some event_kind
  }
;;

let mark_turn_started ~base_path name =
  let changed = ref false in
  let now = Time_compat.now () in
  update_entry_if_registered ~base_path name (fun e ->
    let turn_id = e.meta.runtime.usage.total_turns + 1 in
    let obs =
      { turn_id
      ; started_at = now
      ; last_progress_at = now
      ; last_progress_kind = Some "turn_started"
      ; turn_phase = Packed Turn_prompting
      ; decision_stage = Packed Decision_undecided
      ; measurement = None
      ; measurement_bind_count = 0
      ; selected_model = None
      }
    in
    changed := true;
    { e with
      current_turn_observation = Some obs
    ; compaction_stage = Packed Compaction_accumulating
    });
  if !changed then broadcast_composite_changed ~name ~ts_unix:now
;;

let record_turn_progress ~base_path name ~event_kind =
  let now = Time_compat.now () in
  update_entry_if_registered ~base_path name (fun e ->
    update_current_turn e (stamp_turn_progress ~now ~event_kind))
;;

(* RFC-0045: SDK-turn boundary reset.  Resets in-turn FSM fields without touching keeper-turn-scoped data ([turn_id], [started_at], [selected_model], [measurement], [measurement_bind_count]).  Bypasse... *)
let mark_sdk_turn_started ~base_path name =
  let changed = ref false in
  let now = Time_compat.now () in
  update_entry_if_registered ~base_path name (fun e ->
    match e.current_turn_observation with
    | None -> e
    | Some obs ->
      if
        obs.turn_phase = Packed Turn_prompting
        && obs.decision_stage = Packed Decision_undecided
      then e
      else (
        changed := true;
        let new_obs =
          { (stamp_turn_progress ~now ~event_kind:"sdk_turn_started" obs) with
            turn_phase = Packed Turn_prompting
          ; decision_stage = Packed Decision_undecided
          }
        in
        { e with current_turn_observation = Some new_obs }));
  if !changed then broadcast_composite_changed ~name ~ts_unix:now
;;

let mark_turn_measurement ~base_path name =
  let changed = ref false in
  let now = Time_compat.now () in
  update_entry_if_registered ~base_path name (fun e ->
    match e.current_turn_observation, e.pending_turn_measurement with
    | Some obs, Some measurement ->
      changed := true;
      { e with
        current_turn_observation =
          Some
            { obs with
              measurement = Some measurement
            ; measurement_bind_count = obs.measurement_bind_count + 1
            ; last_progress_at = now
            ; last_progress_kind = Some "turn_measurement"
            }
      ; pending_turn_measurement = None
      }
    | _ -> e);
  if !changed then broadcast_composite_changed ~name ~ts_unix:now
;;

(* FSM transition validators moved to Keeper_registry_fsm_validators. *)
let validate_turn_phase_transition = Keeper_registry_fsm_validators.turn_phase_transition

let set_turn_decision_stage ~base_path name (decision_stage : decision_stage_active) =
(* Spec invariant: the 3 [<active>_to_undecided] transitions are forbidden within a turn.  Previously enforced at runtime via [invalid_arg] inside a 16-pair match; now unrepresentable through the [dec... *)
  let target_packed = decision_stage_active_to_packed decision_stage in
  let changed = ref false in
  let now = Time_compat.now () in
  update_entry_if_registered ~base_path name (fun e ->
    update_current_turn e (fun obs ->
      if obs.decision_stage = target_packed
      then obs
      else (
        changed := true;
        { (stamp_turn_progress ~now ~event_kind:"decision_stage" obs) with
          decision_stage = target_packed
        })));
  if !changed then broadcast_composite_changed ~name ~ts_unix:now
;;

let set_turn_phase_direct ~base_path name ~event_kind (turn_phase : packed_turn_phase) =
  let changed = ref false in
  let now = Time_compat.now () in
  update_entry_if_registered ~base_path name (fun e ->
    update_current_turn e (fun obs ->
      match resolve_turn_phase_transition ~from:obs.turn_phase ~target:turn_phase with
      | Resolved_turn_idempotent -> obs
      | Resolved_turn_transition _ ->
        changed := true;
        { (stamp_turn_progress ~now ~event_kind obs) with
          turn_phase
        }
      | Resolved_turn_violation violation ->
        Keeper_fsm_guard_runtime.wrap_unit
          ~action:"turn_phase_transition"
          ~stage:"guard"
          (fun () ->
             raise_turn_phase_transition_violation
               ~where:event_kind
               ~from:obs.turn_phase
               ~to_:turn_phase
               ~violation);
        obs));
  if !changed then broadcast_composite_changed ~name ~ts_unix:now
;;

let set_turn_phase_with ~base_path name ~event_kind ~target ~update_obs =
  (* RFC-0072 Phase 4b + Phase 5 variant: resolve the turn_phase transition
     and let the caller apply additional observation mutations atomically in
     the same CAS.  This keeps multi-field setters (gate rejection,
     compaction retry) on the same resolver / guard / broadcast pathway as
     [set_turn_phase] instead of calling the legacy
     [validate_turn_phase_transition] directly.  Idempotent self-loops are
     no-ops and do not emit a broadcast, matching [set_turn_phase].  The
     [event_kind] label is forwarded to [raise_turn_phase_transition_violation]
     via [wrap_unit] so guard metrics name the actual caller. *)
  let changed = ref false in
  let now = Time_compat.now () in
  update_entry_if_registered ~base_path name (fun e ->
    update_current_turn e (fun obs ->
      match resolve_turn_phase_transition ~from:obs.turn_phase ~target with
      | Resolved_turn_idempotent -> obs
      | Resolved_turn_transition _ ->
        changed := true;
        let obs' =
          { (stamp_turn_progress ~now ~event_kind obs) with turn_phase = target }
        in
        update_obs obs'
      | Resolved_turn_violation violation ->
        Keeper_fsm_guard_runtime.wrap_unit
          ~action:"turn_phase_transition"
          ~stage:"guard"
          (fun () ->
             raise_turn_phase_transition_violation
               ~where:event_kind
               ~from:obs.turn_phase
               ~to_:target
               ~violation);
        obs));
  if !changed then broadcast_composite_changed ~name ~ts_unix:now
;;

let mark_turn_runtime_exhausted ~base_path name =
  set_turn_decision_stage ~base_path name Decision_active_tool_policy_selected;
  set_turn_phase_direct
    ~base_path
    name
    ~event_kind:"runtime_exhausted"
    (Packed Turn_exhausted)
;;

let mark_turn_runtime_done ~base_path name =
  set_turn_decision_stage ~base_path name Decision_active_tool_policy_selected;
  set_turn_phase_direct
    ~base_path
    name
    ~event_kind:"runtime_done"
    (Packed Turn_finalizing)
;;
