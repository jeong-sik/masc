type operation =
  | Verify
  | Ollama_probe

type definition =
  { operation : operation
  ; schema : Masc_domain.tool_schema
  }

val operation_id : operation -> string
val definitions : definition list
val schemas : Masc_domain.tool_schema list
