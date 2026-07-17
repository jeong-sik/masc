module Operation = Keeper_compaction_operation
module Reducer = Keeper_compaction_operation_reducer
module Store = Keeper_compaction_operation_store

type mode =
  | Startup_recovery
  | Steady_state

type operation_context =
  { operation_id : Operation.Operation_id.t
  ; request_cursor : Store.Cursor.t
  ; request : Operation.request
  }

type candidate_context =
  { operation : operation_context
  ; candidate : Operation.candidate
  }

type attempt_context =
  { operation : operation_context
  ; attempt_id : Operation.Attempt_id.t
  }

type action =
  | Start_attempt of operation_context
  | Terminalize_interrupted_attempt of attempt_context
  | Resume_candidate_commit of candidate_context
  | Reconcile_commit of candidate_context * Operation.reconciliation_reason
  | Wake_for_reinjection of candidate_context

type selection =
  | Selected of action
  | In_flight of attempt_context
  | Idle

type required_fact =
  | Attempt_id
  | Candidate_checkpoint
  | Evidence
  | Reconciliation_reason
  | Committed_checkpoint

type invariant_error =
  | Missing_fact of
      { operation_id : Operation.Operation_id.t
      ; phase : Reducer.phase
      ; fact : required_fact
      }
  | Committed_checkpoint_mismatch of
      { operation_id : Operation.Operation_id.t
      ; candidate_checkpoint : Keeper_checkpoint_ref.t
      ; committed_checkpoint : Keeper_checkpoint_ref.t
      }

let ( let* ) = Result.bind

let operation_context (entry : Store.operation_entry) =
  let snapshot = entry.snapshot in
  { operation_id = snapshot.operation_id
  ; request_cursor = entry.request_cursor
  ; request =
      { keeper_name = snapshot.keeper_name
      ; source_checkpoint = snapshot.source_checkpoint
      ; trigger = snapshot.trigger
      ; cause = snapshot.cause
      ; producer_invocation = snapshot.producer_invocation
      }
  }

let require (snapshot : Reducer.snapshot) fact = function
  | Some value -> Ok value
  | None ->
    Error
      (Missing_fact
         { operation_id = snapshot.operation_id; phase = snapshot.phase; fact })

let candidate_context entry =
  let snapshot = entry.Store.snapshot in
  let* attempt_id = require snapshot Attempt_id snapshot.attempt_id in
  let* candidate_checkpoint =
    require snapshot Candidate_checkpoint snapshot.candidate_checkpoint
  in
  let* evidence = require snapshot Evidence snapshot.evidence in
  Ok
    { operation = operation_context entry
    ; candidate =
        { attempt_id
        ; source_checkpoint = snapshot.source_checkpoint
        ; candidate_checkpoint
        ; evidence
        }
    }

let committed_candidate_context entry =
  let snapshot = entry.Store.snapshot in
  let* candidate = candidate_context entry in
  let* committed_checkpoint =
    require snapshot Committed_checkpoint snapshot.committed_checkpoint
  in
  if
    Keeper_checkpoint_ref.equal
      candidate.candidate.candidate_checkpoint
      committed_checkpoint
  then Ok candidate
  else
    Error
      (Committed_checkpoint_mismatch
         { operation_id = snapshot.operation_id
         ; candidate_checkpoint = candidate.candidate.candidate_checkpoint
         ; committed_checkpoint
         })

let select ~mode (replay : Store.replay) =
  let rec first = function
    | [] -> Ok Idle
    | entry :: rest ->
      let snapshot = entry.Store.snapshot in
      let operation = operation_context entry in
      (match snapshot.phase with
       | Reducer.No_compaction_decided
       | Reducer.Adopted
       | Reducer.Failed
       | Reducer.Superseded ->
         first rest
       | Reducer.Request_pending -> Ok (Selected (Start_attempt operation))
       | Reducer.Attempt_in_progress ->
         let* attempt_id = require snapshot Attempt_id snapshot.attempt_id in
         (match mode with
         | Startup_recovery ->
            Ok
              (Selected
                 (Terminalize_interrupted_attempt { operation; attempt_id }))
          | Steady_state -> Ok (In_flight { operation; attempt_id }))
       | Reducer.Candidate_pending_commit ->
         let* candidate = candidate_context entry in
         Ok (Selected (Resume_candidate_commit candidate))
       | Reducer.Reconciliation_pending ->
         let* candidate = candidate_context entry in
         let* reason =
           require
             snapshot
             Reconciliation_reason
             snapshot.reconciliation_reason
        in
        Ok (Selected (Reconcile_commit (candidate, reason)))
       | Reducer.Commit_complete ->
         let* candidate = committed_candidate_context entry in
         Ok (Selected (Wake_for_reinjection candidate)))
  in
  first replay.operations
