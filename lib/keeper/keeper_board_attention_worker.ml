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

type lane_signal =
  | Candidate_recorded
  | Startup_recovery

type instance =
  { base_path : string
  ; worker_epoch : string
  ; judge : judge
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
     | Keeper_registry.Deferred_lifecycle _ -> "deferred_lifecycle")
;;

let partition_failure kind detail : Candidate.retryable_failure =
  { kind; detail; failed_at = Time_compat.now () }
;;

let candidates_for_partition ~base_path (partition : Partition.t) =
  let* candidates =
    Candidate.load_candidates ~base_path ~keeper_name:partition.keeper_name
  in
  let by_id =
    List.fold_left
      (fun map candidate ->
         Candidate.Candidate_map.add candidate.Candidate.candidate_id candidate map)
      Candidate.Candidate_map.empty
      candidates
  in
  List.fold_left
    (fun result candidate_id ->
       let* selected = result in
       match Candidate.Candidate_map.find_opt candidate_id by_id with
       | None ->
         Error
           (Printf.sprintf
              "partition %s candidate %s is absent from the candidate ledger"
              partition.partition_id
              candidate_id)
       | Some candidate ->
         (match candidate.status with
          | Candidate.Judged _ | Candidate.Consumed _ ->
            Error
              (Printf.sprintf
                 "partition %s candidate %s is no longer Pending"
                 partition.partition_id
                 candidate_id)
          | Candidate.Pending _ ->
            let* context_key = Candidate.keeper_context_key candidate in
            if not (String.equal context_key partition.context_key)
            then
              Error
                (Printf.sprintf
                   "partition %s candidate %s context changed"
                   partition.partition_id
                   candidate_id)
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

let process_claimed ~base_path ~worker_epoch ~judge partition =
  match
    run_storage ~label:"board-attention-load-partition-candidates" (fun () ->
      candidates_for_partition ~base_path partition)
  with
  | Error detail ->
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

let rec drain_keeper instance keeper_name =
  let base_path = instance.base_path in
  let* claimed =
    run_storage ~label:"board-attention-prepare-partition-claim" (fun () ->
      let* candidates = Candidate.load_candidates ~base_path ~keeper_name in
      let* (_ : Partition.t list) =
        Partition.ensure_roots
          ~now:(Time_compat.now ())
          ~base_path
          ~keeper_name
          candidates
      in
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
      process_claimed
        ~base_path
        ~worker_epoch:instance.worker_epoch
        ~judge:instance.judge
        partition
    in
    (match transition with
     | Partition.Partition_completed _ ->
       wake_owner ~base_path keeper_name;
       Eio.Fiber.yield ();
       drain_keeper instance keeper_name
     | Partition.Partition_blocked _ ->
       Eio.Fiber.yield ();
       drain_keeper instance keeper_name
     | Partition.Partition_deferred _ -> Ok ())
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

let run_lane instance keeper_name signal =
  try
    Eio.Switch.run (fun lane_sw ->
      Eio.Switch.on_release lane_sw (fun () -> finish_lane instance keeper_name);
      match signal with
      | Candidate_recorded ->
        (match drain_keeper instance keeper_name with
         | Ok () -> ()
         | Error detail ->
           record_lane_failure instance keeper_name detail;
           Log.Keeper.error
             "Board attention partition lane failed keeper=%s: %s"
             keeper_name
             detail)
      | Startup_recovery ->
        (match
           run_storage ~label:"board-attention-recover-process-start" (fun () ->
             Partition.recover_for_process_start
               ~base_path:instance.base_path
               ~keeper_name)
         with
      | Error detail ->
        record_lane_failure instance keeper_name detail;
        Log.Keeper.error
          "Board attention partition recovery failed keeper=%s: %s"
          keeper_name
          detail
      | Ok recovered ->
        if recovered > 0
        then
          Log.Keeper.info
            "Board attention partition recovery keeper=%s recovered=%d"
            keeper_name
            recovered;
        (match drain_keeper instance keeper_name with
         | Ok () -> ()
         | Error detail ->
           record_lane_failure instance keeper_name detail;
           Log.Keeper.error
             "Board attention partition lane failed keeper=%s: %s"
             keeper_name
             detail)))
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

let production_worker_epoch base_path =
  let raw =
    Printf.sprintf "%s:%d:%.17g" base_path (Unix.getpid ()) (Time_compat.now ())
  in
  "board-attention-worker-" ^ Digestif.SHA256.(digest_string raw |> to_hex)
;;

let start_instance ~sw ~base_path ~worker_epoch ~judge =
  let instance =
    { base_path
    ; worker_epoch
    ; judge
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
      ~worker_epoch:(production_worker_epoch base_path)
      ~judge:(Candidate.judge_batch_exact ~base_path))
;;

let drain_completed_on_owner_lane ~base_path ~keeper_name =
  let* resumed = Candidate.resume_judged_on_owner_lane ~base_path ~keeper_name in
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
      then Ok ()
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
      , candidate_read_errors ) =
    List.fold_left
      (fun (pending, judged, consumed, errors) keeper_name ->
         match Candidate.load_candidates ~base_path ~keeper_name with
         | Error detail -> pending, judged, consumed, (keeper_name, detail) :: errors
         | Ok candidates ->
           List.fold_left
             (fun (pending, judged, consumed, errors) candidate ->
                match candidate.Candidate.status with
                | Candidate.Pending _ -> pending + 1, judged, consumed, errors
                | Candidate.Judged _ -> pending, judged + 1, consumed, errors
                | Candidate.Consumed _ -> pending, judged, consumed + 1, errors)
             (pending, judged, consumed, errors)
             candidates)
      (0, 0, 0, [])
      candidate_keeper_names
    |> fun (pending, judged, consumed, errors) ->
    pending, judged, consumed, List.rev errors
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
  in
  let operator_action_required =
    Partition.operator_action_required durable
    || worker_missing
    || lane_failure_count > 0
    || discovery.read_errors <> []
    || candidate_read_errors <> []
  in
  let ledger_error_json error =
    `Assoc
      [ "ledger_path", `String error.Candidate.ledger_path
      ; "error", `String error.detail
      ]
  in
  let keeper_error_json (keeper_name, detail) =
    `Assoc
      [ "keeper_name", `String keeper_name
      ; "error", `String detail
      ]
  in
  `Assoc
    ([ "schema", `String Partition.fleet_summary_schema
     ; "status", `String (if operator_action_required then "degraded" else "ok")
     ; "operator_action_required", `Bool operator_action_required
     ; "status_reasons", `List (List.map (fun reason -> `String reason) status_reasons)
     ; "worker_registered", `Bool worker_registered
     ; "active_keeper_count", `Int (active_keeper_count ~base_path)
     ; "lane_failure_count", `Int lane_failure_count
     ; "lane_failures", `List (List.map keeper_error_json lane_failures)
     ; "candidate_ledger_keeper_count", `Int (List.length candidate_keeper_names)
     ; ( "candidate_ledger_keeper_names"
       , `List (List.map (fun name -> `String name) candidate_keeper_names) )
     ; "candidate_ledger_discovery_error_count", `Int (List.length discovery.read_errors)
     ; ( "candidate_ledger_discovery_errors"
       , `List (List.map ledger_error_json discovery.read_errors) )
     ; "candidate_pending_count", `Int candidate_pending_count
     ; "candidate_judged_count", `Int candidate_judged_count
     ; "candidate_consumed_count", `Int candidate_consumed_count
     ; "candidate_ledger_read_error_count", `Int (List.length candidate_read_errors)
     ; "candidate_ledger_read_errors", `List (List.map keeper_error_json candidate_read_errors)
     ]
     @ Partition.fleet_summary_detail_fields durable)
;;

module For_testing = struct
  let start_with_judge ~sw ~base_path ~worker_epoch ~judge () =
    Eio.Switch.check sw;
    Eio.Switch.run (fun worker_sw ->
      start_instance ~sw:worker_sw ~base_path ~worker_epoch ~judge)
  ;;

  let registered = registered

  let active_keeper_count = active_keeper_count
end
;;
