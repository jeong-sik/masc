type operation = Local_runtime_tool_policy.operation =
  | Verify
  | Ollama_probe
[@@deriving enumerate]

type definition =
  { operation : operation
  ; schema : Masc_domain.tool_schema
  }

(** Whether the autonomous Keeper model carries this operation's schema in its
    per-turn tool list. Both operations stay registered in the catalog either
    way. [Operator_diagnostic] withholds only the model projection; execution
    permission remains catalog-owned. The metadata-only dashboard runtime probe
    has a separate [CanReadState] route authority and does not borrow this native
    probe's identity. *)
type keeper_model_exposure = Local_runtime_tool_policy.model_exposure =
  | Keeper_callable
  | Operator_diagnostic

val operation_id : operation -> string
val keeper_model_exposure : operation -> keeper_model_exposure
val execution_policy : operation -> Local_runtime_tool_policy.t
val tool_name : operation -> string
(** Canonical wire name, read from the declaration rather than restated. *)

val definitions : definition list
val schemas : Masc_domain.tool_schema list
