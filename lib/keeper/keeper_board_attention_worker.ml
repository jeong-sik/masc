module Candidate = Keeper_board_attention_candidate
module Failure = Keeper_board_attention_failure
module Partition = Keeper_board_attention_partition
module Wake = Keeper_board_attention_worker_wake

type step =
  | Idle
  | Judgment_completed of
      { candidate_id : string
      ; owner_wake : Keeper_registry.wakeup_outcome
      }
  | Judgment_deferred of
      { candidate_id : string
      ; failure : Failure.retryable
      }
  | Candidate_already_consumed of { candidate_id : string }
  | Partition_blocked of
      { candidate_id : string
      ; reason : Partition.blocked_reason
      }

type settlement =
  | No_completed_partition
  | Partition_settled of
      { candidate_id : string
      ; continuation_wake : Keeper_registry.wakeup_outcome option
      }

let ( let* ) = Result.bind

let owner_wake ~base_path ~keeper_name =
  Keeper_registry.wakeup_running
    ~intent:Keeper_registry.Attention_result
    ~base_path
    keeper_name
;;

let recover_claim ~worker_epoch ~base_path partition original_error =
  match
    Partition.recover_claim_after_lane_abort
      ~worker_epoch
      ~base_path
      ~partition
  with
  | Ok (Partition.Claim_released _ | Partition.Claim_already_transitioned _) ->
    Error original_error
  | Error recovery_error ->
    Error
      (Printf.sprintf
         "%s; exact claim recovery also failed: %s"
         original_error
         recovery_error)
;;

let complete ~now ~worker_epoch ~base_path partition judgment =
  let item : Partition.completed_item =
    { candidate_id = partition.Partition.candidate_id; judgment }
  in
  match
    Partition.complete
      ~now
      ~worker_epoch
      ~base_path
      ~partition
      ~item
  with
  | Ok (Partition.Partition_completed completed) -> Ok completed
  | Ok (Partition.Partition_deferred _ | Partition.Partition_blocked _) ->
    recover_claim
      ~worker_epoch
      ~base_path
      partition
      "partition completion returned a non-Completed state"
  | Error detail -> recover_claim ~worker_epoch ~base_path partition detail
;;

let block ~now ~worker_epoch ~base_path partition reason =
  match Partition.block ~now ~worker_epoch ~base_path ~partition reason with
  | Ok (Partition.Partition_blocked _) ->
    Ok (Partition_blocked { candidate_id = partition.candidate_id; reason })
  | Ok (Partition.Partition_completed _ | Partition.Partition_deferred _) ->
    recover_claim
      ~worker_epoch
      ~base_path
      partition
      "partition block returned a non-Blocked state"
  | Error detail -> recover_claim ~worker_epoch ~base_path partition detail
;;

let defer ~now ~worker_epoch ~base_path partition failure =
  match Partition.defer ~now ~worker_epoch ~base_path ~partition failure with
  | Ok (Partition.Partition_deferred _) ->
    Ok (Judgment_deferred { candidate_id = partition.candidate_id; failure })
  | Ok (Partition.Partition_completed _ | Partition.Partition_blocked _) ->
    recover_claim
      ~worker_epoch
      ~base_path
      partition
      "partition defer returned a non-Deferred state"
  | Error detail -> recover_claim ~worker_epoch ~base_path partition detail
;;

let complete_and_signal ~now ~worker_epoch ~base_path partition judgment =
  let* completed = complete ~now ~worker_epoch ~base_path partition judgment in
  let owner_wake =
    owner_wake ~base_path ~keeper_name:completed.Partition.keeper_name
  in
  Ok (Judgment_completed { candidate_id = completed.candidate_id; owner_wake })
;;

let candidate_by_id candidate_id candidates =
  List.find_opt
    (fun (candidate : Candidate.candidate) ->
       String.equal candidate.candidate_id candidate_id)
    candidates
;;

let validate_partition_member partition candidate =
  if not (String.equal partition.Partition.keeper_name candidate.Candidate.keeper_name)
  then Error "partition member Keeper identity changed"
  else if not (Float.equal partition.created_at candidate.recorded_at)
  then Error "partition member recorded_at changed"
  else
    let* context_key = Candidate.Context_key.of_candidate candidate in
    if Candidate.Context_key.equal partition.context_key context_key
    then Ok ()
    else Error "partition member Keeper context changed"
;;

let process_claimed ~now ~worker_epoch ~base_path ~judge candidates partition =
  match candidate_by_id partition.Partition.candidate_id candidates with
  | None ->
    block
      ~now:(now ())
      ~worker_epoch
      ~base_path
      partition
      (Partition.Candidate_membership_conflict
         ("candidate ledger lacks partition member " ^ partition.candidate_id))
  | Some candidate ->
    (match validate_partition_member partition candidate with
     | Error detail ->
       block
         ~now:(now ())
         ~worker_epoch
         ~base_path
         partition
         (Partition.Candidate_membership_conflict detail)
     | Ok () ->
       (match candidate.status with
        | Candidate.Pending _ ->
          (match judge candidate with
           | Ok judgment ->
             complete_and_signal
               ~now:(now ())
               ~worker_epoch
               ~base_path
               partition
               judgment
           | Error (Failure.Retryable failure) ->
             defer ~now:(now ()) ~worker_epoch ~base_path partition failure
           | Error (Failure.Blocked failure) ->
             block
               ~now:(now ())
               ~worker_epoch
               ~base_path
               partition
               (Partition.Judgment_blocked failure))
        | Candidate.Judged judged ->
          complete_and_signal
            ~now:(now ())
            ~worker_epoch
            ~base_path
            partition
            judged.judgment
        | Candidate.Consumed consumed ->
          let* completed =
            complete
              ~now:(now ())
              ~worker_epoch
              ~base_path
              partition
              consumed.judgment
          in
          let* (_ : Partition.t) =
            Partition.settle ~now:(now ()) ~base_path ~partition:completed
          in
          Ok (Candidate_already_consumed { candidate_id = candidate.candidate_id })))
;;

let process_next ~now ~worker_epoch ~base_path ~keeper_name ~judge =
  let* candidates = Candidate.load_candidates ~base_path ~keeper_name in
  let* (_ : int) = Partition.ensure_roots ~base_path ~keeper_name candidates in
  let* claimed =
    Partition.claim_next ~now:(now ()) ~worker_epoch ~base_path ~keeper_name
  in
  match claimed with
  | None -> Ok Idle
  | Some partition ->
    (try
       let* current_candidates = Candidate.load_candidates ~base_path ~keeper_name in
       process_claimed
         ~now
         ~worker_epoch
         ~base_path
         ~judge
         current_candidates
         partition
     with
     | Eio.Cancel.Cancelled _ as exn ->
       Eio.Cancel.protect (fun () ->
         match
           Partition.recover_claim_after_lane_abort
             ~worker_epoch
             ~base_path
             ~partition
         with
         | Ok (Partition.Claim_released _ | Partition.Claim_already_transitioned _) -> ()
         | Error detail ->
           Log.Keeper.error
             "Board attention cancellation claim recovery failed keeper=%s partition=%s: %s"
             keeper_name
             partition.partition_id
             detail);
       raise exn
     | exn ->
       recover_claim
         ~worker_epoch
         ~base_path
         partition
         ("Board attention worker step raised: " ^ Printexc.to_string exn))
;;

let completed_in_order ~base_path ~keeper_name =
  let* completed = Partition.completed ~base_path ~keeper_name in
  Ok
    (List.sort
       (fun left right ->
          match Float.compare left.Partition.created_at right.Partition.created_at with
          | 0 -> String.compare left.partition_id right.partition_id
          | order -> order)
       completed)
;;

let settle_one_completed ~base_path ~keeper_name =
  let* completed = completed_in_order ~base_path ~keeper_name in
  match completed with
  | [] -> Ok No_completed_partition
  | partition :: _ ->
    (match partition.state with
     | Partition.Completed { item; _ } ->
       let* (_ : Candidate.candidate) =
         Candidate.apply_judgment_and_deliver
           ~base_path
           ~keeper_name
           ~candidate_id:item.candidate_id
           ~judgment:item.judgment
       in
       let* settled =
         Partition.settle
           ~now:(Time_compat.now ())
           ~base_path
           ~partition
       in
       let* remaining = completed_in_order ~base_path ~keeper_name in
       let continuation_wake =
         match remaining with
         | [] -> None
         | _ :: _ -> Some (owner_wake ~base_path ~keeper_name)
       in
       Ok
         (Partition_settled
            { candidate_id = settled.candidate_id; continuation_wake })
     | Partition.Ready
     | Partition.Running _
     | Partition.Deferred _
     | Partition.Settled _
     | Partition.Blocked _ ->
       Error
         ("completed partition query returned non-Completed state: "
          ^ partition.partition_id))
;;

let recovered_mutex = Stdlib.Mutex.create ()
let recovered_process_keys : (string, unit) Hashtbl.t = Hashtbl.create 16

let claim_process_recovery ~base_path ~keeper_name =
  let key = Keeper_registry_types.registry_key ~base_path keeper_name in
  Stdlib.Mutex.protect recovered_mutex (fun () ->
    if Hashtbl.mem recovered_process_keys key
    then false
    else (
      Hashtbl.add recovered_process_keys key ();
      true))
;;

let release_process_recovery ~base_path ~keeper_name =
  let key = Keeper_registry_types.registry_key ~base_path keeper_name in
  Stdlib.Mutex.protect recovered_mutex (fun () ->
    Hashtbl.remove recovered_process_keys key)
;;

let observe_error ~base_path ~keeper_name detail =
  (try Keeper_registry_error_recording.record ~base_path keeper_name detail with
   | Eio.Cancel.Cancelled _ as exn -> raise exn
   | exn ->
     Log.Keeper.error
       "Board attention worker failure observation also failed keeper=%s worker_error=%s observer_error=%s"
       keeper_name
       detail
       (Printexc.to_string exn));
  Log.Keeper.error "Board attention worker deferred keeper=%s: %s" keeper_name detail
;;

let run
      ~sw
      ~(clock : [> float Eio.Time.clock_ty ] Eio.Resource.t)
      ~net
      ~base_path
      ~keeper_name
  =
  match Wake.register ~sw ~base_path ~keeper_name with
  | Error detail -> observe_error ~base_path ~keeper_name detail
  | Ok registration ->
    let worker_epoch = Partition.Worker_epoch.generate () in
    let startup_ready =
      if claim_process_recovery ~base_path ~keeper_name
      then (
        try
          match Partition.recover_for_process_start ~base_path ~keeper_name with
          | Ok _ -> true
          | Error detail ->
            release_process_recovery ~base_path ~keeper_name;
            observe_error ~base_path ~keeper_name detail;
            false
        with
        | Eio.Cancel.Cancelled _ as exn ->
          release_process_recovery ~base_path ~keeper_name;
          raise exn)
      else true
    in
    let rec await_wake () =
      match Wake.await registration with
      | Wake.Registration_closed -> ()
      | Wake.Wake -> drain ()
    and await () =
      match Partition.next_provider_retry_deadline ~base_path ~keeper_name with
      | Error detail ->
        observe_error ~base_path ~keeper_name detail;
        await_wake ()
      | Ok None -> await_wake ()
      | Ok (Some deadline) ->
        let observed_at = Time_compat.now () in
        if Float.compare observed_at deadline >= 0
        then drain ()
        else (
          let delay = deadline -. observed_at in
          match
            Eio.Fiber.first
              (fun () -> `Wake (Wake.await registration))
              (fun () ->
                 Eio.Time.sleep clock delay;
                 `Provider_retry_deadline)
          with
          | `Provider_retry_deadline -> drain ()
          | `Wake Wake.Registration_closed -> ()
          | `Wake Wake.Wake -> drain ())
    and drain () =
      match
        Partition.release_due_provider_retries
          ~now:(Time_compat.now ())
          ~base_path
          ~keeper_name
      with
      | Error detail ->
        observe_error ~base_path ~keeper_name detail;
        await_wake ()
      | Ok released ->
        if released > 0
        then
          Log.Keeper.info
            "Board attention Provider-authored retry deadline released keeper=%s count=%d"
            keeper_name
            released;
        (match
           process_next
             ~now:Time_compat.now
             ~worker_epoch
             ~base_path
             ~keeper_name
             ~judge:(Candidate.judge_singleton ~sw ~net ~base_path)
         with
         | Ok Idle -> await ()
         | Ok (Judgment_completed _ | Candidate_already_consumed _) ->
           Eio.Fiber.yield ();
           drain ()
         | Ok (Judgment_deferred { candidate_id; failure }) ->
           Log.Keeper.info
             "Board attention judgment durably deferred keeper=%s candidate=%s requirement=%s"
             keeper_name
             candidate_id
             (Failure.retry_requirement_label failure.requirement);
           await ()
         | Ok (Partition_blocked { candidate_id; reason }) ->
           let reason_label =
             match reason with
             | Partition.Candidate_membership_conflict _ ->
               "candidate_membership_conflict"
             | Partition.Durable_partition_invariant _ ->
               "durable_partition_invariant"
             | Partition.Judgment_blocked blocked ->
               Failure.blocked_kind_label blocked.kind
           in
           Log.Keeper.warn
             "Board attention judgment durably blocked keeper=%s candidate=%s reason=%s"
             keeper_name
             candidate_id
             reason_label;
           Eio.Fiber.yield ();
           drain ()
         | Error detail ->
           observe_error ~base_path ~keeper_name detail;
           await ())
    in
    let rec supervise action =
      try action () with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        observe_error
          ~base_path
          ~keeper_name
          ("Board attention worker control loop raised: " ^ Printexc.to_string exn);
        supervise await
    in
    supervise (if startup_ready then drain else await)
;;

module For_testing = struct
  let process_next = process_next
end
;;
