(** MCP tool schemas for inline-dispatched tools.
    Split into sub-modules by functional group. *)

let schemas =
  Tool_schemas_inline_room.schemas
  @ Tool_schemas_inline_infra.schemas
  @ Tool_schemas_inline_episodes.schemas
