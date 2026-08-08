(** MCP schema bridge — converts between MCP SDK types and OAS types.

    @stability Internal
    @since 0.93.1 *)

module Sdk_types = Mcp_protocol.Mcp_types

(** {1 Schema conversion} *)

val json_schema_type_to_param_type : string -> Types.param_type
val json_schema_type_to_param_type_result : string -> (Types.param_type, string) result
val json_schema_to_params : Yojson.Safe.t -> Types.tool_param list
val json_schema_to_params_result : Yojson.Safe.t -> (Types.tool_param list, string) result

(** {1 MCP tool types} *)

type mcp_tool =
  { name : string
  ; description : string
  ; input_schema : Yojson.Safe.t
  }

type mcp_resource = Sdk_types.resource
type mcp_resource_contents = Sdk_types.resource_contents
type mcp_prompt = Sdk_types.prompt
type mcp_prompt_result = Sdk_types.prompt_result

(** {1 Tool construction} *)

(** Build a tool from one authoritative JSON Schema: [parameters] are derived
    from [~input_schema] here, so the two views cannot disagree, and the schema
    reaches providers verbatim instead of being rebuilt from the lossy
    parameter view. Valid properties that have no {!Types.tool_param}
    representation remain only in that authoritative schema. Fails with the
    offending field and reason when the schema boundary is malformed. *)
val tool_of_input_schema_result
  :  ?descriptor:Tool.descriptor
  -> ?strict:bool
  -> name:string
  -> description:string
  -> input_schema:Yojson.Safe.t
  -> Tool.tool_handler
  -> (Tool.t, string) result

val mcp_tool_of_sdk_tool : Sdk_types.tool -> mcp_tool
val mcp_tool_to_sdk_tool : call_fn:Tool.tool_handler -> mcp_tool -> Tool.t

val mcp_tool_to_sdk_tool_result
  :  call_fn:Tool.tool_handler
  -> mcp_tool
  -> (Tool.t, string) result
