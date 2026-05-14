(** MCP tool schemas for inline-dispatched tools.
    Split into sub-modules by functional group. *)

(* RFC-0057 PR-2d: inline_coord tools (masc_start/join/leave/broadcast/
   messages/who) moved to Tool_descriptors_gen. They flow through
   Tool_schemas_misc.schemas, but downstream consumers
   (Tool_dispatch.mcp_context_required_set,
    Keeper_tool_policy.is_keeper_mcp_context_required) identify
   inline-dispatched tools by membership in this list — so we
   re-include them here by filtering Tool_schemas_misc.schemas to the
   six inline_coord names. *)
let _inline_coord_codegen_names =
  [ "masc_start"
  ; "masc_join"
  ; "masc_leave"
  ; "masc_broadcast"
  ; "masc_messages"
  ; "masc_who"
  ]

let _inline_coord_from_codegen =
  List.filter
    (fun (s : Masc_domain.tool_schema) ->
      List.mem s.name _inline_coord_codegen_names)
    Tool_schemas_misc.schemas

let schemas =
  _inline_coord_from_codegen
  @ Tool_schemas_inline_infra.schemas
  @ Tool_schemas_inline_episodes.schemas
