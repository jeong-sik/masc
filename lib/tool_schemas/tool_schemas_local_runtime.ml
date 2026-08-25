(** Tool_schemas_local_runtime — SSOT for local-runtime tool schemas. *)


type operation = Local_runtime_tool_policy.operation =
  | Verify
  | Ollama_probe

type definition =
  { operation : operation
  ; schema : Masc_domain.tool_schema
  }

let operation_id = Local_runtime_tool_policy.operation_id

(* Who the tool is for. Both operations stay registered in the catalog. The
   completion-backed contract check and native Ollama probe are explicit Admin
   operations; the metadata-only
   dashboard runtime probe has its own [CanReadState] route authority and does
   not reuse this tool identity. The question this answers is narrower: does
   the autonomous Keeper model see the schema in its tool list every turn. *)
type keeper_model_exposure = Local_runtime_tool_policy.model_exposure =
  | Keeper_callable
  | Operator_diagnostic

let keeper_model_exposure = Local_runtime_tool_policy.model_exposure
let execution_policy = Local_runtime_tool_policy.execution_policy

let definitions : definition list =
  [
    { operation = Verify; schema = Tool_schemas_local_runtime_toml.verify };
    { operation = Ollama_probe; schema = Tool_schemas_local_runtime_toml.ollama_probe };
  ]

let schemas = List.map (fun definition -> definition.schema) definitions
