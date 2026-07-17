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

type event
val operation_id : event -> Operation_id.t
val view : event -> event_view

val requested :
  operation_id:Operation_id.t ->
  keeper_name:Keeper_id.Keeper_name.t ->
  source_checkpoint:Keeper_checkpoint_ref.t ->
  trigger:Compaction_trigger.t ->
  cause:Cause.t ->
  producer_invocation:Tool_invocation_ref.t option ->
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
val no_compaction :
  operation_id:Operation_id.t ->
  attempt_id:Attempt_id.t ->
  source_checkpoint:Keeper_checkpoint_ref.t ->
  evidence:Keeper_compaction_evidence.preserved ->
  event
val reinjected :
  operation_id:Operation_id.t ->
  adopted_checkpoint:Keeper_checkpoint_ref.t ->
  adopting_turn:Ids.Turn_ref.t ->
  event
