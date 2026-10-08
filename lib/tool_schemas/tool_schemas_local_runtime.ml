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

(* Taken from the declaration rather than restated, so the name a handler
   labels its result with -- and the name it hands
   [authorize_external_effect] -- cannot drift from the advertised one. *)
let tool_name operation = (definition_for operation).schema.name

let schemas = List.map (fun definition -> definition.schema) definitions
