(** Keeper_registry — SSOT for keeper state. Atomic.t + persistent StringMap; no mutex needed in single-domain Eio. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
open Keeper_id

(** Failure-reason cluster re-included from Keeper_registry_types for backward compatibility. *)
include Keeper_registry_types

let registry : registry_entry StringMap.t Atomic.t = Atomic.make StringMap.empty
let running_count_atomic = Atomic.make 0
module Orphan_drops = Keeper_registry_orphan_drops
module Spawn_slots = Keeper_registry_spawn_slots
module Error_tracking = Keeper_registry_error_tracking

let registry_entry_validation_error_label = function
  | Healthy -> "healthy"
  | Meta_validation_failed _ -> "meta_validation_failed"
  | Required_field_missing _ -> "required_field_missing"
  | Base_path_mismatch _ -> "base_path_mismatch"
  | Name_mismatch _ -> "name_mismatch"
;;

let registry_entry_validation_error_to_string = function
  | Healthy -> "registry entry is healthy"
  | Meta_validation_failed { reason } ->
      Printf.sprintf "registry entry meta validation failed: %s" reason
  | Required_field_missing { field } ->
      Printf.sprintf "registry entry required field missing: %s" field
  | Base_path_mismatch { expected; actual } ->
      Printf.sprintf
        "registry entry base_path mismatch: expected %S, got %S"
        expected
        actual
  | Name_mismatch { expected; actual } ->
      Printf.sprintf
        "registry entry name mismatch: expected %S, got %S"
        expected
        actual
;;

let registry_key_parts = Keeper_registry_types.registry_key_parts

let has_blank_tool_name names =
  List.exists (fun name -> String.equal (String.trim name) "") names
;;

let has_duplicate_tool_name names =
  let rec loop seen = function
    | [] -> false
    | name :: rest ->
      let trimmed = String.trim name in
      if String.equal trimmed ""
      then loop seen rest
      else if Set_util.StringSet.mem trimmed seen
      then true
      else loop (Set_util.StringSet.add trimmed seen) rest
  in
  loop Set_util.StringSet.empty names
;;

let validate_tool_name_list field names =
  if has_blank_tool_name names
  then Error (Meta_validation_failed { reason = field ^ " contains blank entries" })
  else if has_duplicate_tool_name names
  then Error (Meta_validation_failed { reason = field ^ " contains duplicate entries" })
  else Ok ()
;;

let validate_runtime_fields (runtime : agent_runtime_state) =
  if String.equal (Trace_id.to_string runtime.trace_id) ""
  then Error (Required_field_missing { field = "trace_id" })
  else if runtime.generation < 0
  then Error (Required_field_missing { field = "generation" })
  else if runtime.usage.total_turns < 0
  then Error (Required_field_missing { field = "usage.total_turns" })
  else if runtime.usage.total_tokens < 0
  then Error (Required_field_missing { field = "usage.total_tokens" })
  else validate_tool_name_list "trace_history" runtime.trace_history
;;

let validate_registry_entry ~base_path name (entry : registry_entry) =
  let expected_name = String.trim name in
  if not (String.equal entry.base_path base_path)
  then Error (Base_path_mismatch { expected = base_path; actual = entry.base_path })
  else if not (String.equal entry.name expected_name)
  then Error (Name_mismatch { expected = expected_name; actual = entry.name })
  else if not (String.equal (String.trim entry.meta.name) expected_name)
  then Error (Name_mismatch { expected = expected_name; actual = entry.meta.name })
  else if String.equal (String.trim entry.meta.agent_name) ""
  then Error (Meta_validation_failed { reason = "meta.agent_name is empty" })
  else
    match validate_runtime_fields entry.meta.runtime with
    | Error _ as err -> err
    | Ok () ->
      (match validate_tool_name_list "tool_access" entry.meta.tool_access with
       | Error _ as err -> err
       | Ok () -> validate_tool_name_list "tool_denylist" entry.meta.tool_denylist)
;;

let validate_registry_meta ~base_path:_ name (meta : keeper_meta) =
  let expected_name = String.trim name in
  if not (String.equal (String.trim meta.name) expected_name)
  then Error (Name_mismatch { expected = expected_name; actual = meta.name })
  else if String.equal (String.trim meta.agent_name) ""
  then Error (Meta_validation_failed { reason = "meta.agent_name is empty" })
  else Ok ()
;;

let record_invalid_registry_entry ~operation ~name reason =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string RegistryInvalidEntry)
    ~labels:
      [ "operation", operation
      ; "name", name
      ; "reason", registry_entry_validation_error_label reason
      ]
    ();
  Log.Keeper.warn
    "registry: invalid entry operation=%s name=%s reason=%s"
    operation
    name
    (registry_entry_validation_error_to_string reason)

let canonicalize_registry_meta ~operation ~base_path name (meta : keeper_meta) =
  match validate_registry_meta ~base_path name meta with
  | Ok () -> meta
  | Error ((Name_mismatch _ | Meta_validation_failed _) as reason) ->
      let expected_name = String.trim name in
      let expected_agent_name = Keeper_identity.keeper_agent_name expected_name in
      let repaired =
        { meta with
          name = expected_name
        ; agent_name =
            (if String.equal (String.trim meta.agent_name) ""
             then expected_agent_name
             else meta.agent_name)
        }
      in
      record_invalid_registry_entry ~operation ~name reason;
      (match validate_registry_meta ~base_path name repaired with
       | Ok () -> repaired
       | Error repair_reason ->
           record_invalid_registry_entry ~operation ~name repair_reason;
           meta)
  | Error reason ->
      record_invalid_registry_entry ~operation ~name reason;
      meta
;;

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

let put_entry ~base_path name entry =
  match validate_registry_entry ~base_path name entry with
  | Error err ->
    record_invalid_registry_entry ~operation:"put" ~name err;
    Error err
  | Ok () ->
    let key = registry_key ~base_path name in
    let rec loop () =
      let current = Atomic.get registry in
      let updated = StringMap.add key entry current in
      if Atomic.compare_and_set registry current updated then Ok () else loop ()
    in
    loop ()
;;

(** Test-only bypass: install an entry without validation so tests can seed
    corrupted registry state for [get] / [get_with_health] hardening checks. *)
let unsafe_put_entry ~base_path name entry =
  let key = registry_key ~base_path name in
  let rec loop () =
    let current = Atomic.get registry in
    let updated = StringMap.add key entry current in
    if Atomic.compare_and_set registry current updated then () else loop ()
  in
  loop ()
;;

(** Apply [f entry] and write back.  No-op if key absent.  Validates the
    result of [f entry] before installing; on validation error returns the
    health reason, emits [RegistryInvalidEntry] with [operation="update"], and
    leaves the original entry untouched.  Only CAS conflicts retry. *)
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
          count;
      Ok ()
    | Some entry ->
      let new_entry = f entry in
      (match validate_registry_entry ~base_path name new_entry with
       | Error err ->
         record_invalid_registry_entry ~operation:"update" ~name err;
         Error err
       | Ok () ->
         let updated = StringMap.add key new_entry current in
         if Atomic.compare_and_set registry current updated
         then (
           Orphan_drops.clear ~base_path name;
           Ok ())
         else loop ())
  in
  loop ()
;;

let update_entry_unit ~base_path name f =
  (* fire-and-forget: unit wrapper discards Ok/Error; callers only need side effects and logged metrics. *)
  ignore (update_entry ~base_path name f)
;;

let update_entry_if_registered ~base_path name f =
  let key = registry_key ~base_path name in
  let rec loop () =
    let current = Atomic.get registry in
    match StringMap.find_opt key current with
    | None -> false
    | Some entry ->
      let new_entry, changed = f entry in
      if not changed
      then false
      else
        match validate_registry_entry ~base_path name new_entry with
        | Error err ->
          record_invalid_registry_entry ~operation:"update" ~name err;
          false
        | Ok () ->
          let updated = StringMap.add key new_entry current in
          if Atomic.compare_and_set registry current updated
          then (
            Orphan_drops.clear ~base_path name;
            true)
          else loop ()
  in
  loop ()
;;

let update_entry_if_registered_unit ~base_path name f =
  (* fire-and-forget: discard whether the validated registry write was installed. *)
  ignore (update_entry_if_registered ~base_path name (fun entry -> f entry, true))
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
  let meta = canonicalize_registry_meta ~operation:"register" ~base_path name meta in
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
    ; current_turn_switch = Atomic.make None
    ; board_wakeups = StringMap.empty
    ; board_cursor_ts = 0.0
    ; board_cursor_post_id = None
    ; tool_usage = StringMap.empty
    ; transition_seq = 0
    ; waiting_for_inference = Atomic.make false
    ; last_context_actions = None
    ; last_event_bus_correlation = None
    ; pending_turn_measurement = None
    ; current_turn_observation = None
    ; last_completed_turn = None
    ; last_skip_observation = None
    ; compaction_stage = Packed Compaction_accumulating
    }
  in
  (* fire-and-forget: put_entry validates and logs on failure; the constructed entry is always used. *)
  ignore (put_entry ~base_path name entry);
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
  let meta =
    canonicalize_registry_meta ~operation:"register_restarting" ~base_path name meta
  in
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
    ; current_turn_switch = Atomic.make None
    ; board_wakeups = StringMap.empty
    ; board_cursor_ts = 0.0
    ; board_cursor_post_id = None
    ; tool_usage = StringMap.empty
    ; transition_seq = 0
    ; waiting_for_inference = Atomic.make false
    ; last_context_actions = None
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

let health_of_entry ~base_path name entry =
  match validate_registry_entry ~base_path name entry with
  | Ok () -> Healthy
  | Error health -> health
;;

let get_with_health ~base_path name =
  match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
  | None ->
      Log.Keeper.debug "registry: lookup miss name=%s base_path=%s" name base_path;
      None
  | Some entry -> Some (entry, health_of_entry ~base_path name entry)
;;

let get ~base_path name =
  match get_with_health ~base_path name with
  | None -> None
  | Some (entry, Healthy) -> Some entry
  | Some (_, reason) ->
      record_invalid_registry_entry ~operation:"get" ~name reason;
      None
;;

let all ?base_path () =
  StringMap.fold
    (fun key v acc ->
       match registry_key_parts key with
       | Error reason ->
           record_invalid_registry_entry
             ~operation:"all"
             ~name:v.name
             (Meta_validation_failed { reason });
           acc
       | Ok (key_base_path, key_name) ->
           (match base_path with
            | Some expected when not (String.equal expected key_base_path) -> acc
            | Some _ | None -> (
                match validate_registry_entry ~base_path:key_base_path key_name v with
                | Ok () -> v :: acc
                | Error reason ->
                    record_invalid_registry_entry ~operation:"all" ~name:key_name reason;
                    acc)))
    (Atomic.get registry)
    []
;;

let update_meta ~base_path name meta =
  match validate_registry_meta ~base_path name meta with
  | Error reason ->
      record_invalid_registry_entry ~operation:"update_meta" ~name reason
  | Ok () ->
      update_entry_unit ~base_path name (fun e -> { e with base_path; name; meta })
;;

let reload_meta_from_disk ~base_path name =
  let config = Workspace.default_config base_path in
  match read_meta config name with
  | Error msg -> Error msg
  | Ok None -> Ok None
  | Ok (Some meta) -> (
      let meta =
        canonicalize_registry_meta ~operation:"reload_meta_from_disk" ~base_path name meta
      in
      let defaults = load_keeper_profile_defaults_for_base_path ~base_path name in
      match effective_meta_of_profile_defaults defaults meta with
      | Error msg -> Error msg
      | Ok effective_meta -> (
          match validate_registry_meta ~base_path name effective_meta with
          | Error reason ->
              record_invalid_registry_entry ~operation:"reload_meta_from_disk" ~name reason;
              Error (registry_entry_validation_error_to_string reason)
          | Ok () ->
              let updated =
                update_entry_if_registered ~base_path name (fun e ->
                  { e with base_path; name; meta = effective_meta }, true)
              in
              if updated then Ok (get ~base_path name) else Ok None))
;;

(* Runtime-attempt cluster (runtime_attempt_merge / meta_for_runtime_attempt / record_runtime_attempt / runtime_attempt_suffix / last_runtime_attempt / runtime_attempt_freshness_threshold_sec / enrich... *)

let sync_meta_if_registered ~base_path name meta =
  match validate_registry_meta ~base_path name meta with
  | Error reason ->
      record_invalid_registry_entry ~operation:"sync_meta_if_registered" ~name reason
  | Ok () ->
      let key = registry_key ~base_path name in
      let rec loop () =
        let current = Atomic.get registry in
        match StringMap.find_opt key current with
        | None -> ()
        | Some entry ->
            let updated =
              StringMap.add key { entry with base_path; name; meta } current
            in
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
    ~update_entry:update_entry_unit
;;

let record_restart ~base_path name =
  Error_tracking.record_restart ~base_path name ~update_entry:update_entry_unit
;;

let set_last_error_entry ~base_path ~name err =
  Error_tracking.set_last_error_entry ~base_path ~name err ~update_entry:update_entry_unit
;;

(* record_error (MASC/OAS Error-Warn Reduction Goal §P6 dedup logic) moved to Keeper_registry_error_recording. No alias here — it would create a cycle via [Keeper_registry.set_last_error_entry], so ca... *)

let clear_error ~base_path name =
  Error_tracking.clear_error ~base_path name ~update_entry:update_entry_unit
;;

let set_failure_reason ~base_path name reason =
  Error_tracking.set_failure_reason ~base_path name reason ~update_entry:update_entry_unit
;;

let set_last_correlation_id ~base_path name cid =
  Error_tracking.set_last_correlation_id ~base_path name cid ~update_entry:update_entry_unit
;;

(* SSE broadcast helpers (broadcast_composite_changed / record_phase_broadcast_failure) moved to Keeper_registry_broadcast. *)
let broadcast_composite_changed = Keeper_registry_broadcast.composite_changed
let record_phase_broadcast_failure = Keeper_registry_broadcast.record_phase_failure

let update_current_turn e f =
  match e.current_turn_observation with
  | None -> e, false
  | Some obs ->
    let obs' = f obs in
    if obs == obs' then e, false else { e with current_turn_observation = Some obs' }, true
;;

let stamp_turn_progress ~now ~event_kind obs =
  { obs with
    last_progress_at = now
  ; last_progress_kind = Some event_kind
  }
;;

let mark_turn_started ~base_path ~wake name =
  let now = Time_compat.now () in
  let changed =
    update_entry_if_registered ~base_path name (fun e ->
      let turn_id = e.meta.runtime.usage.total_turns + 1 in
      let obs =
        { turn_id
        ; started_at = now
        ; last_progress_at = now
        ; last_progress_kind = Some "turn_started"
        ; active_tool_count = 0
        ; turn_phase = Packed Turn_prompting
        ; decision_stage = Packed Decision_undecided
        ; measurement = None
        ; measurement_bind_count = 0
        ; selected_model = None
        ; wake
        }
      in
      { e with
        current_turn_observation = Some obs
      ; compaction_stage = Packed Compaction_accumulating
      }, true)
  in
  if changed then broadcast_composite_changed ~name ~ts_unix:now
;;

let record_turn_progress ~base_path name ~event_kind =
  let now = Time_compat.now () in
  let (_ : bool) =
    update_entry_if_registered ~base_path name (fun e ->
      update_current_turn e (stamp_turn_progress ~now ~event_kind))
  in
  ()
;;

(* RFC-0197 (P1-4a): write-through mirror of the turn event bus
   [pending_tool_count] into the live [turn_observation]. The supervisor sweep
   only reads [current_turn_observation] (the event bus is a per-turn call-stack
   value, not globally reachable), so the tool-in-flight count is surfaced here
   for [Keeper_supervisor.assess_in_turn_progress] to exclude active tool work
   from the no-progress window. Does not touch [last_progress_at]: a tool
   running silently is "active tool execution", not progress. A [None]
   [current_turn_observation] (turn already ended) is a no-op, so a late
   background-drain callback after [mark_turn_finished] cannot leak. *)
let record_turn_tool_inflight ~base_path name ~count =
  let (_ : bool) =
    update_entry_if_registered ~base_path name (fun e ->
      update_current_turn e (fun obs -> { obs with active_tool_count = count }))
  in
  ()
;;

(* RFC-0045: SDK-turn boundary reset.  Resets in-turn FSM fields without touching keeper-turn-scoped data ([turn_id], [started_at], [selected_model], [measurement], [measurement_bind_count]).  Bypasse... *)
let mark_sdk_turn_started ~base_path name =
  let now = Time_compat.now () in
  let changed =
    update_entry_if_registered ~base_path name (fun e ->
      match e.current_turn_observation with
      | None -> e, false
      | Some obs ->
        if
          obs.turn_phase = Packed Turn_prompting
          && obs.decision_stage = Packed Decision_undecided
        then e, false
        else (
          let new_obs =
            { (stamp_turn_progress ~now ~event_kind:"sdk_turn_started" obs) with
              turn_phase = Packed Turn_prompting
            ; decision_stage = Packed Decision_undecided
            }
          in
          { e with current_turn_observation = Some new_obs }, true))
  in
  if changed then broadcast_composite_changed ~name ~ts_unix:now
;;

let mark_turn_measurement ~base_path name =
  let now = Time_compat.now () in
  let changed =
    update_entry_if_registered ~base_path name (fun e ->
      match e.current_turn_observation, e.pending_turn_measurement with
      | Some obs, Some measurement ->
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
        }, true
      | _ -> e, false)
  in
  if changed then broadcast_composite_changed ~name ~ts_unix:now
;;

(* FSM transition validators moved to Keeper_registry_fsm_validators. *)
let validate_turn_phase_transition = Keeper_registry_fsm_validators.turn_phase_transition

let set_turn_decision_stage ~base_path name (decision_stage : decision_stage_active) =
(* Spec invariant: the 3 [<active>_to_undecided] transitions are forbidden within a turn.  Previously enforced at runtime via [invalid_arg] inside a 16-pair match; now unrepresentable through the [dec... *)
  let target_packed = decision_stage_active_to_packed decision_stage in
  let now = Time_compat.now () in
  let changed =
    update_entry_if_registered ~base_path name (fun e ->
      update_current_turn e (fun obs ->
        if obs.decision_stage = target_packed
        then obs
        else (
          { (stamp_turn_progress ~now ~event_kind:"decision_stage" obs) with
            decision_stage = target_packed
          })))
  in
  if changed then broadcast_composite_changed ~name ~ts_unix:now
;;

let set_turn_phase_direct ~base_path name ~event_kind (turn_phase : packed_turn_phase) =
  let now = Time_compat.now () in
  let changed =
    update_entry_if_registered ~base_path name (fun e ->
      let e', changed =
        update_current_turn e (fun obs ->
          match resolve_turn_phase_transition ~from:obs.turn_phase ~target:turn_phase with
          | Resolved_turn_idempotent -> obs
          | Resolved_turn_transition _ ->
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
            obs)
      in
      e', changed)
  in
  if changed then broadcast_composite_changed ~name ~ts_unix:now
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
  let now = Time_compat.now () in
  let changed =
    update_entry_if_registered ~base_path name (fun e ->
      let e', changed =
        update_current_turn e (fun obs ->
          match resolve_turn_phase_transition ~from:obs.turn_phase ~target with
          | Resolved_turn_idempotent -> obs
          | Resolved_turn_transition _ ->
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
            obs)
      in
      e', changed)
  in
  if changed then broadcast_composite_changed ~name ~ts_unix:now
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

let set_turn_switch ~base_path name sw_opt =
  match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
  | Some entry -> Atomic.set entry.current_turn_switch sw_opt
  | None -> ()
;;

let clear_turn_switch ~base_path name =
  set_turn_switch ~base_path name None
;;

let interrupt_current_turn ~base_path name =
  match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
  | None -> `No_turn_in_flight
  | Some entry ->
    (match entry.current_turn_observation with
     | None -> `No_turn_in_flight
     | Some obs ->
       match Atomic.exchange entry.current_turn_switch None with
       | None -> `No_turn_in_flight
       | Some sw ->
         (try Eio.Switch.fail sw Operator_interrupt with
          | Invalid_argument _ -> ());
         `Cancelled obs.turn_id)
;;
