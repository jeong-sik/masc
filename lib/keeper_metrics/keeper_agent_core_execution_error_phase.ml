type t =
  | Runtime_exhausted
  | Terminal_non_exhaustion
  | Cycle_failed
  | Provider_context_overflow

let to_label = function
  | Runtime_exhausted -> "runtime_exhausted"
  | Terminal_non_exhaustion -> "terminal_non_exhaustion"
  | Cycle_failed -> "cycle_failed"
  | Provider_context_overflow -> "provider_context_overflow"
;;
