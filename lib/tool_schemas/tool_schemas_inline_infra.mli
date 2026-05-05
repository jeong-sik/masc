(** Tool_schemas_inline_infra — Inline schemas for infra tool
    surfaces (session, approval, spawn).

    Issue #8520: [mcp_session_action_enum_strings] hand-mirrors
    {!Mcp_session.valid_action_strings}. The sync regression test
    [test_types.ml :: mcp_session_action_ssot] catches drift. *)

(** Enum of valid [masc_mcp_session] action strings, mirrored from
    {!Mcp_session.valid_action_strings}. *)
val mcp_session_action_enum_strings : string list

(** Tool schema list: [masc_mcp_session], [masc_approval_get],
    [masc_spawn]. *)
val schemas : Masc_domain.tool_schema list
