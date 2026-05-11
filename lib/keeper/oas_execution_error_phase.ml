type t =
  | Cascade_exhausted
  | Terminal_non_exhaustion
  | Recoverable_cascade_transient
  | Cycle_failed
  | Persistent_escalation
  | Resilience_audit_store
  | Overflow_retry_oas_load

let to_label = function
  | Cascade_exhausted -> "cascade_exhausted"
  | Terminal_non_exhaustion -> "terminal_non_exhaustion"
  | Recoverable_cascade_transient -> "recoverable_cascade_transient"
  | Cycle_failed -> "cycle_failed"
  | Persistent_escalation -> "persistent_escalation"
  | Resilience_audit_store -> "resilience_audit_store"
  | Overflow_retry_oas_load -> "overflow_retry_oas_load"
;;
