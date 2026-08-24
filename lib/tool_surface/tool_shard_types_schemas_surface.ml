(** Tool_shard_types_schemas_surface — keeper_surface_* tool schemas
    (RFC-0223 P3). *)

(* Slack's chat.postMessage caps top-level blocks at 50. This lower tool-surface
   layer owns the wire limit; the Keeper executor consumes the public value. *)
let max_rich_blocks = 50

let keeper_surface_post_description =
  "Post a message to one conversation endpoint: 'dashboard' (appears \
   in the operator's chat transcript), 'discord', or 'slack'. Standard \
   Markdown is rendered natively by Discord and by Slack's Block Kit \
   markdown block. To create a real highlighted user mention, pass stable \
   participant-roster ids in mention_user_ids; never guess ids from display \
   names. A Slack post may reply inside an existing thread (thread_ts) \
   or carry Block Kit blocks; see those parameters. Posting to an unbound \
   surface is an error. These endpoints \
   are read by a person, so an unchanged status reposted every cycle \
   crowds their view and says nothing the previous one did not; when \
   there is nothing new, the turn ends without a post."
;;

let surface_tools : Masc_domain.tool_schema list =
  [ Tool_shard_types_schemas_surface_toml.surface_read
  ; Tool_shard_types_schemas_surface_toml.surface_post
  ; Tool_shard_types_schemas_surface_toml.person_note_set
  ]
