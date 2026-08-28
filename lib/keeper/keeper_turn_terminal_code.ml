(* RFC-0042 PR-1: closed sum type for keeper turn terminal code.

   See [.mli] for the public contract. This file holds the type
   definition and the wire-format serialisation. *)

(* Typed observation derived where the original agent-core error is still
   in hand, carried alongside the verbatim wire (RFC-0371 §6.1(3)). [None]
   on values rehydrated from persisted wire strings — their consumers keep
   the string parse as the persistence-boundary fallback. *)
type agent_core_timeout =
  { phase : Llm_provider.Http_client.timeout_phase option }

type t =
  | Healthy
  | Stale_termination_storm
  | Provider_runtime_error of string
  | Fiber_unresolved
  | Turn_overflow_failure
  | Operator_interrupt
  | Exception_unhandled of string
  | Agent_core_error of
      { wire : string
      ; timeout : agent_core_timeout option
      }

let to_wire = function
  | Healthy -> "healthy"
  | Stale_termination_storm -> "stale_termination_storm"
  | Provider_runtime_error code -> code
  | Fiber_unresolved -> "fiber_unresolved"
  | Turn_overflow_failure -> "turn_overflow_failure"
  | Operator_interrupt -> "operator_interrupt"
  | Exception_unhandled _ -> "exception"
  | Agent_core_error { wire; _ } -> wire
;;

let of_wire_exact = function
  | "healthy" -> Some Healthy
  | "stale_termination_storm" -> Some Stale_termination_storm
  | "fiber_unresolved" -> Some Fiber_unresolved
  | "turn_overflow_failure" -> Some Turn_overflow_failure
  | "operator_interrupt" -> Some Operator_interrupt
  | _ -> None
;;

let of_core_error_wire wire = Agent_core_error { wire; timeout = None }
let of_core_error ~wire ~timeout = Agent_core_error { wire; timeout }
