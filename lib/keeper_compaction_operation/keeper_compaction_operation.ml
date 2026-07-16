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

type producer_ref =
  | Tool_invocation of Tool_invocation_ref.t
  | Provider_overflow of
      { source_checkpoint : Keeper_checkpoint_ref.t
      ; source_delivery_sha256 : string
      }

type producer_ref_error =
  | Invalid_source_delivery_sha256_length of int
  | Invalid_source_delivery_sha256_character of
      { index : int
      ; found : char
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

let tool_invocation_producer_ref invocation = Tool_invocation invocation

let validate_source_delivery_sha256 value =
  let length = String.length value in
  if length <> 64
  then Error (Invalid_source_delivery_sha256_length length)
  else
    let rec loop index =
      if index = length
      then Ok ()
      else
        match value.[index] with
        | '0' .. '9' | 'a' .. 'f' -> loop (index + 1)
        | found ->
          Error
            (Invalid_source_delivery_sha256_character { index; found })
    in
    loop 0
;;

let provider_overflow_producer_ref_of_persisted
      ~source_checkpoint
      ~source_delivery_sha256
  =
  validate_source_delivery_sha256 source_delivery_sha256
  |> Result.map (fun () ->
    Provider_overflow { source_checkpoint; source_delivery_sha256 })
;;

let provider_overflow_producer_ref ~source_checkpoint ~source_delivery_identity =
  let source_delivery_sha256 =
    Digestif.SHA256.(digest_string source_delivery_identity |> to_hex)
  in
  Provider_overflow { source_checkpoint; source_delivery_sha256 }
;;

let producer_ref_equal left right =
  match left, right with
  | Tool_invocation left, Tool_invocation right ->
    Tool_invocation_ref.equal left right
  | ( Provider_overflow left
    , Provider_overflow right ) ->
    Keeper_checkpoint_ref.equal left.source_checkpoint right.source_checkpoint
    && String.equal
         left.source_delivery_sha256
         right.source_delivery_sha256
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
