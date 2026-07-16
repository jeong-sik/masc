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

type provider_delivery_ref =
  | Event_queue_lease of int64
  | Keeper_chat of Keeper_chat_delivery_identity.delivery_key
  | Keeper_turn of Ids.Turn_ref.t

type provider_delivery_ref_error =
  | Non_positive_event_queue_lease_sequence of int64

type producer_ref =
  | Tool_invocation of Tool_invocation_ref.t
  | Provider_overflow of
      { source_checkpoint : Keeper_checkpoint_ref.t
      ; source_delivery : provider_delivery_ref
      }

type request =
  { keeper_name : Keeper_id.Keeper_name.t
  ; source_checkpoint : Keeper_checkpoint_ref.t
  ; trigger : Compaction_trigger.t
  ; cause : Cause.t
  ; producer : producer_ref option
  }

type candidate =
  { attempt_id : Attempt_id.t
  ; source_checkpoint : Keeper_checkpoint_ref.t
  ; candidate_checkpoint : Keeper_checkpoint_ref.t
  ; evidence : Keeper_compaction_evidence.t
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
  | Reinjected of Keeper_checkpoint_ref.t * Ids.Turn_ref.t

type event =
  { operation_id : Operation_id.t
  ; view : event_view
  }

let operation_id event = event.operation_id
let view event = event.view

let event_queue_lease_delivery_ref ~sequence =
  if Int64.compare sequence 1L < 0
  then Error (Non_positive_event_queue_lease_sequence sequence)
  else Ok (Event_queue_lease sequence)
;;

let keeper_chat_delivery_ref delivery = Keeper_chat delivery
let keeper_turn_delivery_ref turn = Keeper_turn turn

let provider_delivery_ref_to_yojson = function
  | Event_queue_lease sequence ->
    `Assoc
      [ "kind", `String "event_queue_lease"
      ; "sequence", `String (Int64.to_string sequence)
      ]
  | Keeper_chat delivery ->
    `Assoc
      [ "kind", `String "keeper_chat"
      ; ( "delivery"
        , Keeper_chat_delivery_identity.delivery_key_to_yojson delivery )
      ]
  | Keeper_turn turn ->
    `Assoc
      [ "kind", `String "keeper_turn"
      ; "turn", Ids.Turn_ref.to_yojson turn
      ]
;;

let tool_invocation_producer_ref invocation = Tool_invocation invocation

let provider_overflow_producer_ref ~source_checkpoint ~source_delivery =
  Provider_overflow { source_checkpoint; source_delivery }
;;

let provider_delivery_ref_equal left right =
  match left, right with
  | Event_queue_lease left, Event_queue_lease right -> Int64.equal left right
  | Keeper_chat left, Keeper_chat right ->
    Keeper_chat_delivery_identity.delivery_key_equal left right
  | Keeper_turn left, Keeper_turn right -> Ids.Turn_ref.equal left right
  | Event_queue_lease _, (Keeper_chat _ | Keeper_turn _)
  | Keeper_chat _, (Event_queue_lease _ | Keeper_turn _)
  | Keeper_turn _, (Event_queue_lease _ | Keeper_chat _) -> false
;;

let producer_ref_equal left right =
  match left, right with
  | Tool_invocation left, Tool_invocation right ->
    Tool_invocation_ref.equal left right
  | ( Provider_overflow left
    , Provider_overflow right ) ->
    Keeper_checkpoint_ref.equal left.source_checkpoint right.source_checkpoint
    && provider_delivery_ref_equal
         left.source_delivery
         right.source_delivery
  | Tool_invocation _, Provider_overflow _
  | Provider_overflow _, Tool_invocation _ -> false
;;

let candidate ~attempt_id ~source_checkpoint ~candidate_checkpoint ~evidence =
  { attempt_id; source_checkpoint; candidate_checkpoint; evidence }
;;

let requested ~operation_id ~keeper_name ~source_checkpoint ~trigger ~cause
    ~producer =
  { operation_id
  ; view =
      Requested
        { keeper_name; source_checkpoint; trigger; cause; producer }
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

let reinjected ~operation_id ~adopted_checkpoint ~adopting_turn =
  { operation_id; view = Reinjected (adopted_checkpoint, adopting_turn) }
;;
