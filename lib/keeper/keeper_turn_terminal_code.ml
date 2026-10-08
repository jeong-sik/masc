(* RFC-0042 PR-1: closed sum type for keeper turn terminal code.

   See [.mli] for the public contract. This file holds the type
   definition and the wire-format serialisation. *)

type timeout_source =
  | Agent_core_api
  | Agent_core_provider

(* Typed observation derived where the original agent-core error is still
   in hand, carried alongside the verbatim wire (RFC-0371 §6.1(3)). [None]
   on values rehydrated from persisted wire strings — their consumers keep
   the string parse as the persistence-boundary fallback. *)
type agent_core_timeout =
  { source : timeout_source
  ; phase : Llm_provider.Http_client.timeout_phase option
  }

type t =
  | Healthy
  | Provider_runtime_error of string
  | Fiber_unresolved
  | Operator_interrupt
  | Agent_core_error of
      { wire : string
      ; timeout : agent_core_timeout option
      }

let to_wire = function
  | Healthy -> "healthy"
  | Provider_runtime_error code -> code
  | Fiber_unresolved -> "fiber_unresolved"
  | Operator_interrupt -> "operator_interrupt"
  | Agent_core_error { wire; _ } -> wire
;;

let of_wire_exact = function
  | "healthy" -> Some Healthy
  | "fiber_unresolved" -> Some Fiber_unresolved
  | "operator_interrupt" -> Some Operator_interrupt
  | _ -> None
;;

let of_core_error_wire wire = Agent_core_error { wire; timeout = None }
let of_core_error ~wire ~timeout = Agent_core_error { wire; timeout }
