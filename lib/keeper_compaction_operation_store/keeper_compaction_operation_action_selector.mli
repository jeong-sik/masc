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

val select
  :  mode:mode
  -> Store.replay
  -> (selection, invariant_error) result
