type operation =
  | Verify
  | Ollama_probe

type definition =
  { operation : operation
  ; schema : Masc_domain.tool_schema
  }

(** Whether the autonomous Keeper model carries this operation's schema in its
    per-turn tool list. Both operations stay registered in the catalog either
    way: [Operator_diagnostic] withholds only the model projection, and the
    dashboard route still authorizes by tool name through
    [Auth.authorize_tool_for_role], which refuses any unregistered name. *)
type keeper_model_exposure =
  | Keeper_callable
  | Operator_diagnostic

val operation_id : operation -> string
val keeper_model_exposure : operation -> keeper_model_exposure
val definitions : definition list
val schemas : Masc_domain.tool_schema list
