module Operation = Keeper_compaction_operation

type phase =
  | Request_pending
  | Attempt_in_progress
  | Candidate_pending_commit
  | Reconciliation_pending
  | Commit_complete
  | Adopted
  | Superseded

type progress =
  | Pending
  | Running of Operation.Attempt_id.t
  | Prepared of Operation.candidate
  | Reconciling of Operation.candidate * Operation.reconciliation_reason
  | Committed of Operation.candidate
  | Adopted_state of
      Operation.candidate * Keeper_checkpoint_ref.t * Ids.Turn_ref.t

  | Superseded_state of superseded_state

and superseded_state =
  { attempt_id : Operation.Attempt_id.t
  ; candidate : Operation.candidate option
  ; committed : bool
  ; observed_checkpoint : Keeper_checkpoint_ref.t option
  }

type state =
  { operation_id : Operation.Operation_id.t
  ; request : Operation.request
  ; progress : progress
  ; closed_attempts : Operation.Attempt_id.t list
  }

type snapshot =
  { operation_id : Operation.Operation_id.t
  ; keeper_name : Keeper_id.Keeper_name.t
  ; source_checkpoint : Keeper_checkpoint_ref.t
  ; trigger : Compaction_trigger.t
  ; cause : Operation.Cause.t
  ; producer_invocation : Tool_invocation_ref.t option
  ; phase : phase
  ; attempt_id : Operation.Attempt_id.t option
  ; candidate_checkpoint : Keeper_checkpoint_ref.t option
  ; evidence : Keeper_compaction_evidence.t option
  ; reconciliation_reason : Operation.reconciliation_reason option
  ; committed_checkpoint : Keeper_checkpoint_ref.t option
  ; adopted_checkpoint : Keeper_checkpoint_ref.t option
  ; adopting_turn : Ids.Turn_ref.t option
  ; superseded_by_checkpoint : Keeper_checkpoint_ref.t option
  }

type transition_error =
  | Invalid_transition of phase option
  | Operation_mismatch
  | Attempt_mismatch
  | Attempt_reused
  | Source_mismatch
  | Candidate_mismatch
  | Reinjection_identity_mismatch
  | Supersession_not_observed
  | Supersession_candidate_installed
  | Supersession_trace_mismatch

let phase state =
  match state.progress with
  | Pending -> Request_pending
  | Running _ -> Attempt_in_progress
  | Prepared _ -> Candidate_pending_commit
  | Reconciling _ -> Reconciliation_pending
  | Committed _ -> Commit_complete
  | Adopted_state _ -> Adopted
  | Superseded_state _ -> Superseded
;;

let projection = function
  | Pending -> None, None, None, None, None, None, None, None
  | Running attempt ->
    Some attempt, None, None, None, None, None, None, None
  | Prepared value ->
    Some value.attempt_id, Some value.candidate_checkpoint, Some value.evidence,
    None, None, None, None, None
  | Reconciling (value, reason) ->
    Some value.attempt_id, Some value.candidate_checkpoint, Some value.evidence,
    Some reason, None, None, None, None
  | Committed value ->
    Some value.attempt_id, Some value.candidate_checkpoint, Some value.evidence,
    None, Some value.candidate_checkpoint, None, None, None
  | Adopted_state (value, checkpoint, turn) ->
    Some value.attempt_id, Some value.candidate_checkpoint, Some value.evidence,
    None, Some value.candidate_checkpoint, Some checkpoint, Some turn, None
  | Superseded_state superseded ->
    let candidate_checkpoint, evidence =
      match superseded.candidate with
      | Some value -> Some value.candidate_checkpoint, Some value.evidence
      | None -> None, None
    in
    let committed_checkpoint =
      if superseded.committed then candidate_checkpoint else None
    in
    Some superseded.attempt_id, candidate_checkpoint, evidence, None,
    committed_checkpoint, None, None, superseded.observed_checkpoint
;;

let snapshot state =
  let attempt_id, candidate_checkpoint, evidence, reconciliation_reason,
      committed_checkpoint, adopted_checkpoint, adopting_turn,
      superseded_by_checkpoint =
    projection state.progress
  in
  { operation_id = state.operation_id
  ; keeper_name = state.request.keeper_name
  ; source_checkpoint = state.request.source_checkpoint
  ; trigger = state.request.trigger
  ; cause = state.request.cause
  ; producer_invocation = state.request.producer_invocation
  ; phase = phase state
  ; attempt_id
  ; candidate_checkpoint
  ; evidence
  ; reconciliation_reason
  ; committed_checkpoint
  ; adopted_checkpoint
  ; adopting_turn
  ; superseded_by_checkpoint
  }
;;

let same_candidate
      (expected : Operation.candidate)
      (actual : Operation.candidate)
  =
  if not (Operation.Attempt_id.equal expected.attempt_id actual.attempt_id)
  then Error Attempt_mismatch
  else if
    not
      (Keeper_checkpoint_ref.equal
         expected.source_checkpoint
         actual.source_checkpoint)
  then Error Source_mismatch
  else if
    not
      (Keeper_checkpoint_ref.equal
         expected.candidate_checkpoint
         actual.candidate_checkpoint
       && expected.evidence = actual.evidence)
  then Error Candidate_mismatch
  else Ok ()
;;

let close_attempt state attempt_id =
  { state with progress = Pending; closed_attempts = attempt_id :: state.closed_attempts }
;;

let validate_supersession
      (state : state)
      (candidate : Operation.candidate option)
      ~source_may_match
      (observed_checkpoint : Keeper_checkpoint_ref.t option)
  =
  match observed_checkpoint with
  | None -> Ok ()
  | Some observed_checkpoint ->
    if
      not
        (Keeper_id.Trace_id.equal
           state.request.source_checkpoint.trace_id
           observed_checkpoint.trace_id)
    then Error Supersession_trace_mismatch
    else if
      not source_may_match
      &&
      Keeper_checkpoint_ref.equal
        state.request.source_checkpoint
        observed_checkpoint
    then Error Supersession_not_observed
    else
      (match candidate with
       | Some value
         when Keeper_checkpoint_ref.equal
                value.candidate_checkpoint
                observed_checkpoint ->
         Error Supersession_candidate_installed
       | Some _ | None -> Ok ())
;;

let apply current event =
  let invalid state = Error (Invalid_transition (Option.map phase state)) in
  match current, Operation.view event with
  | None, Operation.Requested request ->
    Ok
      { operation_id = Operation.operation_id event
      ; request
      ; progress = Pending
      ; closed_attempts = []
      }
  | None, _ | Some _, Operation.Requested _ -> invalid current
  | Some state, view ->
    if not (Operation.Operation_id.equal state.operation_id (Operation.operation_id event))
    then Error Operation_mismatch
    else
      match state.progress, view with
      | Pending, Operation.Attempt_started attempt_id ->
        if List.exists (Operation.Attempt_id.equal attempt_id) state.closed_attempts
        then Error Attempt_reused
        else Ok { state with progress = Running attempt_id }
      | Running expected, Operation.Candidate_prepared value ->
        if not (Operation.Attempt_id.equal expected value.attempt_id)
        then Error Attempt_mismatch
        else if
          not
            (Keeper_checkpoint_ref.equal
               state.request.source_checkpoint
               value.source_checkpoint)
        then Error Source_mismatch
        else if
          Keeper_checkpoint_ref.equal
            value.source_checkpoint
            value.candidate_checkpoint
        then Error Candidate_mismatch
        else Ok { state with progress = Prepared value }
      | Running expected,
        Operation.Attempt_failed (actual, Operation.Pre_commit_failure _) ->
        if Operation.Attempt_id.equal expected actual
        then Ok (close_attempt state actual)
        else Error Attempt_mismatch
      | (Prepared expected | Reconciling (expected, _)),
        Operation.Attempt_failed
          ( actual
          , Operation.Candidate_not_installed { observed_checkpoint; _ } ) ->
        if not (Operation.Attempt_id.equal expected.attempt_id actual)
        then Error Attempt_mismatch
        else if
          not
            (Keeper_checkpoint_ref.equal
               state.request.source_checkpoint
               observed_checkpoint)
        then Error Source_mismatch
        else Ok (close_attempt state actual)
      | Prepared expected,
        Operation.Commit_reconciliation_required (actual, reason) ->
        same_candidate expected actual
        |> Result.map (fun () ->
          { state with progress = Reconciling (expected, reason) })
      | Running expected, Operation.Source_superseded supersession ->
        if not (Operation.Attempt_id.equal expected supersession.attempt_id)
        then Error Attempt_mismatch
        else
          validate_supersession
            state
            None
            ~source_may_match:false
            supersession.observed_checkpoint
          |> Result.map (fun () ->
            { state with
              progress =
                Superseded_state
                  { attempt_id = expected
                  ; candidate = None
                  ; committed = false
                  ; observed_checkpoint = supersession.observed_checkpoint
                  }
            })
      | (Prepared expected | Reconciling (expected, _)),
        Operation.Source_superseded supersession ->
        if
          not
            (Operation.Attempt_id.equal
               expected.attempt_id
               supersession.attempt_id)
        then Error Attempt_mismatch
        else
          validate_supersession
            state
            (Some expected)
            ~source_may_match:false
            supersession.observed_checkpoint
          |> Result.map (fun () ->
            { state with
              progress =
                Superseded_state
                  { attempt_id = expected.attempt_id
                  ; candidate = Some expected
                  ; committed = false
                  ; observed_checkpoint = supersession.observed_checkpoint
                  }
            })
      | (Prepared expected | Reconciling (expected, _)), Operation.Compacted actual ->
        same_candidate expected actual
        |> Result.map (fun () -> { state with progress = Committed expected })
      | Committed expected, Operation.Source_superseded supersession ->
        if
          not
            (Operation.Attempt_id.equal
               expected.attempt_id
               supersession.attempt_id)
        then Error Attempt_mismatch
        else
          validate_supersession
            state
            (Some expected)
            ~source_may_match:true
            supersession.observed_checkpoint
          |> Result.map (fun () ->
            { state with
              progress =
                Superseded_state
                  { attempt_id = expected.attempt_id
                  ; candidate = Some expected
                  ; committed = true
                  ; observed_checkpoint = supersession.observed_checkpoint
                  }
            })
      | Committed value, Operation.Reinjected (checkpoint, turn) ->
        let trace =
          Keeper_id.Trace_id.to_string value.candidate_checkpoint.trace_id
        in
        if
          Keeper_checkpoint_ref.equal value.candidate_checkpoint checkpoint
          && String.equal trace (Ids.Turn_ref.trace_id turn)
        then Ok { state with progress = Adopted_state (value, checkpoint, turn) }
        else Error Reinjection_identity_mismatch
      | _ -> invalid current
;;

let fold events =
  let rec loop state = function
    | [] ->
      (match state with
       | Some value -> Ok value
       | None -> Error (Invalid_transition None))
    | event :: rest ->
      (match apply state event with
       | Error _ as error -> error
       | Ok next -> loop (Some next) rest)
  in
  loop None events
;;
