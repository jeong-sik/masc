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

type fatal_stage =
  | Registration
  | Process_start_recovery
  | Durable_drain
  | Control_loop

type fatal_error =
  { stage : fatal_stage
  ; detail : string
  }

let fatal_stage_to_string = function
  | Registration -> "registration"
  | Process_start_recovery -> "process_start_recovery"
  | Durable_drain -> "durable_drain"
  | Control_loop -> "control_loop"
;;

let fatal_error_to_string error =
  Printf.sprintf
    "Board attention worker fatal stage=%s detail=%s"
    (fatal_stage_to_string error.stage)
    error.detail
;;

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

let confirm_blocked_transition ~base_path transition =
  match transition.Partition.write_outcome with
  | Partition.Fsync_completed -> Ok transition.partition
  | Partition.Visible_sync_unconfirmed _ ->
    let* confirmed =
      Partition.confirm_blocked ~base_path ~partition:transition.partition
    in
    (match confirmed.write_outcome with
     | Partition.Fsync_completed -> Ok confirmed.partition
     | Partition.Visible_sync_unconfirmed detail ->
       Error ("Blocked partition fsync remains unconfirmed: " ^ detail))
;;

let failure_category_of_reason = function
  | Partition.Candidate_membership_conflict _ ->
    Candidate.Candidate_membership_conflict
  | Partition.Durable_partition_invariant _ ->
    Candidate.Durable_partition_invariant
  | Partition.Exact_setup_unavailable _ -> Candidate.Exact_setup_unavailable
  | Partition.Exact_flow_replayed -> Candidate.Exact_flow_replayed
  | Partition.Exact_execution_terminal -> Candidate.Exact_execution_terminal
  | Partition.Domain_output_invalid _ -> Candidate.Domain_output_invalid
  | Partition.Execution_provenance_mismatch _ ->
    Candidate.Execution_provenance_mismatch
  | Partition.Unexpected_worker_failure _ ->
    Candidate.Unexpected_worker_failure
  | Partition.Exact_execution_quarantined _ ->
    Candidate.Exact_execution_quarantined
;;

let candidate_provenance (provenance : Partition.exact_provenance) :
    Candidate.attempt_provenance
  =
  { slot_id = provenance.slot_id
  ; call_id = provenance.call_id
  ; plan_fingerprint = provenance.plan_fingerprint
  ; request_body_sha256 = provenance.request_body_sha256
  }
;;

let attempt_provenance_of_reason = function
  | Partition.Exact_execution_quarantined (Partition.Bound provenance) ->
    Some (candidate_provenance provenance)
  | Partition.Exact_execution_quarantined
      (Partition.Advancing { next; _ }) ->
    Some (candidate_provenance next)
  | Partition.Exact_execution_quarantined Partition.Unbound
  | Partition.Candidate_membership_conflict _
  | Partition.Durable_partition_invariant _
  | Partition.Exact_setup_unavailable _
  | Partition.Exact_flow_replayed
  | Partition.Exact_execution_terminal
  | Partition.Domain_output_invalid _
  | Partition.Execution_provenance_mismatch _
  | Partition.Unexpected_worker_failure _ -> None
;;

let quarantine_blocked_partition ~base_path partition =
  match partition.Partition.state with
  | Partition.Blocked { reason; blocked_at } ->
    let* candidates =
      Candidate.load_candidates
        ~base_path
        ~keeper_name:partition.keeper_name
    in
    let* candidate =
      match
        List.find_opt
          (fun candidate ->
             String.equal candidate.Candidate.candidate_id partition.candidate_id)
          candidates
      with
      | Some candidate -> Ok candidate
      | None ->
        Error
          ("Blocked partition candidate is absent: "
           ^ partition.candidate_id)
    in
    Candidate.quarantine
      ~base_path
      ~candidate
      ~partition_id:partition.partition_id
      ~partition_generation:partition.generation
      ~failure_category:(failure_category_of_reason reason)
      ~attempt_provenance:(attempt_provenance_of_reason reason)
      ~quarantined_at:blocked_at
    |> Result.map ignore
  | Partition.Ready
  | Partition.Running _
  | Partition.Completed _
  | Partition.Settled _ ->
    Error ("partition is not Blocked: " ^ partition.partition_id)
;;

let blocked_step ~now ~worker_epoch ~base_path partition reason =
  let* transition =
    Partition.block
      ~now
      ~worker_epoch
      ~base_path
      ~partition
      reason
  in
  let* blocked = confirm_blocked_transition ~base_path transition in
  let* () = quarantine_blocked_partition ~base_path blocked in
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
    let reason =
      preserve_durable_progress
        !latest_partition
        (Partition.Durable_partition_invariant
           ("exact completion failed: " ^ detail))
    in
    blocked_step
      ~now
      ~worker_epoch
      ~base_path
      !latest_partition
      reason
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

let setup_error_detail = function
  | Exact_flow.Network_unavailable -> "network context unavailable"
  | Exact_flow.Candidate_not_pending -> "candidate is no longer pending"
  | Exact_flow.Prompt_contract_unavailable detail ->
    "prompt contract unavailable: " ^ detail
  | Exact_flow.Registry_unavailable -> "runtime registry unavailable"
  | Exact_flow.Lane_unavailable -> "board exact lane unavailable"
  | Exact_flow.Lane_resolved_without_slots ->
    "board exact lane has no admitted slots"
  | Exact_flow.Candidate_invalid { position; slot_id = _ } ->
    Printf.sprintf "board exact lane slot %d has invalid identity" position
  | Exact_flow.Flow_admission_failed -> "OAS exact-flow admission failed"
  | Exact_flow.Flow_start_failed -> "OAS exact-flow start failed"
;;

let exact_provenance_equal left right =
  String.equal left.Partition.slot_id right.Partition.slot_id
  && String.equal left.call_id right.call_id
  && String.equal left.plan_fingerprint right.plan_fingerprint
  && String.equal left.request_body_sha256 right.request_body_sha256
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
    let* (_ : Candidate.candidate) =
      Candidate.normalize_requeued_consumed
        ~base_path
        ~keeper_name:completed.keeper_name
        ~candidate_id:completed.candidate_id
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
      ~execute
      latest_partition
      prepared
  =
  match
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
      judgment
;;

let process_claimed
      ~now
      ~worker_epoch
      ~base_path
      ~prepared
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
       (match Candidate.resumable_status candidate.status with
        | Some (Candidate.Resumable_pending _) ->
          (match prepared with
           | Some (candidate_id, prepared)
             when String.equal candidate_id candidate.candidate_id ->
             process_pending
               ~now
               ~worker_epoch
               ~base_path
               ~execute
               latest_partition
               prepared
           | Some _ | None ->
             Error
               ("Board attention claimed Pending candidate without successful "
                ^ "pre-claim exact setup: "
                ^ candidate.candidate_id))
        | Some (Candidate.Resumable_judged judged) ->
          complete_existing_judgment
            ~now
            ~worker_epoch
            ~base_path
            latest_partition
            judged.judgment
        | Some (Candidate.Resumable_consumed consumed) ->
          settle_existing_consumed
            ~now
            ~worker_epoch
            ~base_path
            latest_partition
            consumed.judgment
        | None ->
          Error
            ("Quarantined Board attention candidate became claimable: "
             ^ candidate.candidate_id)))
;;

let prepare_next_ready
      ~base_path
      ~keeper_name
      ~prepare
      candidates
  =
  let* partitions = Partition.load ~base_path ~keeper_name in
  match
    List.find_opt
      (fun (partition : Partition.t) ->
         match partition.state with
         | Partition.Ready -> true
         | Partition.Running _
         | Partition.Completed _
         | Partition.Settled _
         | Partition.Blocked _ -> false)
      partitions
  with
  | None -> Ok None
  | Some partition ->
    let selected prepared =
      Ok (Some (partition.partition_id, partition.generation, prepared))
    in
    (match candidate_by_id partition.candidate_id candidates with
     | None -> selected None
     | Some candidate ->
       (match validate_partition_member partition candidate with
        | Error _ -> selected None
        | Ok () ->
          (match Candidate.resumable_status candidate.status with
           | Some (Candidate.Resumable_pending _) ->
             (match prepare candidate with
              | Ok prepared ->
                selected (Some (candidate.candidate_id, prepared))
              | Error error ->
                Error
                  ("Board attention exact setup unavailable before claim: "
                   ^ setup_error_detail error))
           | Some
               (Candidate.Resumable_judged _
               | Candidate.Resumable_consumed _)
           | None -> selected None)))
;;

let confirm_requeue_transition ~base_path transition =
  match transition.Partition.write_outcome with
  | Partition.Fsync_completed -> Ok transition
  | Partition.Visible_sync_unconfirmed _ ->
    let* confirmed =
      Partition.confirm_ready
        ~base_path
        ~partition:transition.partition
    in
    (match confirmed.write_outcome with
     | Partition.Fsync_completed -> Ok confirmed
     | Partition.Visible_sync_unconfirmed detail ->
       Error ("requeued partition fsync remains unconfirmed: " ^ detail))
;;

let rec converge_requeue_conflict
    ?(remaining_cursor_retries = 2)
    ~base_path
    ~keeper_name
    ~partition
    ~expected_quarantine_id
  =
  let* candidates = Candidate.load_candidates ~base_path ~keeper_name in
  let* candidate =
    match
      List.find_opt
        (fun candidate ->
           String.equal
             candidate.Candidate.candidate_id
             partition.Partition.candidate_id)
        candidates
    with
    | Some candidate -> Ok candidate
    | None ->
      Error
        ("partition candidate disappeared during requeue convergence: "
         ^ partition.candidate_id)
  in
  let* () =
    match Candidate.quarantine_state candidate.status with
    | Some
        { quarantine
        ; phase = Candidate.Requeued _
        }
      when String.equal quarantine.partition_id partition.partition_id
           && String.equal quarantine.quarantine_id expected_quarantine_id
           && Partition.Generation.equal
                quarantine.partition_generation
                partition.generation ->
      Ok ()
    | Some _ | None ->
      Error
        ("candidate quarantine generation changed during requeue convergence: "
         ^ partition.partition_id)
  in
  let* partitions = Partition.load ~base_path ~keeper_name in
  let* current =
    match
      List.find_opt
        (fun current ->
           String.equal current.Partition.partition_id partition.partition_id)
        partitions
    with
    | Some current -> Ok current
    | None ->
      Error
        ("partition disappeared during requeue convergence: "
         ^ partition.partition_id)
  in
  match current.state with
  | Partition.Ready
    when Partition.Generation.is_direct_successor
           ~previous:partition.generation
           current.generation ->
    let* confirmation = Partition.confirm_ready ~base_path ~partition:current in
    confirm_requeue_transition ~base_path confirmation
  | Partition.Blocked _ when current = partition ->
    if remaining_cursor_retries <= 0
    then
      Error
        ("partition ledger cursor remained conflicted after bounded requeue retries: "
         ^ partition.partition_id)
    else
      let* outcome = Partition.requeue_blocked ~base_path ~partition:current in
      (match outcome with
       | Partition.Requeued transition ->
         confirm_requeue_transition ~base_path transition
       | Partition.Cursor_conflict _ ->
         converge_requeue_conflict
           ~remaining_cursor_retries:(remaining_cursor_retries - 1)
           ~base_path
           ~keeper_name
           ~partition
           ~expected_quarantine_id
       | Partition.Generation_conflict detail ->
         Error ("partition target generation changed during requeue: " ^ detail))
  | Partition.Ready
  | Partition.Blocked _
  | Partition.Running _
  | Partition.Completed _
  | Partition.Settled _ ->
    Error
      ("partition generation changed during requeue convergence: "
       ^ partition.partition_id)
;;

let confirm_requeue_outcome
      ~base_path
      ~keeper_name
      ~partition
      ~expected_quarantine_id
  = function
  | Partition.Requeued transition ->
    confirm_requeue_transition ~base_path transition
  | Partition.Cursor_conflict _ ->
    converge_requeue_conflict
      ~base_path
      ~keeper_name
      ~partition
      ~expected_quarantine_id
  | Partition.Generation_conflict detail ->
    Error ("partition target generation changed during requeue: " ^ detail)
;;

let reconcile_quarantines ~now ~base_path ~keeper_name =
  let* partitions = Partition.load ~base_path ~keeper_name in
  let rec loop = function
    | [] -> Ok ()
    | partition :: rest ->
      let* candidates = Candidate.load_candidates ~base_path ~keeper_name in
      let* candidate =
        match
          List.find_opt
            (fun candidate ->
               String.equal
                 candidate.Candidate.candidate_id
                 partition.Partition.candidate_id)
            candidates
        with
        | Some candidate -> Ok candidate
        | None ->
          Error
            ("partition candidate is absent during quarantine reconciliation: "
             ^ partition.candidate_id)
      in
      (match partition.state, Candidate.quarantine_state candidate.status with
       | Partition.Blocked _, Some state
         when String.equal
                state.quarantine.partition_id
                partition.partition_id
              && Partition.Generation.equal
                   state.quarantine.partition_generation
                   partition.generation ->
         (match state.phase with
          | Candidate.Requeue_requested _ ->
            let* (_ : Candidate.candidate) =
              Candidate.finish_quarantine_requeue
                ~base_path
                ~candidate
                ~partition_id:partition.partition_id
                ~expected_quarantine_id:state.quarantine.quarantine_id
                ~requeued_at:now
            in
            let* (_ : Partition.exact_transition) =
              let* outcome = Partition.requeue_blocked ~base_path ~partition in
              confirm_requeue_outcome
                ~base_path
                ~keeper_name
                ~partition
                ~expected_quarantine_id:state.quarantine.quarantine_id
                outcome
            in
            loop rest
          | Candidate.Quarantined -> loop rest
          | Candidate.Requeued _ ->
            let* (_ : Partition.exact_transition) =
              let* outcome = Partition.requeue_blocked ~base_path ~partition in
              confirm_requeue_outcome
                ~base_path
                ~keeper_name
                ~partition
                ~expected_quarantine_id:state.quarantine.quarantine_id
                outcome
            in
            loop rest)
       | Partition.Blocked _, _ ->
         let* () = quarantine_blocked_partition ~base_path partition in
         loop rest
       | Partition.Ready, Some state
         when String.equal
                state.quarantine.partition_id
                partition.partition_id
              && Partition.Generation.is_direct_successor
                   ~previous:state.quarantine.partition_generation
                   partition.generation ->
         (match state.phase with
          | Candidate.Requeue_requested _ ->
            Error
              ("Ready partition preceded candidate requeue authorization: "
               ^ partition.partition_id)
          | Candidate.Quarantined ->
            Error
              ("Ready partition has an unacknowledged quarantine: "
               ^ partition.partition_id)
          | Candidate.Requeued _ ->
            let* confirmation =
              Partition.confirm_ready ~base_path ~partition
            in
            let* (_ : Partition.exact_transition) =
              confirm_requeue_transition ~base_path confirmation
            in
            loop rest)
       | Partition.Ready, Some state
         when String.equal
                state.quarantine.partition_id
                partition.partition_id ->
         Error
           ("Ready partition is not the quarantined generation successor: "
            ^ partition.partition_id)
       | Partition.Ready, _
       | Partition.Running _, _
       | Partition.Completed _, _
       | Partition.Settled _, _ ->
         loop rest)
  in
  loop partitions
;;

let process_next_with_claim_ready_exact
      ~claim_ready_exact
      ~now
      ~worker_epoch
      ~base_path
      ~keeper_name
      ~prepare
      ~execute
  =
  let* candidates = Candidate.load_candidates ~base_path ~keeper_name in
  let* (_ : int) = Partition.ensure_roots ~base_path ~keeper_name candidates in
  let selected_generation_is_ready ~partition_id ~generation =
    let* partitions = Partition.load ~base_path ~keeper_name in
    Ok
      List.exists
        (fun (partition : Partition.t) ->
           String.equal partition.partition_id partition_id
           && Partition.Generation.equal partition.generation generation
           &&
           match partition.state with
           | Partition.Ready -> true
           | Partition.Running _
           | Partition.Completed _
           | Partition.Settled _
           | Partition.Blocked _ -> false)
        partitions
  in
  let process_selected prepared partition =
    let latest_partition : Partition.t ref = ref partition in
    try
      let* current_candidates =
        Candidate.load_candidates ~base_path ~keeper_name
      in
      process_claimed
        ~now
        ~worker_epoch
        ~base_path
        ~prepared
        ~execute
        latest_partition
        current_candidates
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      Log.Keeper.error
        "Board attention worker raised unexpectedly keeper=%s partition=%s: %s"
        keeper_name
        (!latest_partition).partition_id
        (Printexc.to_string exn);
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
        reason
  in
  let* selected =
    prepare_next_ready ~base_path ~keeper_name ~prepare candidates
  in
  match selected with
  | None -> Ok Idle
  | Some (partition_id, generation, prepared) ->
    let rec claim_selected attempts_remaining =
      let* claimed =
        claim_ready_exact
          ~now:(now ())
          ~worker_epoch
          ~base_path
          ~keeper_name
          ~partition_id
          ~generation
      in
      match claimed with
      | Some partition -> process_selected prepared partition
      | None ->
        let* remains_ready =
          selected_generation_is_ready ~partition_id ~generation
        in
        if remains_ready && attempts_remaining > 1
        then claim_selected (attempts_remaining - 1)
        else Ok Idle
    in
    claim_selected 3
;;

let process_next =
  process_next_with_claim_ready_exact
    ~claim_ready_exact:Partition.claim_ready_exact
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

let protect_process_recovery_release release =
  match Eio.Fiber.is_cancelled () with
  | true | false -> Eio.Cancel.protect release
  | exception Effect.Unhandled _ -> release ()
;;

let with_process_recovery_claim ~base_path ~keeper_name run =
  let claimed = claim_process_recovery ~base_path ~keeper_name in
  Fun.protect
    ~finally:(fun () ->
      if claimed
      then
        protect_process_recovery_release (fun () ->
          release_process_recovery ~base_path ~keeper_name))
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
  | Error detail ->
    observe_error ~base_path ~keeper_name detail;
    Error { stage = Registration; detail }
  | Ok registration ->
    Fun.protect
      ~finally:(fun () ->
        protect_process_recovery_release (fun () -> Wake.unregister registration))
      (fun () ->
         with_process_recovery_claim ~base_path ~keeper_name
         @@ fun owns_process_recovery ->
         let worker_epoch = Partition.Worker_epoch.generate () in
         let fail stage detail =
           observe_error ~base_path ~keeper_name detail;
           Error { stage; detail }
         in
         let startup =
           if not owns_process_recovery
           then Ok ()
           else
             let now = Time_compat.now () in
             let* (_ : int) =
               Partition.recover_for_process_start
                 ~now
                 ~base_path
                 ~keeper_name
             in
             let* () =
               reconcile_quarantines ~now ~base_path ~keeper_name
             in
             let* (_ : Keeper_registry.wakeup_outcome option) =
               replay_completed_owner_wake
                 ~base_path
                 ~keeper_name
                 ~wake_owner:owner_wake
             in
             Ok ()
         in
         match startup with
         | Error detail -> fail Process_start_recovery detail
         | Ok () ->
           let prepare = Exact_flow.prepare ~net in
           let execute = Exact_flow.execute ~clock in
           let rec await () =
             match Wake.await registration with
             | Wake.Registration_closed -> Ok ()
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
             | Error detail -> fail Durable_drain detail
           in
           (try drain () with
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | exn ->
              fail
                Control_loop
                ("Board attention worker control loop raised: "
                 ^ Printexc.to_string exn)))
;;

module For_testing = struct
  let process_next = process_next
  let process_next_with_claim_ready_exact = process_next_with_claim_ready_exact
  let drain_available = drain_available
  let replay_completed_owner_wake = replay_completed_owner_wake
  let with_process_recovery_claim = with_process_recovery_claim
end
;;
