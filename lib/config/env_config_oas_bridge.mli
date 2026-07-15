(** Typed attribution for trusted MASC -> OAS bridge callers.

    Despite the historical module name, this interface exposes no timeout
    budget. OAS Provider transport is the single LLM cancellation boundary. *)

type caller =
  | Anti_rationalization
  | Operator_judge
  | Unknown of string

val caller_key : caller -> string
