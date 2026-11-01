(** Board JSON wire encoders and reaction parsers. *)


include Board_core_classify

(** {1 JSON Serialization} *)

let post_to_yojson = Board_content_json.post_to_yojson
let post_origin_to_yojson = Board_content_json.post_origin_to_yojson
let post_close_state_to_yojson = Board_content_json.post_close_state_to_yojson
let comment_to_yojson = Board_content_json.comment_to_yojson
let audience_to_yojson = Board_content_json.audience_to_yojson

let emit_content_diagnostic (diagnostic : Board_content_json.diagnostic) =
  match diagnostic with
  | Board_content_json.Invalid_post_kind { post_id } ->
    Log.BoardLog.warn
      "dropping persisted board post %s: missing or invalid post_kind"
      post_id
  | Board_content_json.Invalid_agent_id { raw } ->
    ignore (Agent_id.of_string raw)
;;

let decoded_content (decoded : 'a Board_content_json.decoded) : 'a option =
  List.iter emit_content_diagnostic decoded.diagnostics;
  decoded.value
;;

let post_of_yojson json = decoded_content (Board_content_json.post_of_yojson json)
let comment_of_yojson json = decoded_content (Board_content_json.comment_of_yojson json)
let audience_of_yojson json = decoded_content (Board_content_json.audience_of_yojson json)

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
