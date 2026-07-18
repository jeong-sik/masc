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

type instance =
  { base_path : string
  ; worker_epoch : string
  ; judge : judge
  ; sw : Eio.Switch.t
  ; mutex : Stdlib.Mutex.t
  ; condition : Eio.Condition.t
  ; mutable pending : Key_set.t
  ; mutable active : Key_set.t
  ; mutable lane_failures : string Key_map.t
  ; mutable closed : bool
  }

exception Worker_registration_conflict of string
exception Worker_startup_scan_failed of string

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

let signal_instance instance keeper_name =
  let result, notify =
    with_instance instance (fun () ->
      if instance.closed
      then Worker_not_registered, false
      else if Key_set.mem keeper_name instance.pending
      then Coalesced, false
      else (
        instance.pending <- Key_set.add keeper_name instance.pending;
        Signaled, true))
  in
  if notify then Eio.Condition.broadcast instance.condition;
  result
;;

let notify ~base_path ~keeper_name =
  match with_instances (fun () -> Hashtbl.find_opt instances base_path) with
  | None -> Worker_not_registered
  | Some instance -> signal_instance instance keeper_name
;;

let record_and_notify ~base_path candidate =
  match Candidate.record ~base_path candidate with
  | Candidate.Record_error detail -> Error detail
  | Candidate.Recorded persisted ->
    let signal = notify ~base_path ~keeper_name:persisted.keeper_name in
    Ok
      { candidate = persisted
      ; persistence = Candidate.Candidate_recorded
      ; signal
      }
  | Candidate.Duplicate persisted ->
    let signal =
      match persisted.status with
      | Candidate.Pending _ -> notify ~base_path ~keeper_name:persisted.keeper_name
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

let process_claimed ~base_path ~worker_epoch ~judge partition =
  match candidates_for_partition ~base_path partition with
  | Error detail ->
    persist_failure
      ~base_path
      ~worker_epoch
      partition
      (partition_failure Candidate.Partition_membership_conflict detail)
  | Ok candidates ->
    (match judge candidates with
     | Error failure -> persist_failure ~base_path ~worker_epoch partition failure
     | Ok judgments ->
       (match completed_items_exact partition judgments with
        | Error failure ->
          persist_failure ~base_path ~worker_epoch partition failure
        | Ok items ->
          Partition.complete
            ~now:(Time_compat.now ())
            ~worker_epoch
            ~base_path
            ~partition
            ~items))
;;

let rec drain_keeper instance keeper_name =
  let base_path = instance.base_path in
  let* candidates = Candidate.load_candidates ~base_path ~keeper_name in
  let* (_ : Partition.t list) =
    Partition.ensure_roots
      ~now:(Time_compat.now ())
      ~base_path
      ~keeper_name
      candidates
  in
  let* claimed =
    Partition.claim_next
      ~now:(Time_compat.now ())
      ~worker_epoch:instance.worker_epoch
      ~base_path
      ~keeper_name
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
     | Partition.Partition_completed _ -> wake_owner ~base_path keeper_name
     | Partition.Partition_split _
     | Partition.Partition_deferred _
     | Partition.Partition_blocked _ ->
       ());
    Eio.Fiber.yield ();
    drain_keeper instance keeper_name
;;

let finish_lane instance keeper_name =
  let notify =
    with_instance instance (fun () ->
      instance.active <- Key_set.remove keeper_name instance.active;
      not instance.closed)
  in
  if notify then Eio.Condition.broadcast instance.condition
;;

let record_lane_failure instance keeper_name detail =
  with_instance instance (fun () ->
    instance.lane_failures <- Key_map.add keeper_name detail instance.lane_failures)
;;

let run_lane instance keeper_name =
  try
    Eio.Switch.run (fun lane_sw ->
      Eio.Switch.on_release lane_sw (fun () -> finish_lane instance keeper_name);
      match
        Partition.recover_and_resume
          ~base_path:instance.base_path
          ~keeper_name
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
             detail))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
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
        Key_set.find_first_opt
          (fun keeper_name -> not (Key_set.mem keeper_name instance.active))
          instance.pending
      with
      | None -> None
      | Some keeper_name ->
        instance.pending <- Key_set.remove keeper_name instance.pending;
        instance.active <- Key_set.add keeper_name instance.active;
        instance.lane_failures <- Key_map.remove keeper_name instance.lane_failures;
        Some (`Keeper keeper_name))
;;

let rec run_dispatcher instance =
  match Eio.Condition.loop_no_mutex instance.condition (fun () -> take_startable instance) with
  | `Closed -> ()
  | `Keeper keeper_name ->
    (match Eio.Fiber.fork ~sw:instance.sw (fun () -> run_lane instance keeper_name) with
     | () -> ()
     | exception exn ->
       finish_lane instance keeper_name;
       raise exn);
    run_dispatcher instance
;;

let close_instance instance =
  let notify =
    with_instance instance (fun () ->
      if instance.closed
      then false
      else (
        instance.closed <- true;
        true))
  in
  ignore (unregister_instance instance : bool);
  if notify then Eio.Condition.broadcast instance.condition
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
    ; condition = Eio.Condition.create ()
    ; pending = Key_set.empty
    ; active = Key_set.empty
    ; lane_failures = Key_map.empty
    ; closed = false
    }
  in
  if not (register_instance instance)
  then raise (Worker_registration_conflict base_path);
  Eio.Switch.on_release sw (fun () -> close_instance instance);
  let boot_names =
    Eio_unix.run_in_systhread ~label:"board-attention-worker-boot-scan" (fun () ->
      match Candidate.discover_keeper_names ~base_path with
      | Ok names -> names
      | Error detail -> raise (Worker_startup_scan_failed detail))
  in
  List.iter (fun keeper_name -> ignore (signal_instance instance keeper_name : wake_result)) boot_names;
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
  let* legacy = Candidate.consume_judged_on_owner_lane ~base_path ~keeper_name in
  let* completed = Partition.completed ~base_path ~keeper_name in
  match completed with
  | [] -> Ok legacy
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
           | Partition.Split _
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
      { Candidate.attempted = legacy.attempted + applied.attempted
      ; consumed = legacy.consumed + applied.consumed
      ; remaining = legacy.remaining + applied.remaining
      }
;;

let health_json ~base_path =
  match Partition.fleet_summary_json ~base_path with
  | `Assoc fields ->
    let int_field name =
      match List.assoc_opt name fields with
      | Some (`Int value) -> value
      | _ -> 0
    in
    let bool_field name =
      match List.assoc_opt name fields with
      | Some (`Bool value) -> value
      | _ -> false
    in
    let string_list_field name =
      match List.assoc_opt name fields with
      | Some (`List values) ->
        List.filter_map (function `String value -> Some value | _ -> None) values
      | _ -> []
    in
    let replace name value fields =
      (name, value) :: List.remove_assoc name fields
    in
    let worker_registered = registered ~base_path in
    let lane_failures = lane_failures ~base_path in
    let lane_failure_count = List.length lane_failures in
    let pending_candidate_count = int_field "pending_candidate_count" in
    let ( candidate_keeper_names
        , candidate_discovery_error
        , candidate_pending_count
        , candidate_judged_count
        , candidate_consumed_count
        , candidate_read_errors ) =
      match Candidate.discover_keeper_names ~base_path with
      | Error detail -> [], Some detail, 0, 0, 0, []
      | Ok names ->
        List.fold_left
          (fun (pending, judged, consumed, errors) keeper_name ->
             match Candidate.load_candidates ~base_path ~keeper_name with
             | Error detail ->
               ( pending
               , judged
               , consumed
               , `Assoc
                   [ "keeper_name", `String keeper_name
                   ; "error", `String detail
                   ]
                 :: errors )
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
          names
        |> fun (pending, judged, consumed, errors) ->
        names, None, pending, judged, consumed, List.rev errors
    in
    let worker_missing =
      (pending_candidate_count > 0 || candidate_pending_count > 0)
      && not worker_registered
    in
    let candidate_read_error_count = List.length candidate_read_errors in
    let operator_action_required =
      bool_field "operator_action_required"
      || worker_missing
      || lane_failure_count > 0
      || Option.is_some candidate_discovery_error
      || candidate_read_error_count > 0
    in
    let status_reasons =
      let reasons = string_list_field "status_reasons" in
      let reasons =
        if worker_missing && not (List.mem "worker_not_registered" reasons)
        then reasons @ [ "worker_not_registered" ]
        else reasons
      in
      let reasons =
        if lane_failure_count > 0 && not (List.mem "lane_failures" reasons)
        then reasons @ [ "lane_failures" ]
        else reasons
      in
      let reasons =
        if
          Option.is_some candidate_discovery_error
          && not (List.mem "candidate_ledger_discovery_error" reasons)
        then reasons @ [ "candidate_ledger_discovery_error" ]
        else reasons
      in
      if
        candidate_read_error_count > 0
        && not (List.mem "candidate_ledger_read_errors" reasons)
      then reasons @ [ "candidate_ledger_read_errors" ]
      else reasons
    in
    fields
    |> replace "status" (`String (if operator_action_required then "degraded" else "ok"))
    |> replace "operator_action_required" (`Bool operator_action_required)
    |> replace
         "status_reasons"
         (`List (List.map (fun reason -> `String reason) status_reasons))
    |> replace "worker_registered" (`Bool worker_registered)
    |> replace "active_keeper_count" (`Int (active_keeper_count ~base_path))
    |> replace "lane_failure_count" (`Int lane_failure_count)
    |> replace
         "lane_failures"
         (`List
            (List.map
               (fun (keeper_name, detail) ->
                  `Assoc
                    [ "keeper_name", `String keeper_name
                    ; "error", `String detail
                    ])
               lane_failures))
    |> replace "candidate_ledger_keeper_count" (`Int (List.length candidate_keeper_names))
    |> replace
         "candidate_ledger_keeper_names"
         (`List (List.map (fun name -> `String name) candidate_keeper_names))
    |> replace
         "candidate_ledger_discovery_error"
         (match candidate_discovery_error with
          | Some detail -> `String detail
          | None -> `Null)
    |> replace "candidate_pending_count" (`Int candidate_pending_count)
    |> replace "candidate_judged_count" (`Int candidate_judged_count)
    |> replace "candidate_consumed_count" (`Int candidate_consumed_count)
    |> replace "candidate_ledger_read_error_count" (`Int candidate_read_error_count)
    |> replace "candidate_ledger_read_errors" (`List candidate_read_errors)
    |> fun fields -> `Assoc fields
  | json -> json
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
