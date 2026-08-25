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
  ; detail : string option
        (** The provider's own account of the failure, when the terminal came
            from a flow that carries one. The four identifiers above say which
            call failed; they cannot say why, so a compaction that lost 470
            seconds on a slot healthy everywhere else left no answer anywhere.
            [None] where the terminal has no such account — the rendering then
            is exactly what it was before this field existed. *)
  }

type no_compaction_reason =
  | No_eligible_history
  | No_reducible_boundary
  | Invalid_structural_source
  | Exact_lane_unconfigured
      (** The configured runtime has no exact-output lane for compaction. This
          is an operator-actionable precondition failure tied to the durable
          checkpoint source, not a stochastic provider failure. *)
  | Exact_execution_terminal of exact_execution_terminal
      (** Typed outcome of one completed exact-output execution. The retained
          AGENT_CORE slot/call identity is evidence only; it creates no second claim,
          durable replay barrier, or commit authority. *)

type no_compaction =
  { source : Keeper_checkpoint_ref.t
  ; reason : no_compaction_reason
  }

val no_compaction_reason_label : no_compaction_reason -> string
val no_compaction_reason_to_string : no_compaction_reason -> string
val exact_execution_terminal_cause_label : exact_execution_terminal_cause -> string
val exact_execution_terminal_to_string : exact_execution_terminal -> string
