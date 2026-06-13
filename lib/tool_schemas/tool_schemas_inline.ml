(** MCP tool schemas for MCP-runtime tools.
    Split into sub-modules by functional group. *)

(* RFC-0057 PR-2d: inline_workspace tools (masc_start/broadcast/messages)
   moved to Tool_descriptors_gen. They flow through
   Tool_schemas_misc.schemas, but downstream consumers still identify
   MCP-runtime tools by membership in this list — so we re-include
   them here by filtering Tool_schemas_misc.schemas to the inline_workspace
   names. *)
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
  @ Tool_schemas_inline_infra.schemas
  @ Tool_schemas_inline_episodes.schemas
