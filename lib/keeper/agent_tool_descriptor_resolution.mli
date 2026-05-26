(** Shared descriptor lookup for tool names observed at runtime.

    This module is the projection boundary from model/MCP/internal tool strings
    back to [Agent_tool_descriptor]. Keep receipt and tool-call evidence lookup
    here so descriptor route evidence does not grow parallel name-resolution
    rules. *)

val descriptor_for_tool_name : string -> Agent_tool_descriptor.t option

val canonical_internal_name_for_tool_name : string -> string option

val effect_domain_for_tool_name : string -> Tool_catalog.effect_domain option

val capability_has : Tool_capability.kind -> string -> bool

val readonly_for_tool_name : string -> bool option

val readonly_for_tool_call : tool_name:string -> input:Yojson.Safe.t -> bool option

val descriptors_for_tool_names : string list -> Agent_tool_descriptor.t list
