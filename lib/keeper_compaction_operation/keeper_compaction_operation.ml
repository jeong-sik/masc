module Operation_id = Keeper_compaction_operation_identity.Operation_id
module Attempt_id = Keeper_compaction_operation_identity.Attempt_id
module Cause = Keeper_compaction_operation_identity.Cause

type attempt_failure =
  | Pre_commit_failure of Cause.t
  | Candidate_not_installed of
      { cause : Cause.t
      ; observed_checkpoint : Keeper_checkpoint_ref.t
      }

type reconciliation_reason =
  | Commit_durability_unknown
  | Transaction_outcome_unknown

type request =
  { keeper_name : Keeper_id.Keeper_name.t
  ; source_checkpoint : Keeper_checkpoint_ref.t
  ; trigger : Compaction_trigger.t
  ; cause : Cause.t
  ; producer_invocation : Tool_invocation_ref.t option
  }

type candidate =
  { attempt_id : Attempt_id.t
  ; source_checkpoint : Keeper_checkpoint_ref.t
  ; candidate_checkpoint : Keeper_checkpoint_ref.t
  ; evidence : Keeper_compaction_evidence.t
  }

type no_compaction =
  { attempt_id : Attempt_id.t
  ; source_checkpoint : Keeper_checkpoint_ref.t
  ; evidence : Keeper_compaction_evidence.preserved
  }

type supersession =
  { attempt_id : Attempt_id.t
  ; observed_checkpoint : Keeper_checkpoint_ref.t option
  }

type event_view =
  | Requested of request
  | Attempt_started of Attempt_id.t
  | Candidate_prepared of candidate
  | Attempt_failed of Attempt_id.t * attempt_failure
  | Commit_reconciliation_required of candidate * reconciliation_reason
  | Source_superseded of supersession
  | Compacted of candidate
  | No_compaction of no_compaction
  | Reinjected of Keeper_checkpoint_ref.t * Ids.Turn_ref.t

type event =
  { operation_id : Operation_id.t
  ; view : event_view
  }

let operation_id event = event.operation_id
let view event = event.view

let candidate ~attempt_id ~source_checkpoint ~candidate_checkpoint ~evidence =
  { attempt_id; source_checkpoint; candidate_checkpoint; evidence }
;;

let requested ~operation_id ~keeper_name ~source_checkpoint ~trigger ~cause
    ~producer_invocation =
  { operation_id
  ; view =
      Requested
        { keeper_name; source_checkpoint; trigger; cause; producer_invocation }
  }
;;

let attempt_started ~operation_id ~attempt_id =
  { operation_id; view = Attempt_started attempt_id }
;;

let candidate_prepared ~operation_id ~attempt_id ~source_checkpoint
    ~candidate_checkpoint ~evidence =
  { operation_id
  ; view =
      Candidate_prepared
        (candidate ~attempt_id ~source_checkpoint ~candidate_checkpoint ~evidence)
  }
;;

let attempt_failed ~operation_id ~attempt_id ~failure =
  { operation_id; view = Attempt_failed (attempt_id, failure) }
;;

let commit_reconciliation_required ~operation_id ~attempt_id ~source_checkpoint
    ~candidate_checkpoint ~evidence ~reason =
  { operation_id
  ; view =
      Commit_reconciliation_required
        (candidate ~attempt_id ~source_checkpoint ~candidate_checkpoint ~evidence, reason)
  }
;;

let source_superseded ~operation_id ~attempt_id ~observed_checkpoint =
  { operation_id
  ; view = Source_superseded { attempt_id; observed_checkpoint }
  }
;;

let compacted ~operation_id ~attempt_id ~source_checkpoint
    ~committed_checkpoint ~evidence =
  { operation_id
  ; view =
      Compacted
        (candidate
           ~attempt_id
           ~source_checkpoint
           ~candidate_checkpoint:committed_checkpoint
           ~evidence)
  }
;;

let no_compaction ~operation_id ~attempt_id ~source_checkpoint ~evidence =
  { operation_id
  ; view = No_compaction { attempt_id; source_checkpoint; evidence }
  }
;;

let reinjected ~operation_id ~adopted_checkpoint ~adopting_turn =
  { operation_id; view = Reinjected (adopted_checkpoint, adopting_turn) }
;;
