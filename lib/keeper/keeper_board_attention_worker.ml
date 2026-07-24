module Candidate = Keeper_board_attention_candidate
module Exact_flow = Keeper_board_attention_exact_flow
module Partition = Keeper_board_attention_partition
module Wake = Keeper_board_attention_worker_wake

type step =
  | Idle
  | Judgment_completed of
      { candidate_id : string
      ; owner_wake : Keeper_registry.wakeup_outcome
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

let blocked_step ~now ~worker_epoch ~base_path partition reason =
  let* blocked =
    Partition.block
      ~now
      ~worker_epoch
      ~base_path
      ~partition
      reason
  in
  Ok (Partition_blocked { candidate_id = blocked.candidate_id; reason })
;;

let confirm_completed_transition
      ~base_path
      latest_partition
      operation
      (transition : Partition.exact_transition)
  =
  latest_partition := transition.partition;
  match transition.write_outcome with
  | Partition.Fsync_completed -> Ok transition.partition
  | Partition.Visible_sync_unconfirmed _ ->
    (match
       Partition.confirm_completed
         ~base_path
         ~partition:transition.partition
     with
     | Error detail -> Error (operation ^ " confirmation failed: " ^ detail)
     | Ok confirmed ->
       latest_partition := confirmed.partition;
       (match confirmed.write_outcome with
        | Partition.Fsync_completed -> Ok confirmed.partition
        | Partition.Visible_sync_unconfirmed detail ->
          Error
            (operation
             ^ " remained visible but fsync is unconfirmed after confirmation: "
             ^ detail)))
;;

let complete_partition ~now ~worker_epoch ~base_path latest_partition judgment =
  let item : Partition.completed_item =
    { candidate_id = (!latest_partition).Partition.candidate_id; judgment }
  in
  Partition.complete
    ~now
    ~worker_epoch
    ~base_path
    ~partition:!latest_partition
    ~item
;;

let complete_and_signal
      ~now
      ~worker_epoch
      ~base_path
      latest_partition
      judgment
  =
  match
    complete_partition
      ~now
      ~worker_epoch
      ~base_path
      latest_partition
      judgment
  with
  | Ok transition ->
    let* completed =
      confirm_completed_transition
        ~base_path
        latest_partition
        "exact completion"
        transition
    in
    let owner_wake =
      owner_wake ~base_path ~keeper_name:completed.Partition.keeper_name
    in
    Ok
      (Judgment_completed
         { candidate_id = completed.candidate_id; owner_wake })
  | Error detail ->
    blocked_step
      ~now
      ~worker_epoch
      ~base_path
      !latest_partition
      (Partition.Durable_partition_invariant
         ("exact completion failed: " ^ detail))
;;

let partition_provenance
      (provenance : Exact_flow.attempt_provenance)
      : Partition.exact_provenance
  =
  { slot_id = provenance.slot_id
  ; call_id = provenance.call_id
  ; plan_fingerprint = provenance.plan_fingerprint
  ; request_body_sha256 = provenance.request_body_sha256
  }
;;

let setup_blocked_reason = function
  | Exact_flow.Network_unavailable ->
    Partition.Exact_setup_unavailable "network context unavailable"
  | Exact_flow.Candidate_not_pending ->
    Partition.Exact_setup_unavailable "candidate is no longer pending"
  | Exact_flow.Prompt_contract_unavailable detail ->
    Partition.Exact_setup_unavailable ("prompt contract unavailable: " ^ detail)
  | Exact_flow.Registry_unavailable ->
    Partition.Exact_setup_unavailable "runtime registry unavailable"
  | Exact_flow.Lane_unavailable ->
    Partition.Exact_setup_unavailable "board exact lane unavailable"
  | Exact_flow.Lane_resolved_without_slots ->
    Partition.Exact_setup_unavailable "board exact lane has no admitted slots"
  | Exact_flow.Candidate_invalid { position; slot_id = _ } ->
    Partition.Exact_setup_unavailable
      (Printf.sprintf "board exact lane slot %d has invalid identity" position)
  | Exact_flow.Flow_admission_failed ->
    Partition.Exact_setup_unavailable "OAS exact-flow admission failed"
  | Exact_flow.Flow_start_failed ->
    Partition.Exact_setup_unavailable "OAS exact-flow start failed"
;;

let exact_provenance_equal left right =
  String.equal left.Partition.slot_id right.Partition.slot_id
  && String.equal left.call_id right.call_id
  && String.equal left.plan_fingerprint right.plan_fingerprint
  && String.equal left.request_body_sha256 right.request_body_sha256
;;

let running_progress partition =
  match partition.Partition.state with
  | Partition.Running { progress; _ } -> Some progress
  | Partition.Ready
  | Partition.Completed _
  | Partition.Settled _
  | Partition.Blocked _ -> None
;;

let preserve_durable_progress partition fallback =
  match running_progress partition with
  | Some ((Partition.Bound _ | Partition.Advancing _) as progress) ->
    Partition.Exact_execution_quarantined progress
  | Some Partition.Unbound | None -> fallback
;;

let callback_invariant operation cause =
  Partition.Durable_partition_invariant
    (Printf.sprintf "%s callback disagrees with durable progress: %s" operation cause)
;;

let before_dispatch_failure_reason partition ~cause ~current =
  let projected = partition_provenance current in
  match running_progress partition with
  | Some (Partition.Bound durable as progress)
    when exact_provenance_equal durable projected ->
    Partition.Exact_execution_quarantined progress
  | Some (Partition.Advancing { next; _ } as progress)
    when exact_provenance_equal next projected ->
    Partition.Exact_execution_quarantined progress
  | Some Partition.Unbound
  | Some (Partition.Bound _ | Partition.Advancing _)
  | None -> callback_invariant "before-dispatch" cause
;;

let before_advance_failure_reason partition ~cause ~failed ~next =
  let failed = partition_provenance failed in
  let next = partition_provenance next in
  match running_progress partition with
  | Some (Partition.Bound durable as progress)
    when exact_provenance_equal durable failed ->
    Partition.Exact_execution_quarantined progress
  | Some (Partition.Advancing durable as progress)
    when exact_provenance_equal durable.failed failed
         && exact_provenance_equal durable.next next ->
    Partition.Exact_execution_quarantined progress
  | Some Partition.Unbound
  | Some (Partition.Bound _ | Partition.Advancing _)
  | None -> callback_invariant "before-advance" cause
;;

let execution_blocked_reason partition = function
  | Exact_flow.Flow_already_started _ ->
    preserve_durable_progress partition Partition.Exact_flow_replayed
  | Exact_flow.Before_dispatch_persistence_failed
      { cause; current; evidence = _ } ->
    before_dispatch_failure_reason partition ~cause ~current
  | Exact_flow.Before_advance_persistence_failed
      { cause; failed; next; evidence = _ } ->
    before_advance_failure_reason partition ~cause ~failed ~next
  | Exact_flow.Exact_execution_failed _ ->
    preserve_durable_progress partition Partition.Exact_execution_terminal
  | Exact_flow.Provenance_mismatch detail ->
    preserve_durable_progress
      partition
      (Partition.Execution_provenance_mismatch detail)
  | Exact_flow.Domain_output_invalid detail ->
    preserve_durable_progress partition (Partition.Domain_output_invalid detail)
;;

let confirm_exact_transition latest_partition operation = function
  | Error detail -> Error (operation ^ " failed: " ^ detail)
  | Ok transition ->
    latest_partition := transition.Partition.partition;
    (match transition.write_outcome with
     | Partition.Fsync_completed -> Ok ()
     | Partition.Visible_sync_unconfirmed detail ->
       Error (operation ^ " visible but fsync is unconfirmed: " ^ detail))
;;

let before_dispatch
      ~worker_epoch
      ~base_path
      latest_partition
      provenance
  =
  let provenance = partition_provenance provenance in
  Partition.bind_before_dispatch
    ~worker_epoch
    ~base_path
    ~partition:!latest_partition
    ~provenance
  |> confirm_exact_transition latest_partition "exact before-dispatch bind"
;;

let before_advance
      ~worker_epoch
      ~base_path
      latest_partition
      ~failed
      ~next
  =
  let failed = partition_provenance failed in
  let next = partition_provenance next in
  Partition.record_before_advance
    ~worker_epoch
    ~base_path
    ~partition:!latest_partition
    ~failed
    ~next
  |> confirm_exact_transition latest_partition "exact before-advance record"
;;

let complete_existing_judgment
      ~now
      ~worker_epoch
      ~base_path
      latest_partition
      judgment
  =
  let item : Partition.completed_item =
    { candidate_id = (!latest_partition).candidate_id; judgment }
  in
  match
    Partition.complete_existing_judgment
      ~now:(now ())
      ~worker_epoch
      ~base_path
      ~partition:!latest_partition
      ~item
  with
  | Ok transition ->
    let* completed =
      confirm_completed_transition
        ~base_path
        latest_partition
        "existing judgment completion"
        transition
    in
    let owner_wake =
      owner_wake ~base_path ~keeper_name:completed.Partition.keeper_name
    in
    Ok
      (Judgment_completed
         { candidate_id = completed.candidate_id; owner_wake })
  | Error detail ->
    blocked_step
      ~now:(now ())
      ~worker_epoch
      ~base_path
      !latest_partition
      (Partition.Durable_partition_invariant
         ("existing judgment completion failed: " ^ detail))
;;

let settle_existing_consumed
      ~now
      ~worker_epoch
      ~base_path
      latest_partition
      judgment
  =
  let item : Partition.completed_item =
    { candidate_id = (!latest_partition).candidate_id; judgment }
  in
  match
    Partition.complete_existing_judgment
      ~now:(now ())
      ~worker_epoch
      ~base_path
      ~partition:!latest_partition
      ~item
  with
  | Error detail ->
    blocked_step
      ~now:(now ())
      ~worker_epoch
      ~base_path
      !latest_partition
      (Partition.Durable_partition_invariant
         ("existing consumed completion failed: " ^ detail))
  | Ok transition ->
    let* completed =
      confirm_completed_transition
        ~base_path
        latest_partition
        "existing consumed completion"
        transition
    in
    let* settled =
      Partition.settle ~now:(now ()) ~base_path ~partition:completed
    in
    Ok (Candidate_already_consumed { candidate_id = settled.candidate_id })
;;

let process_pending
      ~now
      ~worker_epoch
      ~base_path
      ~prepare
      ~execute
      latest_partition
      candidate
  =
  match prepare candidate with
  | Error error ->
    blocked_step
      ~now:(now ())
      ~worker_epoch
      ~base_path
      !latest_partition
      (setup_blocked_reason error)
  | Ok prepared ->
    (match
       execute
         ~before_dispatch:
           (before_dispatch ~worker_epoch ~base_path latest_partition)
         ~before_advance:
           (before_advance ~worker_epoch ~base_path latest_partition)
         prepared
     with
     | Error error ->
       let reason = execution_blocked_reason !latest_partition error in
       blocked_step
         ~now:(now ())
         ~worker_epoch
         ~base_path
         !latest_partition
         reason
     | Ok judgment ->
       complete_and_signal
         ~now:(now ())
         ~worker_epoch
         ~base_path
         latest_partition
         judgment)
;;

let process_claimed
      ~now
      ~worker_epoch
      ~base_path
      ~prepare
      ~execute
      latest_partition
      candidates
  =
  let partition = !latest_partition in
  match candidate_by_id partition.Partition.candidate_id candidates with
  | None ->
    blocked_step
      ~now:(now ())
      ~worker_epoch
      ~base_path
      partition
      (Partition.Candidate_membership_conflict
         ("candidate ledger lacks partition member " ^ partition.candidate_id))
  | Some candidate ->
    (match validate_partition_member partition candidate with
     | Error detail ->
       blocked_step
         ~now:(now ())
         ~worker_epoch
         ~base_path
         partition
         (Partition.Candidate_membership_conflict detail)
     | Ok () ->
       (match candidate.status with
        | Candidate.Pending _ ->
          process_pending
            ~now
            ~worker_epoch
            ~base_path
            ~prepare
            ~execute
            latest_partition
            candidate
        | Candidate.Judged judged ->
          complete_existing_judgment
            ~now
            ~worker_epoch
            ~base_path
            latest_partition
            judged.judgment
        | Candidate.Consumed consumed ->
          settle_existing_consumed
            ~now
            ~worker_epoch
            ~base_path
            latest_partition
            consumed.judgment))
;;

let quarantine_cancelled_execution
      ~now
      ~worker_epoch
      ~base_path
      ~keeper_name
      latest_partition
  =
  match (!latest_partition).Partition.state with
  | Partition.Running
      { progress = ((Partition.Bound _ | Partition.Advancing _) as progress); _ } ->
    (match
       Partition.block
         ~now:(now ())
         ~worker_epoch
         ~base_path
         ~partition:!latest_partition
         (Partition.Exact_execution_quarantined progress)
     with
     | Ok _ -> ()
     | Error detail ->
       Log.Keeper.error
         "Board attention cancellation quarantine failed keeper=%s partition=%s: %s"
         keeper_name
         (!latest_partition).partition_id
         detail)
  | Partition.Running { progress = Partition.Unbound; _ } ->
    (* No durable dispatch ownership exists. Keep Running Unbound so the sole
       process-start recovery path can return it to Ready. *)
    ()
  | Partition.Ready
  | Partition.Completed _
  | Partition.Settled _
  | Partition.Blocked _ -> ()
;;

let process_next
      ~now
      ~worker_epoch
      ~base_path
      ~keeper_name
      ~prepare
      ~execute
  =
  let* candidates = Candidate.load_candidates ~base_path ~keeper_name in
  let* (_ : int) = Partition.ensure_roots ~base_path ~keeper_name candidates in
  let* claimed =
    Partition.claim_next ~now:(now ()) ~worker_epoch ~base_path ~keeper_name
  in
  match claimed with
  | None -> Ok Idle
  | Some partition ->
    let latest_partition = ref partition in
    (try
       let* current_candidates = Candidate.load_candidates ~base_path ~keeper_name in
       process_claimed
         ~now
         ~worker_epoch
         ~base_path
         ~prepare
         ~execute
         latest_partition
         current_candidates
     with
     | Eio.Cancel.Cancelled _ as exn ->
       Eio.Cancel.protect (fun () ->
         quarantine_cancelled_execution
           ~now
           ~worker_epoch
           ~base_path
           ~keeper_name
           latest_partition);
       raise exn
     | _exn ->
       let reason =
         preserve_durable_progress
           !latest_partition
           (Partition.Unexpected_worker_failure
              "Board attention worker raised unexpectedly")
       in
       blocked_step
         ~now:(now ())
         ~worker_epoch
         ~base_path
         !latest_partition
         reason)
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

let confirm_loaded_completed
      ~base_path
      operation
      partition
  =
  match Partition.confirm_completed ~base_path ~partition with
  | Error detail -> Error (operation ^ " confirmation failed: " ^ detail)
  | Ok transition ->
    (match transition.write_outcome with
     | Partition.Fsync_completed -> Ok transition.partition
     | Partition.Visible_sync_unconfirmed detail ->
       Error
         (operation
          ^ " remained visible but fsync is unconfirmed after confirmation: "
          ^ detail))
;;

let replay_completed_owner_wake
      ~base_path
      ~keeper_name
      ~wake_owner
  =
  let* completed = completed_in_order ~base_path ~keeper_name in
  match completed with
  | [] -> Ok None
  | partition :: _ ->
    let* (_ : Partition.t) =
      confirm_loaded_completed
        ~base_path
        "completed owner-wake replay"
        partition
    in
    Ok (Some (wake_owner ~base_path ~keeper_name))
;;

let settle_one_completed
      ~base_path
      ~keeper_name
  =
  let* completed = completed_in_order ~base_path ~keeper_name in
  match completed with
  | [] -> Ok No_completed_partition
  | partition :: _ ->
    let* partition =
      confirm_loaded_completed
        ~base_path
        "completed owner settlement"
        partition
    in
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

let with_process_recovery_claim ~base_path ~keeper_name run =
  let claimed = claim_process_recovery ~base_path ~keeper_name in
  Fun.protect
    ~finally:(fun () ->
      if claimed then release_process_recovery ~base_path ~keeper_name)
    (fun () -> run claimed)
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
  Log.Keeper.error "Board attention worker failed keeper=%s: %s" keeper_name detail
;;

let rec drain_available
          ~yield
          ~now
          ~worker_epoch
          ~base_path
          ~keeper_name
          ~prepare
          ~execute
  =
  match
    process_next
      ~now
      ~worker_epoch
      ~base_path
      ~keeper_name
      ~prepare
      ~execute
  with
  | Ok Idle -> Ok ()
  | Ok (Judgment_completed _ | Candidate_already_consumed _ | Partition_blocked _) ->
    yield ();
    drain_available
      ~yield
      ~now
      ~worker_epoch
      ~base_path
      ~keeper_name
      ~prepare
      ~execute
  | Error detail -> Error detail
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
    with_process_recovery_claim ~base_path ~keeper_name @@ fun owns_process_recovery ->
    let worker_epoch = Partition.Worker_epoch.generate () in
    let startup_ready =
      if owns_process_recovery
      then (
        try
          match
            Partition.recover_for_process_start
              ~now:(Time_compat.now ())
              ~base_path
              ~keeper_name
          with
          | Ok _ ->
            (match
               replay_completed_owner_wake
                 ~base_path
                 ~keeper_name
                 ~wake_owner:owner_wake
             with
             | Ok _ -> true
             | Error detail ->
               observe_error ~base_path ~keeper_name detail;
               false)
          | Error detail ->
            observe_error ~base_path ~keeper_name detail;
            false
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn)
      else true
    in
    let prepare = Exact_flow.prepare ~net in
    let execute = Exact_flow.execute ~clock in
    let rec await () =
      match Wake.await registration with
      | Wake.Registration_closed -> ()
      | Wake.Wake -> drain ()
    and drain () =
      match
        drain_available
          ~yield:Eio.Fiber.yield
          ~now:Time_compat.now
          ~worker_epoch
          ~base_path
          ~keeper_name
          ~prepare
          ~execute
      with
      | Ok () -> await ()
      | Error detail ->
        observe_error ~base_path ~keeper_name detail;
        await ()
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
  let drain_available = drain_available
  let replay_completed_owner_wake = replay_completed_owner_wake
  let with_process_recovery_claim = with_process_recovery_claim
end
;;
