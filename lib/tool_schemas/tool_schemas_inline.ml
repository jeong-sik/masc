(** MCP tool schemas for inline-dispatched tools.
    Split into sub-modules by functional group. *)

(* Tool_schemas_inline_coord.schemas moved to Tool_descriptors_gen
   (via Tool_schemas_misc.schemas) by RFC-0057 PR-2d. *)
let schemas =
  Tool_schemas_inline_infra.schemas
  @ Tool_schemas_inline_episodes.schemas
