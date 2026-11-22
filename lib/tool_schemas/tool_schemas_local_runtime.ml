(** Tool_schemas_local_runtime — SSOT for local-runtime tool schemas. *)

type operation = Local_runtime_tool_policy.operation =
  | Verify
  | Ollama_probe
  | Systemone_decide
[@@deriving enumerate]

type definition =
  { operation : operation
  ; schema : Masc_domain.tool_schema
  }

let operation_id = Local_runtime_tool_policy.operation_id
let execution_policy = Local_runtime_tool_policy.execution_policy

let verify_schema = Tool_definition_embedded.schema "masc_runtime_verify"
let ollama_probe_schema = Tool_definition_embedded.schema "masc_runtime_ollama_probe"
let systemone_decide_schema = Tool_definition_embedded.schema "masc_decide"

let definition_for operation =
  match operation with
  | Verify -> { operation; schema = verify_schema }
  | Ollama_probe -> { operation; schema = ollama_probe_schema }
  | Systemone_decide -> { operation; schema = systemone_decide_schema }
;;

let definitions : definition list = List.map definition_for all_of_operation

let tool_name operation = (definition_for operation).schema.name

let schemas = List.map (fun definition -> definition.schema) definitions
