(** Tool_schemas_inline_infra — Inline schema for MCP session plumbing.

    Issue #8520: [mcp_session_action_enum_strings] hand-mirrors
    {!Mcp_session.valid_action_strings}. The sync regression test
    [test_types.ml :: mcp_session_action_ssot] catches drift. *)

(** Enum of valid [masc_session] action strings, mirrored from
    {!Mcp_session.valid_action_strings}. *)
val mcp_session_action_enum_strings : string list

(** Tool schema list: [masc_session]. *)
val schemas : Masc_domain.tool_schema list
