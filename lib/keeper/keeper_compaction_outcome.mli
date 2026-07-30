(** In-process outcomes for one exact compaction attempt.

    These values belong to the compaction flow. They are not event-queue
    transitions and are not persisted by the event queue. *)

type exact_execution_terminal_cause =
  | Exact_execution_failed
  | Exact_execution_cancelled
  | Domain_invalid_output
  | Compaction_produced_no_reduction
  | Compaction_increased_checkpoint
  | Invalid_structural_evidence
  | Invalid_structural_source_after_dispatch
  | Commit_admission_unavailable
  | Lifecycle_transition_failed_after_dispatch
  | Checkpoint_source_changed
  | Checkpoint_persistence_failed

type exact_execution_terminal =
  { cause : exact_execution_terminal_cause
  ; slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  }

type no_compaction_reason =
  | No_eligible_history
  | Invalid_structural_source
  | Exact_lane_unconfigured
      (** The configured runtime has no exact-output lane for compaction. This
          is an operator-actionable precondition failure tied to the durable
          checkpoint source, not a stochastic provider failure. *)
  | Exact_execution_terminal of exact_execution_terminal
      (** Exact-output execution is affine and terminal. The typed cause plus
          OAS slot/call identity forbids a second attempt for this source. *)

type no_compaction =
  { source : Keeper_checkpoint_ref.t
  ; reason : no_compaction_reason
  }

val no_compaction_reason_label : no_compaction_reason -> string
val no_compaction_reason_to_string : no_compaction_reason -> string
val exact_execution_terminal_cause_label : exact_execution_terminal_cause -> string
val exact_execution_terminal_to_string : exact_execution_terminal -> string
