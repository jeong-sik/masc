(** Shared descriptor lookup for tool names observed at runtime.

    This module is the projection boundary from model/MCP/internal tool strings
    back to [Keeper_tool_descriptor]. Keep receipt and tool-call evidence lookup
    here so descriptor route evidence does not grow parallel name-resolution
    rules. *)

val descriptor_for_tool_name : string -> Keeper_tool_descriptor.t option

val canonical_internal_name_for_tool_name : string -> string option

val public_names_for_internal : string -> string list

val public_name_for_internal : string -> string option

val public_names_for_allowed_internal_names : string list -> string list

(** [is_public_mcp_surface_name name] answers the narrow diagnostic question
    "is this runtime-observed name the descriptor-backed public MCP surface
    name?" Keep per-turn keeper classification behind this projection instead
    of letting turn setup query the MCP catalog directly. *)
val is_public_mcp_surface_name : string -> bool

val capability_has : Tool_capability.kind -> string -> bool

val descriptor_and_input_for_tool_call :
  tool_name:string -> input:Yojson.Safe.t -> (Keeper_tool_descriptor.t * Yojson.Safe.t) option

val validate_public_input_for_tool_call :
  tool_name:string -> input:Yojson.Safe.t -> (Yojson.Safe.t, Tool_result.result) result option

val validated_descriptor_and_input_for_tool_call :
  tool_name:string ->
  input:Yojson.Safe.t ->
  ((Keeper_tool_descriptor.t * Yojson.Safe.t), Tool_result.result) result option

val readonly_for_tool_name : string -> bool option

val readonly_for_tool_call : tool_name:string -> input:Yojson.Safe.t -> bool option

val descriptors_for_tool_names : string list -> Keeper_tool_descriptor.t list
