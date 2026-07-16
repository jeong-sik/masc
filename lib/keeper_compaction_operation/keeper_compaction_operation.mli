(** Typed immutable facts for one Keeper compaction operation. *)

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

type provider_delivery_ref = private
  | Event_queue_lease of int64
  | Keeper_chat of Keeper_chat_delivery_identity.delivery_key
  | Keeper_turn of Ids.Turn_ref.t

type provider_delivery_ref_error =
  | Non_positive_event_queue_lease_sequence of int64

type producer_ref = private
  | Tool_invocation of Tool_invocation_ref.t
  | Provider_overflow of
      { source_checkpoint : Keeper_checkpoint_ref.t
      ; source_delivery : provider_delivery_ref
      }

val event_queue_lease_delivery_ref :
  sequence:int64 ->
  (provider_delivery_ref, provider_delivery_ref_error) result
val keeper_chat_delivery_ref :
  Keeper_chat_delivery_identity.delivery_key -> provider_delivery_ref
val keeper_turn_delivery_ref : Ids.Turn_ref.t -> provider_delivery_ref
val provider_delivery_ref_to_yojson : provider_delivery_ref -> Yojson.Safe.t

val tool_invocation_producer_ref : Tool_invocation_ref.t -> producer_ref
val provider_overflow_producer_ref :
  source_checkpoint:Keeper_checkpoint_ref.t ->
  source_delivery:provider_delivery_ref ->
  producer_ref

val producer_ref_equal : producer_ref -> producer_ref -> bool

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

type event
val operation_id : event -> Operation_id.t
val view : event -> event_view

val requested :
  operation_id:Operation_id.t ->
  keeper_name:Keeper_id.Keeper_name.t ->
  source_checkpoint:Keeper_checkpoint_ref.t ->
  trigger:Compaction_trigger.t ->
  cause:Cause.t ->
  producer:producer_ref option ->
  event
val attempt_started : operation_id:Operation_id.t -> attempt_id:Attempt_id.t -> event
val candidate_prepared :
  operation_id:Operation_id.t ->
  attempt_id:Attempt_id.t ->
  source_checkpoint:Keeper_checkpoint_ref.t ->
  candidate_checkpoint:Keeper_checkpoint_ref.t ->
  evidence:Keeper_compaction_evidence.t ->
  event
val attempt_failed :
  operation_id:Operation_id.t ->
  attempt_id:Attempt_id.t ->
  failure:attempt_failure ->
  event
val commit_reconciliation_required :
  operation_id:Operation_id.t ->
  attempt_id:Attempt_id.t ->
  source_checkpoint:Keeper_checkpoint_ref.t ->
  candidate_checkpoint:Keeper_checkpoint_ref.t ->
  evidence:Keeper_compaction_evidence.t ->
  reason:reconciliation_reason ->
  event
val source_superseded :
  operation_id:Operation_id.t ->
  attempt_id:Attempt_id.t ->
  observed_checkpoint:Keeper_checkpoint_ref.t option ->
  event
val compacted :
  operation_id:Operation_id.t ->
  attempt_id:Attempt_id.t ->
  source_checkpoint:Keeper_checkpoint_ref.t ->
  committed_checkpoint:Keeper_checkpoint_ref.t ->
  evidence:Keeper_compaction_evidence.t ->
  event
val reinjected :
  operation_id:Operation_id.t ->
  adopted_checkpoint:Keeper_checkpoint_ref.t ->
  adopting_turn:Ids.Turn_ref.t ->
  event
