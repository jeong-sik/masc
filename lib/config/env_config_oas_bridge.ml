(** Typed attribution for the remaining trusted MASC -> OAS bridge callers.

    This module deliberately owns no timeout configuration. LLM cancellation is
    enforced once, at the OAS Provider transport boundary. *)

type caller =
  | Anti_rationalization
  | Operator_judge
  | Unknown of string

let caller_key = function
  | Anti_rationalization -> "anti_rationalization"
  | Operator_judge -> "operator_judge"
  | Unknown caller -> caller
;;
