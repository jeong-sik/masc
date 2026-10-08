type operation = Local_runtime_tool_policy.operation =
  | Verify
  | Ollama_probe
[@@deriving enumerate]

type definition =
  { operation : operation
  ; schema : Masc_domain.tool_schema
  }

val operation_id : operation -> string
val execution_policy : operation -> Local_runtime_tool_policy.t
val tool_name : operation -> string
(** Canonical wire name, read from the declaration rather than restated. *)

val definitions : definition list
val schemas : Masc_domain.tool_schema list
