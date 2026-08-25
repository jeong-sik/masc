(** Tool_shard_types_schemas_surface — keeper_surface_* tool schemas
    (RFC-0223 P3). *)

(* Slack's chat.postMessage caps top-level blocks at 50. This lower tool-surface
   layer owns the wire limit; the Keeper executor consumes the public value. *)
let max_rich_blocks = 50

(* The sentence lives in config/tools/keeper_surface_post.toml, which is what
   the model is handed. Restating it here gave two copies to keep in step. *)
let keeper_surface_post_description =
  Tool_shard_types_schemas_surface_toml.surface_post.Masc_domain.description
;;

let surface_tools : Masc_domain.tool_schema list =
  [ Tool_shard_types_schemas_surface_toml.surface_read
  ; Tool_shard_types_schemas_surface_toml.surface_post
  ; Tool_shard_types_schemas_surface_toml.person_note_set
  ]
