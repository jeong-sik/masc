type connector_post_replay =
  | Replay_discord_post of
      { input : Yojson.Safe.t
      ; channel_id : string
      ; content : string
      ; mention_user_ids : string list
      }
  | Replay_slack_post of
      { input : Yojson.Safe.t
      ; channel_id : string
      ; thread_ts : string option
      ; content : string
      ; blocks : Yojson.Safe.t list
      ; mention_user_ids : string list
      }

val connector_post_gate_input :
  connector:string -> channel_id:string -> content:string ->
  mention_user_ids:string list -> ?thread_ts:string ->
  ?blocks:Yojson.Safe.t list -> unit -> Yojson.Safe.t
val connector_post_replay_of_gate_input :
  Yojson.Safe.t -> (connector_post_replay, string) result
val connector_post_replay_target :
  connector_post_replay -> Keeper_surface_post.post_target
val connector_post_call_summary : connector_post_replay -> string option
