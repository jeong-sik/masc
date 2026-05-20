(* Board SSE event -> JSON params projection.

   Maps the [Board_dispatch.board_sse_event] sum type into the wire
   payload broadcast on the [/sse/board] stream (post.created /
   comment.created / vote.changed / reaction.changed).  Carries actor
   identity through [Server_utils.board_actor_identity_json] so the
   dashboard can route per-author UI.

   Extracted from [Server_bootstrap_loops] (godfile decomp). Pure
   mapping over [Board_dispatch] variants - no I/O, no shared state. *)

let board_sse_event_params event =
  match event with
  | Board_dispatch.Post_created { post_id; author; title; content; post_kind; hearth } ->
    let preview =
      if String.length content > 200 then String.sub content 0 200 else content
    in
    let base =
      [ "type", `String "post_created"
      ; "event_type", `String "post.created"
      ; "post_id", `String post_id
      ; "author", `String author
      ; "author_identity", Server_utils.board_actor_identity_json author
      ; "title", `String title
      ; "content", `String preview
      ; "post_kind", `String (Board.post_kind_to_string post_kind)
      ]
    in
    `Assoc
      (match hearth with
       | Some h -> ("hearth", `String h) :: base
       | None -> base)
  | Board_dispatch.Comment_added { post_id; comment_id; author } ->
    `Assoc
      [ "type", `String "comment_added"
      ; "event_type", `String "comment.created"
      ; "post_id", `String post_id
      ; "comment_id", `String comment_id
      ; "author", `String author
      ; "author_identity", Server_utils.board_actor_identity_json author
      ]
  | Board_dispatch.Post_voted { post_id; voter; direction } ->
    let dir = Board_votes.vote_direction_to_string direction in
    `Assoc
      [ "type", `String "post_voted"
      ; "event_type", `String "vote.changed"
      ; "target_type", `String "post"
      ; "post_id", `String post_id
      ; "voter", `String voter
      ; "voter_identity", Server_utils.board_actor_identity_json voter
      ; "direction", `String dir
      ]
  | Board_dispatch.Comment_voted { comment_id; voter; direction } ->
    let dir = Board_votes.vote_direction_to_string direction in
    `Assoc
      [ "type", `String "comment_voted"
      ; "event_type", `String "vote.changed"
      ; "target_type", `String "comment"
      ; "comment_id", `String comment_id
      ; "voter", `String voter
      ; "voter_identity", Server_utils.board_actor_identity_json voter
      ; "direction", `String dir
      ]
  | Board_dispatch.Reaction_changed { target_type; target_id; user_id; emoji; reacted } ->
    `Assoc
      [ "type", `String "reaction_changed"
      ; "event_type", `String "reaction.changed"
      ; "target_type", `String (Board.reaction_target_type_to_string target_type)
      ; "target_id", `String target_id
      ; "user_id", `String user_id
      ; "user_identity", Server_utils.board_actor_identity_json user_id
      ; "emoji", `String emoji
      ; "reacted", `Bool reacted
      ]
;;
