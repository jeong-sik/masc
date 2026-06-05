(** Tool schema registry for the board MCP adapter. *)

val tool_delete : Masc_domain.tool_schema
val board_tool_cleanup : Masc_domain.tool_schema
val board_tool_curation_read : Masc_domain.tool_schema
val board_tool_curation_submit : Masc_domain.tool_schema
val tools : Masc_domain.tool_schema list
