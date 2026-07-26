(* RFC-0042 PR-1: closed sum type for keeper turn terminal code.

   See [.mli] for the public contract. This file holds the type
   definition and the wire-format serialisation. *)

type t =
  | Healthy
  | Stale_termination_storm
  | Heartbeat_failures
  | Turn_failures
  | Provider_runtime_error of string
  | Fiber_unresolved
  | Turn_overflow_failure
  | Operator_interrupt
  | Exception_unhandled of string
  | Sdk_error of string

let to_wire = function
  | Healthy -> "healthy"
  | Stale_termination_storm -> "stale_termination_storm"
  | Heartbeat_failures -> "heartbeat_failures"
  | Turn_failures -> "turn_failures"
  | Provider_runtime_error code -> code
  | Fiber_unresolved -> "fiber_unresolved"
  | Turn_overflow_failure -> "turn_overflow_failure"
  | Operator_interrupt -> "operator_interrupt"
  | Exception_unhandled _ -> "exception"
  | Sdk_error wire -> wire
;;

let of_wire_exact = function
  | "healthy" -> Some Healthy
  | "stale_termination_storm" -> Some Stale_termination_storm
  | "heartbeat_failures" -> Some Heartbeat_failures
  | "turn_failures" -> Some Turn_failures
  | "fiber_unresolved" -> Some Fiber_unresolved
  | "turn_overflow_failure" -> Some Turn_overflow_failure
  | "operator_interrupt" -> Some Operator_interrupt
  | _ -> None
;;

let of_sdk_error_wire wire = Sdk_error wire
