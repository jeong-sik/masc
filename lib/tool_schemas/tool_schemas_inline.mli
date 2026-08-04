(** MCP tool schemas for MCP-runtime tools (facade).

    Concatenates the [inline_workspace] subset of {!Tool_schemas_misc}
    (start/broadcast/messages, moved out in RFC-0057 PR-2d to
    [Tool_descriptors_gen]) and {!Tool_schemas_inline_episodes}. *)

val schemas : Masc_domain.tool_schema list
