(** Pure replay reducer for one compaction operation. *)

module Operation = Keeper_compaction_operation

type phase =
  | Request_pending
  | Attempt_in_progress
  | Candidate_pending_commit
  | Reconciliation_pending
  | Commit_complete
  | Adopted
  | Failed  (** Terminal; another objective requires a new operation. *)
  | Superseded

type state
type snapshot =
  { operation_id : Operation.Operation_id.t
  ; keeper_name : Keeper_id.Keeper_name.t
  ; source_checkpoint : Keeper_checkpoint_ref.t
  ; trigger : Compaction_trigger.t
  ; cause : Operation.Cause.t
  ; producer : Operation.producer_ref option
  ; phase : phase
  ; attempt_id : Operation.Attempt_id.t option
  ; candidate_checkpoint : Keeper_checkpoint_ref.t option
  ; evidence : Keeper_compaction_evidence.t option
  ; reconciliation_reason : Operation.reconciliation_reason option
  ; committed_checkpoint : Keeper_checkpoint_ref.t option
  ; adopted_checkpoint : Keeper_checkpoint_ref.t option
  ; adopting_turn : Ids.Turn_ref.t option
  ; failure : Operation.attempt_failure option
  ; superseded_by_checkpoint : Keeper_checkpoint_ref.t option
  }

type transition_error =
  | Invalid_transition of phase option
  | Provider_overflow_producer_required
  | Producer_trigger_mismatch
  | Producer_source_mismatch
  | Operation_mismatch
  | Attempt_mismatch
  | Source_mismatch
  | Candidate_mismatch
  | Reinjection_identity_mismatch
  | Supersession_not_observed
  | Supersession_candidate_installed
  | Supersession_trace_mismatch

val phase : state -> phase
val snapshot : state -> snapshot
val apply : state option -> Operation.event -> (state, transition_error) result
val fold : Operation.event list -> (state, transition_error) result
