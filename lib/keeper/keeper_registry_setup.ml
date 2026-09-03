(** Keeper_registry — SSOT for keeper state. Atomic.t + persistent StringMap; no mutex needed in single-domain Eio. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
open Keeper_id
open Keeper_registry_types

let registry : registry_entry StringMap.t Atomic.t = Atomic.make StringMap.empty
let running_count_atomic = Atomic.make 0
module Orphan_drops = Keeper_registry_orphan_drops
module Error_tracking = Keeper_registry_error_tracking
module Turn_failure_streak_store = Keeper_turn_failure_streak_store

let registry_entry_validation_error_label = function
  | Healthy -> "healthy"
  | Lifecycle_transaction_reserved _ -> "lifecycle_transaction_reserved"
  | Meta_validation_failed _ -> "meta_validation_failed"
  | Required_field_missing _ -> "required_field_missing"
  | Base_path_mismatch _ -> "base_path_mismatch"
  | Name_mismatch _ -> "name_mismatch"
;;

let registry_entry_validation_error_to_string = function
  | Healthy -> "registry entry is healthy"
  | Lifecycle_transaction_reserved owner ->
    Printf.sprintf
      "registry mutation reserved by lifecycle transaction owner=%s"
      owner.owner_id
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

let has_blank_string names =
  List.exists (fun name -> String.equal (String.trim name) "") names
;;

let has_duplicate_string names =
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

let validate_string_list field names =
  if has_blank_string names
  then Error (Meta_validation_failed { reason = field ^ " contains blank entries" })
  else if has_duplicate_string names
  then Error (Meta_validation_failed { reason = field ^ " contains duplicate entries" })
  else Ok ()
;;

let validate_runtime_fields (runtime : agent_runtime_state) =
  if String.equal (Trace_id.to_string runtime.trace_id) ""
  then Error (Required_field_missing { field = "trace_id" })
  else if runtime.usage.total_turns < 0
  then Error (Required_field_missing { field = "usage.total_turns" })
  else if runtime.usage.total_tokens < 0
  then Error (Required_field_missing { field = "usage.total_tokens" })
  else validate_string_list "trace_history" runtime.trace_history
;;

let validate_registry_entry ~base_path name (entry : registry_entry) =
  let base_path = canonical_base_path_exn base_path in
  let expected_name = String.trim name in
  if not (String.equal entry.base_path base_path)
  then Error (Base_path_mismatch { expected = base_path; actual = entry.base_path })
  else if not (String.equal entry.name expected_name)
  then Error (Name_mismatch { expected = expected_name; actual = entry.name })
  else if not (String.equal (String.trim entry.meta.name) expected_name)
  then Error (Name_mismatch { expected = expected_name; actual = entry.meta.name })
  else
    validate_runtime_fields entry.meta.runtime
;;

let validate_registry_meta ~base_path:_ name (meta : keeper_meta) =
  let expected_name = String.trim name in
  if not (String.equal (String.trim meta.name) expected_name)
  then Error (Name_mismatch { expected = expected_name; actual = meta.name })
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
  | Error
      ((Name_mismatch _ | Meta_validation_failed _) as reason) ->
      let expected_name = String.trim name in
      let repaired = { meta with name = expected_name } in
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

(* Precondition: the caller already holds the per-keeper lifecycle key lock.
   Every step below is non-suspending: [authorize] is an [Atomic.get] on the
   process-local reservation table (NOT [Keeper_lifecycle_reservation.acquire],
   which takes the key lock and would suspend — the two differ by exactly that,
   and the whole argument here rests on it), [validate_registry_entry] is pure,
   the metric store and [Log] use stdlib I/O rather than Eio flows, and the
   install is a CAS loop.
   That totality is what makes this body legal to run inside
   [Keeper_shutdown_intake_fence.commit_registration_if_open], whose critical section
   is guarded by a scheduler-blocking [Stdlib.Mutex]: a fiber that suspends
   there can never be resumed, because [Stdlib.Mutex.lock] blocks the very OS
   thread that runs the Eio scheduler. Acquiring the key lock here instead
   would reintroduce that suspension. *)
let put_entry_key_locked ?lifecycle_token ~base_path name entry =
  match
    Keeper_lifecycle_reservation.authorize
      ?token:lifecycle_token
      ~base_path
      ~keeper_name:name
      ()
  with
  | Error owner -> Error (Lifecycle_transaction_reserved owner)
  | Ok () ->
    (match validate_registry_entry ~base_path name entry with
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
       loop ())
;;

let put_entry_internal ?lifecycle_token ~base_path name entry =
  Keeper_lifecycle_reservation.with_key_lock ~base_path ~keeper_name:name (fun () ->
    put_entry_key_locked ?lifecycle_token ~base_path name entry)
;;

let put_entry ~base_path name entry = put_entry_internal ~base_path name entry

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
let update_entry_internal ?lifecycle_token ~base_path name f =
  Keeper_lifecycle_reservation.with_key_lock ~base_path ~keeper_name:name (fun () ->
  match
    Keeper_lifecycle_reservation.authorize
      ?token:lifecycle_token
      ~base_path
      ~keeper_name:name
      ()
  with
  | Error owner -> Error (Lifecycle_transaction_reserved owner)
  | Ok () ->
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
  loop ())
;;

let update_entry ~base_path name f = update_entry_internal ~base_path name f

type exact_update_result =
  | Exact_updated
  | Exact_update_missing
  | Exact_update_replaced
  | Exact_update_invalid of registry_entry_validation_error

let update_entry_exact_internal ?lifecycle_token (expected : registry_entry) f =
  let base_path = expected.base_path in
  let name = expected.name in
  Keeper_lifecycle_reservation.with_key_lock ~base_path ~keeper_name:name (fun () ->
  match
    Keeper_lifecycle_reservation.authorize
      ?token:lifecycle_token
      ~base_path
      ~keeper_name:name
      ()
  with
  | Error owner -> Exact_update_invalid (Lifecycle_transaction_reserved owner)
  | Ok () ->
  let key = registry_key ~base_path name in
  let expected_lane = Keeper_lane.id expected.lane in
  let rec loop () =
    let current = Atomic.get registry in
    match StringMap.find_opt key current with
    | None -> Exact_update_missing
    | Some entry
      when not (Keeper_lane.Id.equal expected_lane (Keeper_lane.id entry.lane)) ->
      Exact_update_replaced
    | Some entry ->
      let new_entry = f entry in
      (match validate_registry_entry ~base_path name new_entry with
       | Error err ->
         record_invalid_registry_entry ~operation:"update_exact" ~name err;
         Exact_update_invalid err
       | Ok () ->
         let updated = StringMap.add key new_entry current in
         if Atomic.compare_and_set registry current updated
         then (
           Orphan_drops.clear ~base_path name;
           Exact_updated)
         else loop ())
  in
  loop ())
;;

let update_entry_exact expected f = update_entry_exact_internal expected f

let update_entry_exact_for_lifecycle token expected f =
  update_entry_exact_internal ~lifecycle_token:token expected f
;;

type install_entry_result =
  | Entry_installed
  | Entry_install_conflict
  | Entry_install_missing
  | Entry_install_replaced
  | Entry_install_invalid of registry_entry_validation_error

let install_entry_if_current_internal
      ?lifecycle_token
      ~(observed : registry_entry)
      (replacement : registry_entry)
  =
  let base_path = observed.base_path in
  let name = observed.name in
  Keeper_lifecycle_reservation.with_key_lock ~base_path ~keeper_name:name (fun () ->
  match
    Keeper_lifecycle_reservation.authorize
      ?token:lifecycle_token
      ~base_path
      ~keeper_name:name
      ()
  with
  | Error owner -> Entry_install_invalid (Lifecycle_transaction_reserved owner)
  | Ok () ->
  match validate_registry_entry ~base_path name replacement with
  | Error err ->
    record_invalid_registry_entry ~operation:"install_if_current" ~name err;
    Entry_install_invalid err
  | Ok () ->
    let current = Atomic.get registry in
    let key = registry_key ~base_path name in
    (match StringMap.find_opt key current with
     | None -> Entry_install_missing
     | Some entry
       when not
              (Keeper_lane.Id.equal
                 (Keeper_lane.id observed.lane)
                 (Keeper_lane.id entry.lane)) ->
       Entry_install_replaced
     | Some entry when entry != observed -> Entry_install_conflict
     | Some _ ->
       let updated = StringMap.add key replacement current in
       if Atomic.compare_and_set registry current updated
       then Entry_installed
       else Entry_install_conflict))
;;

let install_entry_if_current ~observed replacement =
  install_entry_if_current_internal ~observed replacement
;;

let update_entry_unit ~base_path name f =
  (* fire-and-forget: unit wrapper discards Ok/Error; callers only need side effects and logged metrics. *)
  ignore (update_entry ~base_path name f)
;;

let update_entry_if_registered ~base_path name f =
  Keeper_lifecycle_reservation.with_key_lock ~base_path ~keeper_name:name (fun () ->
  match
    Keeper_lifecycle_reservation.authorize ~base_path ~keeper_name:name ()
  with
  | Error owner ->
    Log.Keeper.info
      "registry: conditional update deferred to lifecycle transaction name=%s %s"
      name
      (Keeper_lifecycle_reservation.snapshot_to_string owner);
    false
  | Ok () ->
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
  loop ())
;;

type registration_error =
  | Registration_shutdown_reserved of Keeper_shutdown_types.Operation_id.t
  | Registration_intake_token_not_live
  | Registration_lifecycle_reserved of Keeper_lifecycle_reservation.snapshot
  | Registration_invalid of registry_entry_validation_error
  | Registration_event_queue_unavailable of
      { keeper_name : string
      ; detail : string
      }
  | Registration_turn_failure_streak_unavailable of
      { keeper_name : string
      ; detail : string
      }

let register_with_state_result
      ?lifecycle_token
      ?intake_token
      ~respect_shutdown_fence
      ~base_path
      name
      meta
      ~(phase : Keeper_state_machine.phase)
      ~(conditions : Keeper_state_machine.conditions)
  =
  let base_path = canonical_base_path_exn base_path in
  let meta = canonicalize_registry_meta ~operation:"register" ~base_path name meta in
  match
    Keeper_lifecycle_reservation.authorize
      ?token:lifecycle_token
      ~base_path
      ~keeper_name:name
      ()
  with
  | Error owner -> Error (Registration_lifecycle_reserved owner)
  | Ok () ->
  Log.Keeper.info
    "registry: registering keeper name=%s base_path=%s phase=%s"
    name
    base_path
    (Keeper_state_machine.phase_to_string phase);
  let done_p, done_r = Eio.Promise.create () in
  let key = registry_key ~base_path name in
  match
    Keeper_event_queue_persistence.load_pending_result
      ~base_path
      ~keeper_name:name
  with
  | Error detail -> Error (Registration_event_queue_unavailable { keeper_name = name; detail })
  | Ok initial_event_queue ->
  match Turn_failure_streak_store.load ~base_path ~keeper_name:name with
  | Error error ->
    Error
      (Registration_turn_failure_streak_unavailable
         { keeper_name = name
         ; detail = Turn_failure_streak_store.error_to_string error
         })
  | Ok persisted_turn_failure_streak ->
  let initial_turn_failure_streak =
    Option.value ~default:0 persisted_turn_failure_streak
  in
  let initial_failure_reason =
    if initial_turn_failure_streak > 0
    then Some (Turn_consecutive_failures initial_turn_failure_streak)
    else None
  in
  let entry =
    { base_path
    ; name
    ; meta
    ; phase
    ; conditions
    ; fiber_stop = Atomic.make false
    ; fiber_wakeup = Atomic.make false
    ; cadence_sleeping = Atomic.make false
    ; event_queue = Atomic.make initial_event_queue
    ; started_at = Time_compat.now ()
    ; grpc_close = Atomic.make None
    ; lane = Keeper_lane.create ()
    ; done_p
    ; done_r
    ; restart_count = 0
    ; last_restart_ts = 0.0
    ; crash_log = []
    ; last_error = None
    ; last_failure_reason = initial_failure_reason
    ; turn_consecutive_failures = initial_turn_failure_streak
    ; turn_attempt_state = Atomic.make None
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
    }
  in
  (* Runs with the lifecycle key lock already held, so it never suspends. *)
  let commit_key_locked () =
    (match StringMap.find_opt key (Atomic.get registry) with
     | Some prior when prior.phase = Running ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string LifecycleDispatchRejections)
         ~labels:[ "keeper", name; "event", "register_overwrite_running" ]
         ();
       Log.Keeper.warn "registry: overwriting running keeper during register name=%s" name;
       decr_running_count_clamped ()
     | Some _ | None -> ());
    put_entry_key_locked ?lifecycle_token ~base_path name entry
  in
  (* Ordinary registration takes the key lock before the non-yielding
     [commit_registration_if_open] state check. A caller-supplied intake token
     already owns the fiber-aware per-Keeper intake mutex, so it validates that
     exact transaction and commits without trying to reacquire the same gate.
     In both paths the registry install remains ordered with shutdown. *)
  let commit_result =
    Keeper_lifecycle_reservation.with_key_lock ~base_path ~keeper_name:name (fun () ->
      if Option.is_some intake_token
      then (
        match intake_token with
        | Some token
          when Keeper_shutdown_intake_fence.intake_token_matches
                 token
                 ~base_path
                 ~keeper_name:name ->
          (match commit_key_locked () with
           | Ok () -> Ok ()
           | Error (Lifecycle_transaction_reserved owner) ->
             Error (Registration_lifecycle_reserved owner)
           | Error validation_error -> Error (Registration_invalid validation_error))
        | Some _ | None -> Error Registration_intake_token_not_live)
      else if respect_shutdown_fence
      then (
        match
          Keeper_shutdown_intake_fence.commit_registration_if_open
            ~base_path
            ~keeper_name:name
            commit_key_locked
        with
        | Keeper_shutdown_intake_fence.Registration_shutdown_reserved operation_id ->
          (* Observed, not obeyed. The reservation records that a shutdown
             began; one that never finalises never clears it, and refusing on
             it stopped every registration for as long as the process lived —
             15h32m on 2026-08-20 (#29566). Register and name what stood. *)
          Log.Keeper.warn
            "keeper registered while a shutdown reservation stood: keeper=%s \
             operation=%s"
            name
            (Keeper_shutdown_types.Operation_id.to_string operation_id);
          (match commit_key_locked () with
           | Ok () -> Ok ()
           | Error (Lifecycle_transaction_reserved owner) ->
             Error (Registration_lifecycle_reserved owner)
           | Error validation_error -> Error (Registration_invalid validation_error))
        | Keeper_shutdown_intake_fence.Registration_committed
            (Error (Lifecycle_transaction_reserved owner)) ->
          Error (Registration_lifecycle_reserved owner)
        | Keeper_shutdown_intake_fence.Registration_committed (Error validation_error) ->
          Error (Registration_invalid validation_error)
        | Keeper_shutdown_intake_fence.Registration_committed (Ok ()) -> Ok ())
      else (
        match commit_key_locked () with
        | Ok () -> Ok ()
        | Error (Lifecycle_transaction_reserved owner) ->
          Error (Registration_lifecycle_reserved owner)
        | Error validation_error -> Error (Registration_invalid validation_error)))
  in
  match commit_result with
  | Error _ as error -> error
  | Ok () ->
    if phase = Running then Atomic.incr running_count_atomic;
    Log.Keeper.debug
      "registry: keeper registered name=%s running_count=%d"
      name
      (Atomic.get running_count_atomic);
    Ok entry
;;

let register_with_state ~base_path name meta ~phase ~conditions =
  match
    register_with_state_result
      ~respect_shutdown_fence:false
      ~base_path
      name
      meta
      ~phase
      ~conditions
  with
  | Ok entry -> entry
  | Error (Registration_invalid error) ->
    invalid_arg (registry_entry_validation_error_to_string error)
  | Error (Registration_event_queue_unavailable { keeper_name; detail }) ->
    invalid_arg
      (Printf.sprintf
         "keeper registration event queue unavailable keeper=%s: %s"
         keeper_name
         detail)
  | Error
      (Registration_turn_failure_streak_unavailable { keeper_name; detail }) ->
    invalid_arg
      (Printf.sprintf
         "keeper registration turn failure streak unavailable keeper=%s: %s"
         keeper_name
         detail)
  | Error (Registration_shutdown_reserved _) ->
    invalid_arg "unchecked registry registration observed a shutdown fence"
  | Error Registration_intake_token_not_live ->
    invalid_arg "unchecked registry registration observed an inactive intake token"
  | Error (Registration_lifecycle_reserved owner) ->
    invalid_arg
      (Printf.sprintf
         "unchecked registry registration observed lifecycle reservation: %s"
         (Keeper_lifecycle_reservation.snapshot_to_string owner))
;;

let register ~base_path name meta =
  let conditions =
    { Keeper_state_machine.default_conditions with
      fiber_alive = true
    }
  in
  let phase = Keeper_state_machine.derive_phase conditions in
  register_with_state ~base_path name meta ~phase ~conditions
;;

let register_offline ~base_path name meta =
  let conditions =
    { Keeper_state_machine.default_conditions with
      launch_pending = true
    }
  in
  let phase = Keeper_state_machine.derive_phase conditions in
  register_with_state ~base_path name meta ~phase ~conditions
;;

let register_offline_if_admitted ?intake_token ~base_path name meta =
  let conditions =
    { Keeper_state_machine.default_conditions with
      launch_pending = true
    }
  in
  let phase = Keeper_state_machine.derive_phase conditions in
  register_with_state_result
    ?intake_token
    ~respect_shutdown_fence:true
    ~base_path
    name
    meta
    ~phase
    ~conditions
;;

let register_offline_if_admitted_for_lifecycle
      ?intake_token
      token
      ~base_path
      name
      meta
  =
  let conditions =
    { Keeper_state_machine.default_conditions with
      launch_pending = true
    }
  in
  let phase = Keeper_state_machine.derive_phase conditions in
  register_with_state_result
    ~lifecycle_token:token
    ?intake_token
    ~respect_shutdown_fence:true
    ~base_path
    name
    meta
    ~phase
    ~conditions
;;

type register_restarting_error =
  | Restart_shutdown_reserved of Keeper_shutdown_types.Operation_id.t
  | Restart_intake_token_not_live
  | Restart_lifecycle_reserved of Keeper_lifecycle_reservation.snapshot
  | Restart_event_queue_unavailable of
      { keeper_name : string
      ; detail : string
      }
  | Restart_turn_failure_streak_unavailable of
      { keeper_name : string
      ; detail : string
      }

let register_restarting_internal ?lifecycle_token ?intake_token ~base_path name meta
  : (registry_entry, register_restarting_error) result
  =
  let base_path = canonical_base_path_exn base_path in
  let meta =
    canonicalize_registry_meta ~operation:"register_restarting" ~base_path name meta
  in
  let key = registry_key ~base_path name in
  match
    Keeper_lifecycle_reservation.authorize
      ?token:lifecycle_token
      ~base_path
      ~keeper_name:name
      ()
  with
  | Error owner -> Error (Restart_lifecycle_reserved owner)
  | Ok () ->
  let conditions =
    { Keeper_state_machine.default_conditions with
      restart_requested = true
    }
  in
  let phase = Keeper_state_machine.derive_phase conditions in
  (* Build fresh entry once — its per-fiber atomics are independent of the
     registry contents, so a CAS retry can re-use the same record without
     re-allocating. Pending Event Layer stimuli are restored from the durable
     queue snapshot instead of being reset across restart. *)
  let done_p, done_r = Eio.Promise.create () in
  match
    Keeper_event_queue_persistence.load_pending_result
      ~base_path
      ~keeper_name:name
  with
  | Error detail -> Error (Restart_event_queue_unavailable { keeper_name = name; detail })
  | Ok initial_event_queue ->
  match Turn_failure_streak_store.load ~base_path ~keeper_name:name with
  | Error error ->
    Error
      (Restart_turn_failure_streak_unavailable
         { keeper_name = name
         ; detail = Turn_failure_streak_store.error_to_string error
         })
  | Ok persisted_turn_failure_streak ->
  let initial_turn_failure_streak =
    Option.value ~default:0 persisted_turn_failure_streak
  in
  let initial_failure_reason =
    if initial_turn_failure_streak > 0
    then Some (Turn_consecutive_failures initial_turn_failure_streak)
    else None
  in
  let new_entry =
    { base_path
    ; name
    ; meta
    ; phase
    ; conditions
    ; fiber_stop = Atomic.make false
    ; fiber_wakeup = Atomic.make false
    ; cadence_sleeping = Atomic.make false
    ; event_queue = Atomic.make initial_event_queue
    ; started_at = Time_compat.now ()
    ; grpc_close = Atomic.make None
    ; lane = Keeper_lane.create ()
    ; done_p
    ; done_r
    ; restart_count = 0
    ; last_restart_ts = 0.0
    ; crash_log = []
    ; last_error = None
    ; last_failure_reason = initial_failure_reason
    ; turn_consecutive_failures = initial_turn_failure_streak
    ; turn_attempt_state = Atomic.make None
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
    }
  in
  let rec loop () =
    let current = Atomic.get registry in
    let updated = StringMap.add key new_entry current in
    if Atomic.compare_and_set registry current updated
    then Ok new_entry
    else loop ()
  in
  (* Runs with the lifecycle key lock already held, so it never suspends. *)
  let guarded_loop_key_locked () =
    match
      Keeper_lifecycle_reservation.authorize
        ?token:lifecycle_token
        ~base_path
        ~keeper_name:name
        ()
    with
    | Error owner -> Error (Restart_lifecycle_reserved owner)
    | Ok () -> loop ()
  in
  (* The launch transaction already owns the durable-intake epoch when it
     supplies [intake_token]. Validate that exact ownership instead of
     reacquiring/checking the shutdown slot midway through the transaction. *)
  let commit_result =
    Keeper_lifecycle_reservation.with_key_lock ~base_path ~keeper_name:name (fun () ->
      match intake_token with
      | Some token
        when Keeper_shutdown_intake_fence.intake_token_matches
               token
               ~base_path
               ~keeper_name:name ->
        guarded_loop_key_locked ()
      | Some _ -> Error Restart_intake_token_not_live
      | None ->
        (match
           Keeper_shutdown_intake_fence.commit_registration_if_open
             ~base_path
             ~keeper_name:name
             guarded_loop_key_locked
         with
         | Keeper_shutdown_intake_fence.Registration_shutdown_reserved operation_id ->
           Error (Restart_shutdown_reserved operation_id)
         | Keeper_shutdown_intake_fence.Registration_committed result -> result))
  in
  match commit_result with
  | Error _ as error -> error
  | Ok registered ->
    Log.Keeper.info
      "registry: registering keeper name=%s base_path=%s phase=%s"
      name
      base_path
      (Keeper_state_machine.phase_to_string phase);
    Ok registered
;;

let register_restarting ~base_path name meta =
  register_restarting_internal ~base_path name meta
;;

let register_restarting_for_lifecycle ?intake_token token ~base_path name meta =
  register_restarting_internal
    ~lifecycle_token:token
    ?intake_token
    ~base_path
    name
    meta
;;

type unregister_exact_result =
  | Exact_unregistered
  | Exact_entry_missing
  | Exact_entry_replaced
  | Exact_unregister_lifecycle_reserved of Keeper_lifecycle_reservation.snapshot

type remove_entry_result =
  | Entry_removed of registry_entry
  | Entry_missing
  | Entry_replaced
  | Entry_lifecycle_reserved of Keeper_lifecycle_reservation.snapshot

let remove_entry
      ?lifecycle_token
      ?expected
      ~base_path
      name
  =
  Keeper_lifecycle_reservation.with_key_lock ~base_path ~keeper_name:name (fun () ->
  match
    Keeper_lifecycle_reservation.authorize
      ?token:lifecycle_token
      ~base_path
      ~keeper_name:name
      ()
  with
  | Error owner -> Entry_lifecycle_reserved owner
  | Ok () ->
  let key = registry_key ~base_path name in
  let rec loop () =
    let current = Atomic.get registry in
    match StringMap.find_opt key current with
    | None -> Entry_missing
    | Some entry ->
      (match expected with
       | Some expected_entry
         when not
                (Keeper_lane.Id.equal
                   (Keeper_lane.id entry.lane)
                   (Keeper_lane.id expected_entry.lane)) ->
         Entry_replaced
       | None | Some _ ->
         let updated = StringMap.remove key current in
         if Atomic.compare_and_set registry current updated
        then Entry_removed entry
         else loop ())
  in
  loop ())
;;

let finish_unregistration entry =
  (* The watchdog and heartbeat fibers retain [entry] in their closures.
     Removing the map binding therefore must also signal that exact lane. *)
  Atomic.set entry.fiber_stop true;
  Atomic.set entry.fiber_wakeup true;
  if entry.phase = Running then decr_running_count_clamped ()
;;

let unregister ~base_path name =
  Log.Keeper.info "registry: unregistering keeper name=%s base_path=%s" name base_path;
  match remove_entry ~base_path name with
  | Entry_removed entry when entry.phase = Running ->
    finish_unregistration entry;
    Log.Keeper.debug
      "registry: unregistered running keeper name=%s running_count=%d"
      name
      (Atomic.get running_count_atomic)
  | Entry_removed entry ->
    finish_unregistration entry;
    Log.Keeper.debug
      "registry: unregistered non-running keeper name=%s state=%s"
      name
      (Keeper_state_machine.phase_to_string entry.phase)
  | Entry_missing ->
    Log.Keeper.warn "registry: attempted to unregister non-existent keeper name=%s" name
  | Entry_replaced ->
    Log.Keeper.error
      "registry: unconditional unregister reported a replaced entry name=%s base_path=%s"
      name
      base_path
  | Entry_lifecycle_reserved owner ->
    Log.Keeper.warn
      "registry: unregister rejected by lifecycle reservation name=%s base_path=%s %s"
      name
      base_path
      (Keeper_lifecycle_reservation.snapshot_to_string owner)
;;

let unregister_exact_internal ?lifecycle_token entry =
  match
    remove_entry
      ?lifecycle_token
      ~expected:entry
      ~base_path:entry.base_path
      entry.name
  with
  | Entry_removed removed ->
    finish_unregistration removed;
    Exact_unregistered
  | Entry_missing -> Exact_entry_missing
  | Entry_replaced -> Exact_entry_replaced
  | Entry_lifecycle_reserved owner -> Exact_unregister_lifecycle_reserved owner
;;

let unregister_exact entry = unregister_exact_internal entry

let unregister_exact_for_lifecycle token entry =
  unregister_exact_internal ~lifecycle_token:token entry
;;

type restore_entry_result =
  | Entry_restored
  | Entry_restore_occupied of registry_entry
  | Entry_restore_invalid of registry_entry_validation_error
  | Entry_restore_lifecycle_reserved of Keeper_lifecycle_reservation.snapshot

let restore_entry_if_absent_for_lifecycle token (entry : registry_entry) =
  Keeper_lifecycle_reservation.with_key_lock
    ~base_path:entry.base_path
    ~keeper_name:entry.name
    (fun () ->
  match
    Keeper_lifecycle_reservation.authorize
      ~token
      ~base_path:entry.base_path
      ~keeper_name:entry.name
      ()
  with
  | Error owner -> Entry_restore_lifecycle_reserved owner
  | Ok () ->
    (match validate_registry_entry ~base_path:entry.base_path entry.name entry with
     | Error error -> Entry_restore_invalid error
     | Ok () ->
       let key = registry_key ~base_path:entry.base_path entry.name in
       let rec loop () =
         let current = Atomic.get registry in
         match StringMap.find_opt key current with
         | Some occupied -> Entry_restore_occupied occupied
         | None ->
           let updated = StringMap.add key entry current in
           if Atomic.compare_and_set registry current updated
           then Entry_restored
           else loop ()
       in
       loop ()))
;;

let health_of_entry ~base_path name entry =
  match validate_registry_entry ~base_path name entry with
  | Ok () -> Healthy
  | Error health -> health
;;

let project_owner_meta ~base_path ~name (entry : registry_entry) =
  match Keeper_owner_projection.lookup ~base_path ~keeper_name:name with
  | Keeper_owner_projection.Owner_absent -> Some entry
  | Owner_projection { meta = None; _ } -> None
  | Owner_projection { meta = Some meta; _ } -> Some { entry with meta }
;;

let get_with_health ~base_path name =
  match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
  | None ->
      Log.Keeper.debug "registry: lookup miss name=%s base_path=%s" name base_path;
      None
  | Some entry ->
    Option.map
      (fun entry -> entry, health_of_entry ~base_path name entry)
      (project_owner_meta ~base_path ~name entry)
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
  let base_path = Option.map canonical_base_path_exn base_path in
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
                match project_owner_meta ~base_path:key_base_path ~name:key_name v with
                | None -> acc
                | Some v ->
                  (match validate_registry_entry ~base_path:key_base_path key_name v with
                   | Ok () -> v :: acc
                   | Error reason ->
                     record_invalid_registry_entry ~operation:"all" ~name:key_name reason;
                     acc))))
    (Atomic.get registry)
    []
;;

(* Runtime-attempt cluster (runtime_attempt_merge / meta_for_runtime_attempt / record_runtime_attempt / runtime_attempt_suffix / last_runtime_attempt / runtime_attempt_freshness_threshold_sec / enrich... *)

let record_restart ~base_path name =
  Error_tracking.record_restart ~base_path name ~update_entry:update_entry_unit
;;

let set_last_error_entry ~base_path ~name err =
  Error_tracking.set_last_error_entry ~base_path ~name err ~update_entry:update_entry_unit
;;

(* record_error (MASC/AGENT_CORE Error-Warn Reduction Goal §P6 dedup logic) moved to Keeper_registry_error_recording. No alias here — it would create a cycle via [Keeper_registry.set_last_error_entry], so callers use that module directly. *)

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

(* Write-through observation of the turn event bus [pending_tool_count] in the
   live [turn_observation]. It has no timeout or lifecycle authority. A [None]
   [current_turn_observation] (turn already ended) is a no-op, so a late
   background-drain callback after [mark_turn_finished] cannot leak. *)
let record_turn_tool_inflight ~base_path name ~count =
  let (_ : bool) =
    update_entry_if_registered ~base_path name (fun e ->
      update_current_turn e (fun obs -> { obs with active_tool_count = count }))
  in
  ()
;;

(* Reset agent core-turn FSM fields while retaining Keeper-turn identity,
   timing, model, and measurement state. *)
let mark_agent_core_turn_started ~base_path name =
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
            { (stamp_turn_progress ~now ~event_kind:"agent_core_turn_started" obs) with
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
     the same CAS.  This keeps multi-field setters (gate rejection) on the
     same resolver / guard / broadcast pathway as
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

type exact_turn_interrupt_result =
  | Exact_turn_cancelled of int
  | Exact_no_turn_in_flight
  | Exact_turn_cancel_failed of
      { turn_id : int option
      ; detail : string
      }

let interrupt_current_turn_exact observed_entry =
  let current_entry =
    StringMap.find_opt
      (registry_key
         ~base_path:observed_entry.base_path
         observed_entry.name)
      (Atomic.get registry)
  in
  match current_entry with
  | None ->
    Exact_turn_cancel_failed
      { turn_id = None; detail = "registry entry disappeared before turn cancellation" }
  | Some entry
    when not
           (Keeper_lane.Id.equal
              (Keeper_lane.id entry.lane)
              (Keeper_lane.id observed_entry.lane)) ->
    Exact_turn_cancel_failed
      { turn_id = None; detail = "a newer same-name lane owns the registry entry" }
  | Some entry ->
  let turn_id =
    Option.map
      (fun observation -> observation.turn_id)
      entry.current_turn_observation
  in
    match Atomic.exchange entry.current_turn_switch None, turn_id with
    | None, None -> Exact_no_turn_in_flight
    | None, Some turn_id ->
       Exact_turn_cancel_failed
         { turn_id = Some turn_id
         ; detail = "turn observation exists without a live turn switch"
         }
    | Some turn_sw, observed_turn_id ->
      (try
         Eio.Switch.fail turn_sw Operator_interrupt;
         match observed_turn_id with
         | Some turn_id -> Exact_turn_cancelled turn_id
         | None ->
           Exact_turn_cancel_failed
             { turn_id = None
             ; detail = "live turn switch exists without a turn observation"
             }
       with
       | exn ->
         Exact_turn_cancel_failed
           { turn_id = observed_turn_id
           ; detail = Printexc.to_string exn
           })
;;

(* A cancellation that failed used to collapse into [`No_turn_in_flight], which
   reads as "there was nothing to cancel" — the opposite of what happened. The
   metric and the warn line stay; the outcome now reaches the caller so an
   operator surface can say which of the two it was. *)
let interrupt_current_turn ~base_path name =
  match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
  | None ->
    Exact_turn_cancel_failed
      { turn_id = None; detail = "no registry entry for this Keeper name" }
  | Some entry ->
    (match interrupt_current_turn_exact entry with
     | Exact_turn_cancelled _ as cancelled -> cancelled
     | Exact_no_turn_in_flight -> Exact_no_turn_in_flight
     | Exact_turn_cancel_failed { detail; _ } as failed ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string LifecycleDispatchRejections)
         ~labels:[ "keeper", name; "event", "turn_cancel_failed" ]
         ();
       Log.Keeper.warn "%s: turn cancellation failed: %s" name detail;
       failed)
;;
