(** Board JSON wire encoders and reaction parsers. *)


include Board_core_classify

(** {1 JSON Serialization} *)

(* RFC-0233 §7: encode the typed origin as its own top-level [origin] key
   (sibling of [meta], NOT nested under it) so the index key needs no
   meta_json substring scan (RFC §7.6 guard #2). Each sub-field is emitted
   only when present; turn_ref serializes via [Ids.Turn_ref.to_yojson] (a flat
   "trace#turn" string), matching the chat-row wire form. *)
let post_origin_to_yojson (o : post_origin) : Yojson.Safe.t =
  `Assoc
    ((match o.turn_ref with
      | Some tr -> [ "turn_ref", Ids.Turn_ref.to_yojson tr ]
      | None -> [])
     @ (match o.source with
        | Some s -> [ "source", `String s ]
        | None -> [])
     @
     match o.fusion_run_id with
     | Some r -> [ "fusion_run_id", `String r ]
     | None -> [])
;;

let post_to_yojson (p : post) : Yojson.Safe.t =
  `Assoc
    ([ "id", `String (Post_id.to_string p.id)
     ; "author", `String (Agent_id.to_string p.author)
     ; "title", `String p.title
     ; "body", `String p.body
     ; "post_kind", `String (post_kind_to_string p.post_kind)
     ; "visibility", `String (visibility_to_string p.visibility)
     ; "created_at", `Float p.created_at
     ; "updated_at", `Float p.updated_at
     ; "expires_at", `Float p.expires_at
     ; "votes_up", `Int p.votes_up
     ; "votes_down", `Int p.votes_down
     ; "reply_count", `Int p.reply_count
     ; "pinned", `Bool p.pinned
     ]
     @ (match p.hearth with
        | Some h -> [ "hearth", `String h ]
        | None -> [])
     @ (match p.thread_id with
        | Some t -> [ "thread_id", `String t ]
        | None -> [])
     @ (match p.origin with
        | Some o -> [ "origin", post_origin_to_yojson o ]
        | None -> [])
     @ (match post_classification_reason p with
        | Some reason -> [ "classification_reason", `String reason ]
        | None -> [])
     @
     match p.meta_json with
     | Some meta -> [ "meta", meta ]
     | None -> [])
;;

let comment_to_yojson (c : comment) : Yojson.Safe.t =
  `Assoc
    [ "id", `String (Comment_id.to_string c.id)
    ; "post_id", `String (Post_id.to_string c.post_id)
    ; ( "parent_id"
      , Json_util.string_opt_to_json (Option.map Comment_id.to_string c.parent_id) )
    ; "author", `String (Agent_id.to_string c.author)
    ; "content", `String c.content
    ; "created_at", `Float c.created_at
    ; "expires_at", `Float c.expires_at
    ; "votes_up", `Int c.votes_up
    ; "votes_down", `Int c.votes_down
    ]
;;

let reaction_target_type_to_string = function
  | Reaction_post -> "post"
  | Reaction_comment -> "comment"
;;

let reaction_target_type_of_string_opt raw =
  match String.lowercase_ascii (String.trim raw) with
  | "post" -> Some Reaction_post
  | "comment" -> Some Reaction_comment
  | _ -> None
;;

let valid_reaction_target_type_strings = [ "post"; "comment" ]

let board_reaction_emojis = [ "👍"; "❤️"; "🎉"; "🚀"; "👀"; "😕"; "👏"; "🔥" ]

let reaction_key ~target_type ~target_id ~user_id ~emoji =
  String.concat
    ":"
    [ reaction_target_type_to_string target_type; target_id; user_id; emoji ]
;;

let reaction_to_yojson (r : reaction) : Yojson.Safe.t =
  `Assoc
    [ "target_type", `String (reaction_target_type_to_string r.target_type)
    ; "target_id", `String r.target_id
    ; "user_id", `String (Agent_id.to_string r.user_id)
    ; "emoji", `String r.emoji
    ; "created_at", `Float r.created_at
    ]
;;

let reaction_summary_to_yojson (summary : reaction_summary) : Yojson.Safe.t =
  `Assoc
    [ "emoji", `String summary.emoji
    ; "count", `Int summary.count
    ; "reacted", `Bool summary.reacted
    ; "has_reacted", `Bool summary.reacted
    ; ( "recent_user_ids"
      , `List (List.map (fun user_id -> `String user_id) summary.recent_user_ids) )
    ]
;;

let reaction_toggle_result_to_yojson (result : reaction_toggle_result) : Yojson.Safe.t =
  `Assoc
    [ "target_type", `String (reaction_target_type_to_string result.target_type)
    ; "target_id", `String result.target_id
    ; "user_id", `String result.user_id
    ; "emoji", `String result.emoji
    ; "reacted", `Bool result.reacted
    ; "summary", `List (List.map reaction_summary_to_yojson result.summary)
    ]
;;

let reaction_of_yojson (json : Yojson.Safe.t) : reaction option =
  match json with
  | `Assoc fields ->
    let allowed = [ "target_type"; "target_id"; "user_id"; "emoji"; "created_at" ] in
    let rec has_exact_fields seen = function
      | [] -> true
      | (name, _) :: rest ->
        if List.mem name seen || not (List.mem name allowed)
        then false
        else has_exact_fields (name :: seen) rest
    in
    if not (has_exact_fields [] fields)
    then None
    else
      (match
         ( List.assoc_opt "target_type" fields
         , List.assoc_opt "target_id" fields
         , List.assoc_opt "user_id" fields
         , List.assoc_opt "emoji" fields
         , List.assoc_opt "created_at" fields )
       with
       | ( Some (`String target_type_raw)
         , Some (`String target_id_raw)
         , Some (`String user_id_raw)
         , Some (`String emoji)
         , Some (`Float created_at) )
         when Float.is_finite created_at && Float.compare created_at 0.0 > 0 ->
         let target =
           match target_type_raw with
           | "post" ->
             (match Post_id.of_string target_id_raw with
              | Ok id when String.equal target_id_raw (Post_id.to_string id) ->
                Some (Reaction_post, Post_id.to_string id)
              | Ok _ | Error _ -> None)
           | "comment" ->
             (match Comment_id.of_string target_id_raw with
              | Ok id when String.equal target_id_raw (Comment_id.to_string id) ->
                Some (Reaction_comment, Comment_id.to_string id)
              | Ok _ | Error _ -> None)
           | _ -> None
         in
         (match target, Agent_id.of_string user_id_raw with
          | Some (target_type, target_id), Ok user_id
            when String.equal user_id_raw (Agent_id.to_string user_id)
                 && List.exists (String.equal emoji) board_reaction_emojis ->
            Some { target_type; target_id; user_id; emoji; created_at }
          | Some _, Ok _ | Some _, Error _ | None, _ -> None)
       | _ -> None)
  | _ -> None
;;
