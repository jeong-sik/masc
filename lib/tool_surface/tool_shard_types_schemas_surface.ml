(** Tool_shard_types_schemas_surface — keeper_surface_* tool schemas
    (RFC-0223 P3). *)

(* Slack's chat.postMessage caps top-level blocks at 50. This lower tool-surface
   layer owns the wire limit; the Keeper executor consumes the public value. *)
let max_rich_blocks = 50

let surface_tools : Masc_domain.tool_schema list =
  [ Tool_shard_types_schemas_surface_toml.surface_read
  ; Tool_shard_types_schemas_surface_toml.surface_post
  ; Tool_shard_types_schemas_surface_toml.person_note_set
  ]
