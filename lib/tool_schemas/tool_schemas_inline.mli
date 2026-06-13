(** MCP tool schemas for MCP-runtime tools (facade).

    Concatenates the [inline_workspace] subset of {!Tool_schemas_misc} (six
    [masc_*] names: start/join/leave/broadcast/messages/who, moved out
    in RFC-0057 PR-2d to [Tool_descriptors_gen]), {!Tool_schemas_inline_infra},
    and {!Tool_schemas_inline_episodes}. *)

val schemas : Masc_domain.tool_schema list
