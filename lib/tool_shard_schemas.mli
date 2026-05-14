(** Tool_shard_schemas - MCP tool schema definitions for shard management.

    Extracted from tool_shard.ml to reduce godfile size.
*)

val schemas : Masc_domain.tool_schema list
(** MCP tool schemas for masc_tool_grant, masc_tool_revoke, masc_tool_list. *)
