(** Tool_shard_schemas - removed MCP shard-management surface.

    Shard membership remains internal keeper policy state. *)

val schemas : Masc_domain.tool_schema list
(** Empty: [masc_tool_*] callable tools are not exposed. *)
