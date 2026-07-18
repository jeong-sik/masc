(* See .mli. *)

module Candidate = Keeper_board_attention_candidate
module Partition = Keeper_board_attention_partition
module Key_set = Set.Make (String)
module Key_map = Map.Make (String)
module Id_set = Set.Make (String)

type wake_result =
  | Signaled
  | Coalesced
  | Worker_not_registered
  | No_signal_required

type record_acceptance =
  { candidate : Candidate.candidate
  ; persistence : Candidate.persistence
  ; signal : wake_result
  }

type judge =
  Candidate.candidate list
  -> ( Candidate.judgment Candidate.Candidate_map.t
       , Candidate.retryable_failure )
       result

type candidate_loader =
  base_path:string
  -> keeper_name:string
  -> (Candidate.candidate list, string) result

type lane_signal =
  | Candidate_recorded
  | Startup_recovery

type instance =
  { base_path : string
  ; worker_epoch : Partition.Worker_epoch.t
  ; judge : judge
  ; load_candidates : candidate_loader
  ; sw : Eio.Switch.t
  ; mutex : Stdlib.Mutex.t
  ; wakeup : unit Eio.Stream.t
  ; mutable wake_queued : bool
  ; mutable pending : lane_signal Key_map.t
  ; mutable active : Key_set.t
  ; mutable lane_failures : string Key_map.t
  ; mutable closed : bool
  }

exception Worker_registration_conflict of string

let ( let* ) = Result.bind
let instances_mutex = Stdlib.Mutex.create ()
let instances : (string, instance) Hashtbl.t = Hashtbl.create 4

let with_instances f = Stdlib.Mutex.protect instances_mutex f
let with_instance instance f = Stdlib.Mutex.protect instance.mutex f

let registered ~base_path =
  with_instances (fun () -> Hashtbl.mem instances base_path)
;;

let active_keeper_count ~base_path =
  match with_instances (fun () -> Hashtbl.find_opt instances base_path) with
  | None -> 0
  | Some instance -> with_instance instance (fun () -> Key_set.cardinal instance.active)
;;

let lane_failures ~base_path =
  match with_instances (fun () -> Hashtbl.find_opt instances base_path) with
  | None -> []
  | Some instance ->
    with_instance instance (fun () -> Key_map.bindings instance.lane_failures)
;;

let register_instance instance =
  with_instances (fun () ->
    match Hashtbl.find_opt instances instance.base_path with
    | Some _ -> false
    | None ->
      Hashtbl.add instances instance.base_path instance;
      true)
;;

let unregister_instance instance =
  with_instances (fun () ->
    match Hashtbl.find_opt instances instance.base_path with
    | Some current when current == instance ->
      Hashtbl.remove instances instance.base_path;
      true
    | Some _ | None -> false)
;;

let merge_signal current incoming =
  match current, incoming with
  | Startup_recovery, _ | _, Startup_recovery -> Startup_recovery
  | Candidate_recorded, Candidate_recorded -> Candidate_recorded
;;

(* The stream carries no work identity; durable [pending] is the SSOT. Exactly
   one queued token is therefore sufficient to tell the dispatcher to rescan.
   The caller holds [instance.mutex], making [wake_queued] and the stream's
   single-slot capacity one invariant rather than a workload-size heuristic. *)
let schedule_wakeup_locked instance =
  if instance.wake_queued
  then false
  else (
    instance.wake_queued <- true;
    true)
;;

let signal_instance instance keeper_name signal =
  let result, notify =
    with_instance instance (fun () ->
      if instance.closed
      then Worker_not_registered, false
      else (
        let result =
          match Key_map.find_opt keeper_name instance.pending with
          | Some current ->
            instance.pending <-
              Key_map.add keeper_name (merge_signal current signal) instance.pending;
            Coalesced
          | None ->
            instance.pending <- Key_map.add keeper_name signal instance.pending;
            Signaled
        in
        result, schedule_wakeup_locked instance))
  in
  if notify then Eio.Stream.add instance.wakeup ();
  result
;;

let notify ~base_path ~keeper_name signal =
  match with_instances (fun () -> Hashtbl.find_opt instances base_path) with
  | None -> Worker_not_registered
  | Some instance -> signal_instance instance keeper_name signal
;;

let record_and_notify ~base_path candidate =
  match Candidate.record ~base_path candidate with
  | Candidate.Record_error detail -> Error detail
  | Candidate.Recorded persisted ->
    let signal =
      notify ~base_path ~keeper_name:persisted.keeper_name Candidate_recorded
    in
    Ok
      { candidate = persisted
      ; persistence = Candidate.Candidate_recorded
      ; signal
      }
  | Candidate.Duplicate persisted ->
    let signal =
      match persisted.status with
      | Candidate.Pending _ ->
        notify ~base_path ~keeper_name:persisted.keeper_name Candidate_recorded
      | Candidate.Judged _ | Candidate.Consumed _ -> No_signal_required
    in
    Ok
      { candidate = persisted
      ; persistence = Candidate.Candidate_already_present
      ; signal
      }
;;

let wake_owner ~base_path keeper_name =
  let outcome =
    Keeper_registry.wakeup_running
      ~intent:Keeper_registry.Reactive_signal
      ~base_path
      keeper_name
  in
  Log.Keeper.info
    "Board attention partition completed keeper=%s owner_wake=%s"
    keeper_name
    (match outcome with
     | Keeper_registry.Signaled -> "signaled"
     | Keeper_registry.Deferred_unregistered -> "deferred_unregistered"
     | Keeper_registry.Deferred_not_running _ -> "deferred_not_running"
     | Keeper_registry.Deferred_lifecycle _ -> "deferred_lifecycle");
  outcome
;;

let partition_failure kind detail : Candidate.retryable_failure =
  { kind; detail; failed_at = Time_compat.now () }
;;

type snapshot_preparation_error =
  | Candidate_storage_unavailable of string
  | Snapshot_membership_invalid of string
  | Partition_prepare_failed of string

type candidate_selection_error = Partition_membership_invalid of string

let snapshot_preparation_error_to_string = function
  | Candidate_storage_unavailable detail ->
    "candidate storage unavailable: " ^ detail
  | Snapshot_membership_invalid detail ->
    "candidate snapshot membership invalid: " ^ detail
  | Partition_prepare_failed detail ->
    "partition preparation failed: " ^ detail
;;

type candidate_snapshot =
  { keeper_name : string
  ; ordered : Candidate.candidate list
  ; by_id : Candidate.candidate Candidate.Candidate_map.t
  }

let build_candidate_snapshot ~keeper_name candidates =
  let* by_id =
    List.fold_left
      (fun result candidate ->
         let* by_id = result in
         if not (String.equal candidate.Candidate.keeper_name keeper_name)
         then
           Error
             (Snapshot_membership_invalid
                (Printf.sprintf
                   "candidate snapshot identity mismatch expected=%s observed=%s candidate=%s"
                   keeper_name
                   candidate.keeper_name
                   candidate.candidate_id))
         else if Candidate.Candidate_map.mem candidate.Candidate.candidate_id by_id
         then
           Error
             (Snapshot_membership_invalid
                (Printf.sprintf
                   "candidate snapshot contains duplicate id %s"
                   candidate.candidate_id))
         else
           Ok
             (Candidate.Candidate_map.add
                candidate.candidate_id
                candidate
                by_id))
      (Ok Candidate.Candidate_map.empty)
      candidates
  in
  Ok { keeper_name; ordered = candidates; by_id }
;;

let candidates_for_partition ~snapshot (partition : Partition.t) =
  if not (String.equal snapshot.keeper_name partition.keeper_name)
  then
    Error
      (Partition_membership_invalid
         (Printf.sprintf
            "partition %s belongs to Keeper %s, not candidate snapshot %s"
            partition.partition_id
            partition.keeper_name
            snapshot.keeper_name))
  else
    List.fold_left
      (fun result candidate_id ->
         let* selected = result in
         match Candidate.Candidate_map.find_opt candidate_id snapshot.by_id with
         | None ->
           Error
             (Partition_membership_invalid
                (Printf.sprintf
                   "partition %s candidate %s is absent from the candidate ledger"
                   partition.partition_id
                   candidate_id))
         | Some candidate ->
           (match candidate.status with
            | Candidate.Judged _ | Candidate.Consumed _ ->
              Error
                (Partition_membership_invalid
                   (Printf.sprintf
                      "partition %s candidate %s is no longer Pending"
                      partition.partition_id
                      candidate_id))
            | Candidate.Pending _ ->
              let* context_key =
                Candidate.keeper_context_key candidate
                |> Result.map_error (fun detail -> Partition_membership_invalid detail)
              in
              if not (String.equal context_key partition.context_key)
              then
                Error
                  (Partition_membership_invalid
                     (Printf.sprintf
                        "partition %s candidate %s context changed"
                        partition.partition_id
                        candidate_id))
              else Ok (candidate :: selected)))
      (Ok [])
      partition.candidate_ids
    |> Result.map List.rev
;;

let completed_items_exact (partition : Partition.t) judgments =
  let requested =
    List.fold_left
      (fun ids candidate_id -> Id_set.add candidate_id ids)
      Id_set.empty
      partition.candidate_ids
  in
  let returned =
    Candidate.Candidate_map.fold
      (fun candidate_id _ ids -> Id_set.add candidate_id ids)
      judgments
      Id_set.empty
  in
  if not (Id_set.equal requested returned)
  then
    let missing = Id_set.diff requested returned |> Id_set.elements in
    let unknown = Id_set.diff returned requested |> Id_set.elements in
    Error
      (partition_failure
         Candidate.Response_contract_unavailable
         (Printf.sprintf
            "partition response identity mismatch missing=[%s] unknown=[%s]"
            (String.concat "," missing)
            (String.concat "," unknown)))
  else
    List.fold_left
      (fun result candidate_id ->
         let* items = result in
         match Candidate.Candidate_map.find_opt candidate_id judgments with
         | Some judgment ->
           Ok ({ Partition.candidate_id; judgment } :: items)
         | None ->
           Error
             (partition_failure
                Candidate.Response_contract_unavailable
                ("partition response lost candidate " ^ candidate_id)))
      (Ok [])
      partition.candidate_ids
    |> Result.map List.rev
;;

let persist_failure ~base_path ~worker_epoch partition failure =
  match
    Partition.fail
      ~now:(Time_compat.now ())
      ~worker_epoch
      ~base_path
      ~partition
      failure
  with
  | Ok transition -> Ok transition
  | Error detail -> Error detail
;;

(* Keep this boundary limited to the Candidate/Partition durable ledgers. Their
   transactions are explicitly dual-context and use only Unix/Stdlib work in a
   non-Eio caller. Provider judgment stays on the lane fiber: moving an OAS or
   Promise operation into this closure would perform an unhandled Eio effect. *)
let run_storage ~label operation =
  Eio_unix.run_in_systhread ~label operation
;;

let process_claimed ~base_path ~worker_epoch ~judge ~snapshot partition =
  match candidates_for_partition ~snapshot partition with
  | Error (Partition_membership_invalid detail) ->
    run_storage ~label:"board-attention-persist-membership-failure" (fun () ->
      persist_failure
        ~base_path
        ~worker_epoch
        partition
        (partition_failure Candidate.Partition_membership_conflict detail))
  | Ok candidates ->
    (match judge candidates with
     | Error failure ->
       run_storage ~label:"board-attention-persist-judge-failure" (fun () ->
         persist_failure ~base_path ~worker_epoch partition failure)
     | Ok judgments ->
       (match completed_items_exact partition judgments with
        | Error failure ->
          run_storage ~label:"board-attention-persist-response-failure" (fun () ->
            persist_failure ~base_path ~worker_epoch partition failure)
        | Ok items ->
          run_storage ~label:"board-attention-persist-completion" (fun () ->
            Partition.complete
              ~now:(Time_compat.now ())
              ~worker_epoch
              ~base_path
              ~partition
              ~items)))
;;

let recover_claim_after_lane_abort instance partition =
  let recovery =
    Eio.Cancel.protect (fun () ->
      run_storage ~label:"board-attention-recover-aborted-claim" (fun () ->
        Partition.recover_claim_after_lane_abort
          ~worker_epoch:instance.worker_epoch
          ~base_path:instance.base_path
          ~partition))
  in
  (match recovery with
   | Ok (Partition.Claim_released released) ->
     Log.Keeper.warn
       "Board attention aborted claim released keeper=%s partition=%s"
       released.keeper_name
       released.partition_id
   | Ok (Partition.Claim_already_transitioned persisted) ->
     Log.Keeper.info
       "Board attention aborted claim already transitioned keeper=%s partition=%s state=%s"
       persisted.keeper_name
       persisted.partition_id
       (Partition.state_to_string persisted.state)
   | Error detail ->
     Log.Keeper.error
       "Board attention aborted claim recovery rejected keeper=%s partition=%s: %s"
       partition.keeper_name
       partition.partition_id
       detail);
  recovery
;;

let process_claimed_with_recovery instance ~snapshot partition =
  match
    process_claimed
      ~base_path:instance.base_path
      ~worker_epoch:instance.worker_epoch
      ~judge:instance.judge
      ~snapshot
      partition
  with
  | Ok transition -> Ok transition
  | Error detail ->
    (match recover_claim_after_lane_abort instance partition with
     | Ok (Partition.Claim_released _ | Partition.Claim_already_transitioned _) ->
       Error detail
     | Error recovery_detail ->
       Error
         (Printf.sprintf
            "%s; durable claim recovery failed: %s"
            detail
            recovery_detail))
  | exception exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    (match recover_claim_after_lane_abort instance partition with
     | Ok (Partition.Claim_released _ | Partition.Claim_already_transitioned _) ->
       Printexc.raise_with_backtrace exn backtrace
     | Error recovery_detail ->
       Log.Keeper.error
         "Board attention aborted claim recovery failed keeper=%s partition=%s: %s"
         partition.keeper_name
         partition.partition_id
         recovery_detail;
       Printexc.raise_with_backtrace exn backtrace)
;;

let rec drain_ready instance keeper_name snapshot =
  let base_path = instance.base_path in
  let* claimed =
    run_storage ~label:"board-attention-claim-ready-partition" (fun () ->
      Partition.claim_next
        ~now:(Time_compat.now ())
        ~worker_epoch:instance.worker_epoch
        ~base_path
        ~keeper_name)
  in
  match claimed with
  | None -> Ok ()
  | Some partition ->
    let* transition =
      process_claimed_with_recovery instance ~snapshot partition
    in
    (match transition with
     | Partition.Partition_completed _ ->
       ignore (wake_owner ~base_path keeper_name : Keeper_registry.wakeup_outcome);
       Eio.Fiber.yield ();
       drain_ready instance keeper_name snapshot
     | Partition.Partition_blocked _ | Partition.Partition_deferred _ ->
       Eio.Fiber.yield ();
       drain_ready instance keeper_name snapshot)
;;

let drain_keeper instance keeper_name =
  let base_path = instance.base_path in
  let snapshot =
    run_storage ~label:"board-attention-prepare-candidate-snapshot" (fun () ->
      let* candidates =
        instance.load_candidates ~base_path ~keeper_name
        |> Result.map_error (fun detail -> Candidate_storage_unavailable detail)
      in
      let* snapshot = build_candidate_snapshot ~keeper_name candidates in
      let* (_ : Partition.t list) =
        Partition.ensure_roots
          ~base_path
          ~keeper_name
          snapshot.ordered
        |> Result.map_error (fun detail -> Partition_prepare_failed detail)
      in
      Ok snapshot)
  in
  let* snapshot = Result.map_error snapshot_preparation_error_to_string snapshot in
  (* A candidate recorded while this lane is active installs a durable pending
     signal. It owns the next lane cycle and therefore the next immutable
     candidate snapshot; the current cycle never mutates or rebuilds its map. *)
  drain_ready instance keeper_name snapshot
;;

let finish_lane instance keeper_name =
  let notify =
    with_instance instance (fun () ->
      instance.active <- Key_set.remove keeper_name instance.active;
      not instance.closed && schedule_wakeup_locked instance)
  in
  if notify then Eio.Stream.add instance.wakeup ()
;;

let record_lane_failure instance keeper_name detail =
  with_instance instance (fun () ->
    instance.lane_failures <- Key_map.add keeper_name detail instance.lane_failures)
;;

let replay_completed_owner_wake instance keeper_name =
  let* completed =
    run_storage ~label:"board-attention-load-completed-for-wake" (fun () ->
      Partition.completed ~base_path:instance.base_path ~keeper_name)
  in
  match completed with
  | [] -> Ok ()
  | _ :: _ ->
    ignore
      (wake_owner ~base_path:instance.base_path keeper_name
        : Keeper_registry.wakeup_outcome);
    Ok ()
;;

let run_lane_work instance keeper_name signal =
  let* () =
    match signal with
    | Candidate_recorded -> Ok ()
    | Startup_recovery ->
      let* compacted, recovered =
        run_storage ~label:"board-attention-recover-process-start" (fun () ->
          let* compacted =
            Candidate.compact_for_process_start
              ~base_path:instance.base_path
              ~keeper_name
          in
          let* recovered =
            Partition.recover_for_process_start
              ~base_path:instance.base_path
              ~keeper_name
          in
          Ok (compacted, recovered))
      in
      if compacted.rewritten
      then
        Log.Keeper.info
          "Board attention candidate compaction keeper=%s removed_rows=%d"
          keeper_name
          compacted.removed_rows;
      if recovered > 0
      then
        Log.Keeper.info
          "Board attention partition recovery keeper=%s recovered=%d"
          keeper_name
          recovered;
      Ok ()
  in
  let* () = replay_completed_owner_wake instance keeper_name in
  drain_keeper instance keeper_name
;;

let run_lane instance keeper_name signal =
  try
    Eio.Switch.run (fun lane_sw ->
      Eio.Switch.on_release lane_sw (fun () -> finish_lane instance keeper_name);
      match run_lane_work instance keeper_name signal with
      | Ok () -> ()
      | Error detail ->
        record_lane_failure instance keeper_name detail;
        Log.Keeper.error
          "Board attention partition lane failed keeper=%s signal=%s: %s"
          keeper_name
          (match signal with
           | Candidate_recorded -> "candidate_recorded"
           | Startup_recovery -> "startup_recovery")
          detail)
  with
  | Eio.Cancel.Cancelled _ as exn ->
    (match Eio.Switch.get_error instance.sw with
     | Some _ -> raise exn
     | None ->
       let detail = Printexc.to_string exn in
       record_lane_failure instance keeper_name detail;
       Log.Keeper.error
         "Board attention partition lane cancelled independently keeper=%s: %s"
         keeper_name
         detail)
  | exn ->
    let detail = Printexc.to_string exn in
    record_lane_failure instance keeper_name detail;
    Log.Keeper.error
      "Board attention partition lane crashed keeper=%s: %s"
      keeper_name
      detail
;;

let take_startable instance =
  with_instance instance (fun () ->
    if instance.closed
    then Some `Closed
    else
      match
        Key_map.find_first_opt
          (fun keeper_name -> not (Key_set.mem keeper_name instance.active))
          instance.pending
      with
      | None -> None
      | Some (keeper_name, signal) ->
        instance.pending <- Key_map.remove keeper_name instance.pending;
        instance.active <- Key_set.add keeper_name instance.active;
        instance.lane_failures <- Key_map.remove keeper_name instance.lane_failures;
        Some (`Keeper (keeper_name, signal)))
;;

let rec run_dispatcher instance =
  match take_startable instance with
  | Some `Closed -> ()
  | Some (`Keeper (keeper_name, signal)) ->
    (match
       Eio.Fiber.fork_promise ~sw:instance.sw (fun () ->
         run_lane instance keeper_name signal)
     with
     | _lane_result -> ()
     | exception exn ->
       finish_lane instance keeper_name;
       raise exn);
    run_dispatcher instance
  | None ->
    Eio.Stream.take instance.wakeup;
    with_instance instance (fun () -> instance.wake_queued <- false);
    run_dispatcher instance
;;

let close_instance instance =
  let notify =
    with_instance instance (fun () ->
      if instance.closed
      then false
      else (
        instance.closed <- true;
        schedule_wakeup_locked instance))
  in
  ignore (unregister_instance instance : bool);
  if notify then Eio.Stream.add instance.wakeup ()
;;

let start_instance ~sw ~base_path ~worker_epoch ~judge ~load_candidates =
  let instance =
    { base_path
    ; worker_epoch
    ; judge
    ; load_candidates
    ; sw
    ; mutex = Stdlib.Mutex.create ()
    ; wakeup = Eio.Stream.create 1
    ; wake_queued = false
    ; pending = Key_map.empty
    ; active = Key_set.empty
    ; lane_failures = Key_map.empty
    ; closed = false
    }
  in
  if not (register_instance instance)
  then raise (Worker_registration_conflict base_path);
  Eio.Switch.on_release sw (fun () -> close_instance instance);
  let discovery =
    Eio_unix.run_in_systhread ~label:"board-attention-worker-boot-scan" (fun () ->
      Candidate.discover_keeper_names ~base_path)
  in
  List.iter
    (fun error ->
       Log.Keeper.error
         "Board attention startup skipped unreadable candidate ledger path=%s: %s"
         error.Candidate.ledger_path
         error.detail)
    discovery.read_errors;
  List.iter
    (fun keeper_name ->
       ignore (signal_instance instance keeper_name Startup_recovery : wake_result))
    discovery.keeper_names;
  run_dispatcher instance
;;

let start ~sw ~base_path () =
  Eio.Switch.check sw;
  Eio.Switch.run (fun worker_sw ->
    start_instance
      ~sw:worker_sw
      ~base_path
      ~worker_epoch:(Partition.Worker_epoch.generate ())
      ~judge:(Candidate.judge_batch_exact ~base_path)
      ~load_candidates:Candidate.load_candidates)
;;

let drain_completed_on_owner_lane ~base_path ~keeper_name =
  let* resumed = Candidate.resume_judged_on_owner_lane ~base_path ~keeper_name in
  let* () =
    if resumed.remaining > 0
    then
      Error
        (Printf.sprintf
           "board attention durable delivery incomplete keeper=%s remaining=%d source=judged_recovery"
           keeper_name
           resumed.remaining)
    else Ok ()
  in
  let* completed = Partition.completed ~base_path ~keeper_name in
  match completed with
  | [] -> Ok resumed
  | _ :: _ ->
    let partition_ids = List.map (fun partition -> partition.Partition.partition_id) completed in
    let completed_items =
      List.concat_map
        (fun partition ->
           match partition.Partition.state with
           | Partition.Completed { items; _ } ->
             List.map (fun item -> item.Partition.candidate_id, item.judgment) items
           | Partition.Ready
           | Partition.Running _
           | Partition.Deferred _
           | Partition.Settled _
           | Partition.Blocked _ ->
             [])
        completed
    in
    let* applied =
      Candidate.apply_completed_judgments
        ~base_path
        ~keeper_name
        completed_items
    in
    let* () =
      if applied.remaining > 0
      then
        Error
          (Printf.sprintf
             "board attention durable delivery incomplete keeper=%s remaining=%d partitions=[%s]"
             keeper_name
             applied.remaining
             (String.concat "," partition_ids))
      else
        let* (_ : Partition.t list) =
          Partition.settle_many
            ~now:(Time_compat.now ())
            ~base_path
            ~keeper_name
            ~partition_ids
        in
        Ok ()
    in
    Ok
      { Candidate.attempted = resumed.attempted + applied.attempted
      ; consumed = resumed.consumed + applied.consumed
      ; remaining = resumed.remaining + applied.remaining
      }
;;

let ledger_error_json (error : Candidate.ledger_read_error) =
  `Assoc
    [ "ledger_path", `String error.ledger_path
    ; "error", `String error.detail
    ]
;;

let keeper_error_json (keeper_name, detail) =
  `Assoc
    [ "keeper_name", `String keeper_name
    ; "error", `String detail
    ]
;;

let health_projection_json
      ~status
      ~operator_action_required
      ~status_reasons
      ~worker_registered
      ~active_keeper_count
      ~lane_failures
      ~candidate_keeper_names
      ~candidate_discovery_errors
      ~candidate_pending_count
      ~candidate_judged_count
      ~candidate_consumed_count
      ~candidate_delivery_failure_count
      ~candidate_read_errors
      ~durable_detail_fields
      ~component_timed_out
  =
  let component_timeout_fields =
    match component_timed_out with
    | None -> []
    | Some timed_out -> [ "component_timed_out", `Bool timed_out ]
  in
  `Assoc
    ([ "schema", `String Partition.fleet_summary_schema
     ; "status", `String (Health_status.to_string status)
     ; "operator_action_required", `Bool operator_action_required
     ; "status_reasons", `List (List.map (fun reason -> `String reason) status_reasons)
     ; "worker_registered", `Bool worker_registered
     ; "active_keeper_count", `Int active_keeper_count
     ; "lane_failure_count", `Int (List.length lane_failures)
     ; "lane_failures", `List (List.map keeper_error_json lane_failures)
     ; "candidate_ledger_keeper_count", `Int (List.length candidate_keeper_names)
     ; ( "candidate_ledger_keeper_names"
       , `List (List.map (fun name -> `String name) candidate_keeper_names) )
     ; ( "candidate_ledger_discovery_error_count"
       , `Int (List.length candidate_discovery_errors) )
     ; ( "candidate_ledger_discovery_errors"
       , `List (List.map ledger_error_json candidate_discovery_errors) )
     ; "candidate_pending_count", `Int candidate_pending_count
     ; "candidate_judged_count", `Int candidate_judged_count
     ; "candidate_consumed_count", `Int candidate_consumed_count
     ; "candidate_delivery_failure_count", `Int candidate_delivery_failure_count
     ; "candidate_ledger_read_error_count", `Int (List.length candidate_read_errors)
     ; "candidate_ledger_read_errors", `List (List.map keeper_error_json candidate_read_errors)
     ]
     @ durable_detail_fields
     @ component_timeout_fields)
;;

let placeholder_health_json ~status ~component_timed_out =
  if Health_status.equal status Health_status.Ok
  then invalid_arg "Board attention placeholder health status must not be Ok";
  health_projection_json
    ~status
    ~operator_action_required:false
    ~status_reasons:[]
    ~worker_registered:false
    ~active_keeper_count:0
    ~lane_failures:[]
    ~candidate_keeper_names:[]
    ~candidate_discovery_errors:[]
    ~candidate_pending_count:0
    ~candidate_judged_count:0
    ~candidate_consumed_count:0
    ~candidate_delivery_failure_count:0
    ~candidate_read_errors:[]
    ~durable_detail_fields:Partition.empty_fleet_summary_detail_fields
    ~component_timed_out:(Some component_timed_out)
;;

let health_json ~base_path =
  let durable = Partition.fleet_summary ~base_path in
  let worker_registered = registered ~base_path in
  let lane_failures = lane_failures ~base_path in
  let lane_failure_count = List.length lane_failures in
  let discovery = Candidate.discover_keeper_names ~base_path in
  let candidate_keeper_names = discovery.keeper_names in
  let ( candidate_pending_count
      , candidate_judged_count
      , candidate_consumed_count
      , candidate_delivery_failure_count
      , candidate_read_errors ) =
    List.fold_left
      (fun (pending, judged, consumed, delivery_failures, errors) keeper_name ->
         match Candidate.load_candidates ~base_path ~keeper_name with
         | Error detail ->
           pending, judged, consumed, delivery_failures, (keeper_name, detail) :: errors
         | Ok candidates ->
           List.fold_left
             (fun (pending, judged, consumed, delivery_failures, errors) candidate ->
                let delivery_failures =
                  match candidate.Candidate.status with
                  | Candidate.Pending { last_failure = Some failure }
                  | Candidate.Judged { last_failure = Some failure; _ }
                    when failure.kind = Candidate.Durable_delivery_unavailable ->
                    delivery_failures + 1
                  | Candidate.Pending _ | Candidate.Judged _ | Candidate.Consumed _ ->
                    delivery_failures
                in
                match candidate.Candidate.status with
                | Candidate.Pending _ ->
                  pending + 1, judged, consumed, delivery_failures, errors
                | Candidate.Judged _ ->
                  pending, judged + 1, consumed, delivery_failures, errors
                | Candidate.Consumed _ ->
                  pending, judged, consumed + 1, delivery_failures, errors)
             (pending, judged, consumed, delivery_failures, errors)
             candidates)
      (0, 0, 0, 0, [])
      candidate_keeper_names
    |> fun (pending, judged, consumed, delivery_failures, errors) ->
    pending, judged, consumed, delivery_failures, List.rev errors
  in
  let worker_missing =
    (Partition.pending_candidate_count durable > 0 || candidate_pending_count > 0)
    && not worker_registered
  in
  let status_reasons =
    Partition.status_reasons durable
    @ (if worker_missing then [ "worker_not_registered" ] else [])
    @ (if lane_failure_count > 0 then [ "lane_failures" ] else [])
    @ (if discovery.read_errors <> [] then [ "candidate_ledger_discovery_errors" ] else [])
    @ (if candidate_read_errors <> [] then [ "candidate_ledger_read_errors" ] else [])
    @ (if candidate_delivery_failure_count > 0
       then [ "candidate_delivery_failures" ]
       else [])
  in
  let operator_action_required =
    Partition.operator_action_required durable
    || worker_missing
    || lane_failure_count > 0
    || discovery.read_errors <> []
    || candidate_read_errors <> []
    || candidate_delivery_failure_count > 0
  in
  health_projection_json
    ~status:
      (if operator_action_required then Health_status.Degraded else Health_status.Ok)
    ~operator_action_required
    ~status_reasons
    ~worker_registered
    ~active_keeper_count:(active_keeper_count ~base_path)
    ~lane_failures
    ~candidate_keeper_names
    ~candidate_discovery_errors:discovery.read_errors
    ~candidate_pending_count
    ~candidate_judged_count
    ~candidate_consumed_count
    ~candidate_delivery_failure_count
    ~candidate_read_errors
    ~durable_detail_fields:(Partition.fleet_summary_detail_fields durable)
    ~component_timed_out:None
;;

module For_testing = struct
  let start_with_judge
        ?(load_candidates = Candidate.load_candidates)
        ~sw
        ~base_path
        ~worker_epoch
        ~judge
        ()
    =
    Eio.Switch.check sw;
    Eio.Switch.run (fun worker_sw ->
      start_instance
        ~sw:worker_sw
        ~base_path
        ~worker_epoch
        ~judge
        ~load_candidates)
  ;;

  let registered = registered

  let active_keeper_count = active_keeper_count
end
;;
