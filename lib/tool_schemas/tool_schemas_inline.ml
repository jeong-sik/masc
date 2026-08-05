(** MCP tool schemas for MCP-runtime tools.
    Split into sub-modules by functional group. *)

(** Exact projection of schemas handled by [Mcp_tool_runtime]. The schema
    records remain owned by [Tool_schemas_misc]. *)
let inline_workspace_codegen_names =
  [ "masc_start"
  ; "masc_broadcast"
  ; "masc_messages"
  ]

let inline_workspace_from_codegen =
  List.filter
    (fun (s : Masc_domain.tool_schema) ->
      List.mem s.name inline_workspace_codegen_names)
    Tool_schemas_misc.schemas

let schemas =
  inline_workspace_from_codegen
  @ Tool_schemas_inline_episodes.schemas
