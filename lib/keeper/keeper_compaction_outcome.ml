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
  }

type no_compaction_reason =
  | No_eligible_history
  | No_reducible_boundary
  | Invalid_structural_source
  | Exact_lane_unconfigured
  | Exact_execution_terminal of exact_execution_terminal

type no_compaction =
  { source : Keeper_checkpoint_ref.t
  ; reason : no_compaction_reason
  }

let exact_execution_terminal_cause_label = function
  | Exact_execution_failed -> "exact_execution_failed"
  | Exact_execution_cancelled -> "exact_execution_cancelled"
  | Domain_invalid_output -> "domain_invalid_output"
  | Compaction_produced_no_reduction -> "compaction_produced_no_reduction"
  | Compaction_increased_checkpoint -> "compaction_increased_checkpoint"
  | Invalid_structural_evidence -> "invalid_structural_evidence"
  | Invalid_structural_source_after_dispatch ->
    "invalid_structural_source_after_dispatch"
  | Commit_admission_unavailable -> "commit_admission_unavailable"
  | Lifecycle_transition_failed_after_dispatch ->
    "lifecycle_transition_failed_after_dispatch"
  | Checkpoint_source_changed -> "checkpoint_source_changed"
  | Checkpoint_persistence_failed -> "checkpoint_persistence_failed"
;;

let exact_execution_terminal_to_string terminal =
  Printf.sprintf
    "%s:slot_id=%s:call_id=%s:plan_fingerprint=%s:request_body_sha256=%s%s"
    (exact_execution_terminal_cause_label terminal.cause)
    terminal.slot_id
    terminal.call_id
    terminal.plan_fingerprint
    terminal.request_body_sha256
    (match terminal.detail with
     | Some detail when String.trim detail <> "" -> ":detail=" ^ String.trim detail
     | Some _ | None -> "")
;;

let no_compaction_reason_label = function
  | No_eligible_history -> "no_eligible_history"
  | No_reducible_boundary -> "no_reducible_boundary"
  | Invalid_structural_source -> "invalid_structural_source"
  | Exact_lane_unconfigured -> "exact_lane_unconfigured"
  | Exact_execution_terminal terminal ->
    exact_execution_terminal_cause_label terminal.cause
;;

let no_compaction_reason_to_string = function
  | Exact_execution_terminal terminal -> exact_execution_terminal_to_string terminal
  | reason -> no_compaction_reason_label reason
;;
