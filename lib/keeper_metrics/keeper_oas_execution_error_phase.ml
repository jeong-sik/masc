type t =
  | Turn_start
  | Runtime_exhausted
  | Terminal_non_exhaustion
  | Cycle_failed
  | Persistent_escalation
  | Resilience_audit_store
  | Overflow_retry_oas_load
  | Context_overflow_after_oas_retry

let to_label = function
  | Turn_start -> "turn_start"
  | Runtime_exhausted -> "runtime_exhausted"
  | Terminal_non_exhaustion -> "terminal_non_exhaustion"
  | Cycle_failed -> "cycle_failed"
  | Persistent_escalation -> "persistent_escalation"
  | Resilience_audit_store -> "resilience_audit_store"
  | Overflow_retry_oas_load -> "overflow_retry_oas_load"
  | Context_overflow_after_oas_retry -> "context_overflow_after_oas_retry"
;;
