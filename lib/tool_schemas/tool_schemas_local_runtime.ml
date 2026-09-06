(** Tool_schemas_local_runtime — SSOT for local-runtime tool schemas. *)


type operation = Local_runtime_tool_policy.operation =
  | Verify
  | Ollama_probe
[@@deriving enumerate]

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

(* One definition per constructor, and [definitions] is [all_of_operation]
   mapped through it. Writing the list out instead let a new operation compile
   -- [operation_id] and the policy functions are exhaustive -- while quietly
   staying out of the list registration walks, so it would be routable and
   never advertised. *)
let definition_for operation =
  match operation with
  | Verify -> { operation; schema = Tool_schemas_local_runtime_toml.verify }
  | Ollama_probe -> { operation; schema = Tool_schemas_local_runtime_toml.ollama_probe }
;;

let definitions : definition list = List.map definition_for all_of_operation

let schemas = List.map (fun definition -> definition.schema) definitions
