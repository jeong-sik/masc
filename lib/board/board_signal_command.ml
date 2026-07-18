module List = Stdlib.List
module Result = Stdlib.Result
module String = Stdlib.String
module Float = Stdlib.Float

type routing_post_snapshot = {
  post_id : string;
  title : string;
  content : string;
  hearth : string option;
  updated_at : float;
  reply_count : int;
}

type t =
  | Post of {
      post : Board.post;
      audience : Board_signal_audience.t;
    }
  | Comment of {
      comment : Board.comment;
      routing_post : routing_post_snapshot;
      audience : Board_signal_audience.t;
    }
  | Reaction of {
      target_type : Board.reaction_target_type;
      target_id : string;
      user_id : string;
      emoji : string;
      reacted : bool;
      created_at : float;
      routing_post : routing_post_snapshot;
      audience : Board_signal_audience.t;
    }

type signal_kind =
  | Board_post_created
  | Board_comment_added
  | Board_reaction_changed of reaction_change

and reaction_change = {
  target_type : Board.reaction_target_type;
  target_id : string;
  user_id : string;
  emoji : string;
  reacted : bool;
}

type signal = {
  kind : signal_kind;
  post_id : string;
  author : string;
  title : string;
  content : string;
  hearth : string option;
  updated_at : float option;
}

let option_json encode = function
  | None -> `Null
  | Some value -> encode value
;;

let routing_post_snapshot_to_yojson (snapshot : routing_post_snapshot) =
  `Assoc
    [ "post_id", `String snapshot.post_id
    ; "title", `String snapshot.title
    ; "content", `String snapshot.content
    ; "hearth", option_json (fun value -> `String value) snapshot.hearth
    ; "updated_at", `Float snapshot.updated_at
    ; "reply_count", `Int snapshot.reply_count
    ]
;;

let to_yojson = function
  | Post { post; audience } ->
    `Assoc
      [ "kind", `String "post"
      ; "post", Board.post_to_yojson post
      ; "audience", Board_signal_audience.to_yojson audience
      ]
  | Comment { comment; routing_post; audience } ->
    `Assoc
      [ "kind", `String "comment"
      ; "comment", Board.comment_to_yojson comment
      ; "routing_post", routing_post_snapshot_to_yojson routing_post
      ; "audience", Board_signal_audience.to_yojson audience
      ]
  | Reaction
      { target_type
      ; target_id
      ; user_id
      ; emoji
      ; reacted
      ; created_at
      ; routing_post
      ; audience
      } ->
    `Assoc
      [ "kind", `String "reaction"
      ; "target_type", `String (Board.reaction_target_type_to_string target_type)
      ; "target_id", `String target_id
      ; "user_id", `String user_id
      ; "emoji", `String emoji
      ; "reacted", `Bool reacted
      ; "created_at", `Float created_at
      ; "routing_post", routing_post_snapshot_to_yojson routing_post
      ; "audience", Board_signal_audience.to_yojson audience
      ]
;;

let exact_fields ~context expected fields =
  let field_names = List.map fst fields in
  let expected = List.sort_uniq String.compare expected in
  let actual = List.sort_uniq String.compare field_names in
  if List.length field_names <> List.length actual
  then Error (Printf.sprintf "%s contains duplicate fields" context)
  else if expected = actual
  then Ok ()
  else
    Error
      (Printf.sprintf
         "%s fields mismatch expected=[%s] actual=[%s]"
         context
         (String.concat "," expected)
         (String.concat "," actual))
;;

let string_field ~context name fields =
  match List.assoc_opt name fields with
  | Some (`String value) when not (String.equal value "") -> Ok value
  | Some _ -> Error (Printf.sprintf "%s.%s must be a non-empty string" context name)
  | None -> Error (Printf.sprintf "%s missing %s" context name)
;;

let bool_field ~context name fields =
  match List.assoc_opt name fields with
  | Some (`Bool value) -> Ok value
  | Some _ -> Error (Printf.sprintf "%s.%s must be a boolean" context name)
  | None -> Error (Printf.sprintf "%s missing %s" context name)
;;

let finite_float_field ~context name fields =
  let value =
    match List.assoc_opt name fields with
    | Some (`Float value) -> Ok value
    | Some (`Int value) -> Ok (Float.of_int value)
    | Some _ -> Error (Printf.sprintf "%s.%s must be a number" context name)
    | None -> Error (Printf.sprintf "%s missing %s" context name)
  in
  Result.bind value (fun value ->
    if Float.is_finite value
    then Ok value
    else Error (Printf.sprintf "%s.%s must be finite" context name))
;;

let nullable_string_field ~context name fields =
  match List.assoc_opt name fields with
  | Some `Null -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some _ -> Error (Printf.sprintf "%s.%s must be a string or null" context name)
  | None -> Error (Printf.sprintf "%s missing %s" context name)
;;

let routing_post_snapshot_of_yojson = function
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let context = "board routing post snapshot" in
    let* () =
      exact_fields
        ~context
        [ "post_id"; "title"; "content"; "hearth"; "updated_at"; "reply_count" ]
        fields
    in
    let* post_id = string_field ~context "post_id" fields in
    let* title =
      match List.assoc_opt "title" fields with
      | Some (`String value) -> Ok value
      | Some _ -> Error (context ^ ".title must be a string")
      | None -> Error (context ^ " missing title")
    in
    let* content =
      match List.assoc_opt "content" fields with
      | Some (`String value) -> Ok value
      | Some _ -> Error (context ^ ".content must be a string")
      | None -> Error (context ^ " missing content")
    in
    let* hearth = nullable_string_field ~context "hearth" fields in
    let* updated_at = finite_float_field ~context "updated_at" fields in
    let* reply_count =
      match List.assoc_opt "reply_count" fields with
      | Some (`Int value) when value >= 0 -> Ok value
      | Some _ -> Error (context ^ ".reply_count must be a non-negative integer")
      | None -> Error (context ^ " missing reply_count")
    in
    Ok { post_id; title; content; hearth; updated_at; reply_count }
  | _ -> Error "board routing post snapshot must be an object"
;;

let canonical_post_of_yojson json =
  match Board.post_of_yojson json with
  | Some post
    when Yojson.Safe.equal (Board.post_to_yojson post) json
         && Float.is_finite post.created_at
         && Float.is_finite post.updated_at
         && Float.is_finite post.expires_at
         && Float.equal post.updated_at post.created_at
         && post.votes_up = 0
         && post.votes_down = 0
         && post.reply_count = 0
         && not post.pinned -> Ok post
  | Some _ | None -> Error "board prepared post is not a canonical post object"
;;

let canonical_comment_of_yojson json =
  match Board.comment_of_yojson json with
  | Some comment
    when Yojson.Safe.equal (Board.comment_to_yojson comment) json
         && Float.is_finite comment.created_at
         && Float.is_finite comment.expires_at
         && comment.votes_up = 0
         && comment.votes_down = 0 -> Ok comment
  | Some _ | None -> Error "board prepared comment is not a canonical comment object"
;;

let required_json ~context name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s missing %s" context name)
;;

let post_audience (post : Board.post) =
  match
    Direct_mention.targets_of_content (String.concat "\n" [ post.title; post.content ])
  with
  | _ :: _ as targets ->
    Result.map_error
      (fun detail -> Board_types.Validation_error detail)
      (Board_signal_audience.targets targets)
  | [] ->
    (match post.visibility with
     | Board.Direct ->
       Error
         (Board_types.Validation_error
            "Direct Board visibility requires at least one exact @target")
     | Board.Public | Board.Unlisted | Board.Internal ->
       Ok Board_signal_audience.discoverable)
;;

let of_yojson = function
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let context = "board signal command" in
    let* kind = string_field ~context "kind" fields in
    (match kind with
     | "post" ->
       let* () = exact_fields ~context [ "kind"; "post"; "audience" ] fields in
       let* post_json = required_json ~context "post" fields in
       let* audience_json = required_json ~context "audience" fields in
       let* post = canonical_post_of_yojson post_json in
       let* audience = Board_signal_audience.of_yojson audience_json in
       let* expected_audience =
         Result.map_error Board_types.show_board_error (post_audience post)
       in
       if expected_audience = audience
       then Ok (Post { post; audience })
       else Error (context ^ ".audience differs from the post routing policy")
     | "comment" ->
       let* () =
         exact_fields
           ~context
           [ "kind"; "comment"; "routing_post"; "audience" ]
           fields
       in
       let* comment_json = required_json ~context "comment" fields in
       let* routing_post_json = required_json ~context "routing_post" fields in
       let* audience_json = required_json ~context "audience" fields in
       let* comment = canonical_comment_of_yojson comment_json in
       let* routing_post = routing_post_snapshot_of_yojson routing_post_json in
       let* audience = Board_signal_audience.of_yojson audience_json in
       let actual_post_id = Board.Post_id.to_string comment.post_id in
       let direct_targets = Direct_mention.targets_of_content comment.content in
       let audience_matches_policy =
         match direct_targets, audience with
         | _ :: _, Board_signal_audience.Targets targets ->
           direct_targets = targets
         | [], Board_signal_audience.Thread_participants _ -> true
         | _ -> false
       in
       if not (String.equal actual_post_id routing_post.post_id)
       then Error (context ^ ".comment post_id differs from routing_post.post_id")
       else if not audience_matches_policy
       then Error (context ^ ".audience differs from the comment routing policy")
       else Ok (Comment { comment; routing_post; audience })
     | "reaction" ->
       let* () =
         exact_fields
           ~context
           [ "kind"
           ; "target_type"
           ; "target_id"
           ; "user_id"
           ; "emoji"
           ; "reacted"
           ; "created_at"
           ; "routing_post"
           ; "audience"
           ]
           fields
       in
       let* target_type_raw = string_field ~context "target_type" fields in
       let* target_type =
         match Board.reaction_target_type_of_string_opt target_type_raw with
         | Some value -> Ok value
         | None -> Error (context ^ ".target_type is invalid")
       in
       let* target_id = string_field ~context "target_id" fields in
       let* user_id = string_field ~context "user_id" fields in
       let* emoji = string_field ~context "emoji" fields in
       let* () =
         let validation =
           match target_type with
           | Board.Reaction_post ->
             Result.map
               (fun (_ : Board.Post_id.t) -> ())
               (Board.Post_id.of_string target_id)
           | Board.Reaction_comment ->
             Result.map
               (fun (_ : Board.Comment_id.t) -> ())
               (Board.Comment_id.of_string target_id)
         in
         Result.map_error Board_types.show_board_error validation
       in
       let* canonical_user =
         Result.map_error Board_types.show_board_error (Board.Agent_id.of_string user_id)
       in
       let* canonical_emoji =
         Result.map_error Board_types.show_board_error (Board.normalize_reaction_emoji emoji)
       in
       let* () =
         if String.equal user_id (Board.Agent_id.to_string canonical_user)
            && String.equal emoji canonical_emoji
         then Ok ()
         else Error (context ^ ".reaction identity or emoji is not canonical")
       in
       let* reacted = bool_field ~context "reacted" fields in
       let* created_at = finite_float_field ~context "created_at" fields in
       let* routing_post_json = required_json ~context "routing_post" fields in
       let* audience_json = required_json ~context "audience" fields in
       let* routing_post = routing_post_snapshot_of_yojson routing_post_json in
       let* audience = Board_signal_audience.of_yojson audience_json in
       let target_matches_routing_post =
         match target_type with
         | Board.Reaction_post -> String.equal target_id routing_post.post_id
         | Board.Reaction_comment -> true
       in
       if not target_matches_routing_post
       then Error (context ^ ".reaction target differs from routing_post.post_id")
       else
         (match audience with
          | Board_signal_audience.Thread_participants _ ->
            Ok
              (Reaction
                 { target_type
                 ; target_id
                 ; user_id
                 ; emoji
                 ; reacted
                 ; created_at
                 ; routing_post
                 ; audience
                 })
          | Board_signal_audience.Targets _
          | Board_signal_audience.Broadcast
          | Board_signal_audience.Discoverable ->
            Error (context ^ ".audience differs from the reaction routing policy"))
     | unknown -> Error (Printf.sprintf "%s.kind is unknown: %S" context unknown))
  | _ -> Error "board signal command must be an object"
;;

let routing_post_snapshot_of_post (post : Board.post) =
  { post_id = Board.Post_id.to_string post.id
  ; title = post.title
  ; content = post.content
  ; hearth = post.hearth
  ; updated_at = post.updated_at
  ; reply_count = post.reply_count
  }
;;

let post post =
  match canonical_post_of_yojson (Board.post_to_yojson post) with
  | Error detail -> Error (Board_types.Validation_error detail)
  | Ok canonical_post ->
    Result.map
      (fun audience -> Post { post = canonical_post; audience })
      (post_audience canonical_post)
;;

let audience_for_thread_activity
      ~(post : Board.post)
      ~(comments : Board.comment list)
      ~actor
      ~direct_content
  =
  match Direct_mention.targets_of_content direct_content with
  | _ :: _ as targets ->
    Result.map_error
      (fun detail -> Board_types.Validation_error detail)
      (Board_signal_audience.targets targets)
  | [] ->
    let actor = String.lowercase_ascii (String.trim actor) in
    let participants =
      Board.Agent_id.to_string post.author
      :: List.map
           (fun (comment : Board.comment) -> Board.Agent_id.to_string comment.author)
           comments
      |> List.filter (fun identity ->
        not (String.equal (String.lowercase_ascii (String.trim identity)) actor))
    in
    Ok (Board_signal_audience.thread_participants participants)
;;

let comment ~(post : Board.post) ~comments (comment : Board.comment) =
  let post_id = Board.Post_id.to_string post.id in
  let comment_post_id = Board.Post_id.to_string comment.post_id in
  if not (Float.is_finite post.updated_at) || post.reply_count < 0
  then
    Error
      (Board_types.Validation_error
         "Board comment command routing post snapshot is invalid")
  else if not (String.equal post_id comment_post_id)
  then
    Error
      (Board_types.Validation_error
         "Board comment command post differs from its routing post")
  else (
    match canonical_comment_of_yojson (Board.comment_to_yojson comment) with
    | Error detail -> Error (Board_types.Validation_error detail)
    | Ok canonical_comment ->
      Result.map
        (fun audience ->
           Comment
             { comment = canonical_comment
             ; routing_post = routing_post_snapshot_of_post post
             ; audience
             })
        (audience_for_thread_activity
           ~post
           ~comments
           ~actor:(Board.Agent_id.to_string canonical_comment.author)
           ~direct_content:canonical_comment.content))
;;

let reaction
      ~(post : Board.post)
      ~comments
      ~target_type
      ~target_id
      ~user_id
      ~emoji
      ~reacted
      ~created_at
  =
  let canonical_fields =
    let ( let* ) = Result.bind in
    let* () =
      if Float.is_finite created_at && Float.is_finite post.updated_at
      then Ok ()
      else Error (Board_types.Validation_error "Board reaction command time is not finite")
    in
    let* () =
      match target_type with
      | Board.Reaction_post -> Result.map (fun (_ : Board.Post_id.t) -> ()) (Board.Post_id.of_string target_id)
      | Board.Reaction_comment -> Result.map (fun (_ : Board.Comment_id.t) -> ()) (Board.Comment_id.of_string target_id)
    in
    let* canonical_user = Board.Agent_id.of_string user_id in
    let* canonical_emoji = Board.normalize_reaction_emoji emoji in
    Ok (Board.Agent_id.to_string canonical_user, canonical_emoji)
  in
  let ( let* ) = Result.bind in
  let* user_id, emoji = canonical_fields in
  let target_belongs_to_post =
    match target_type with
    | Board.Reaction_post ->
      String.equal target_id (Board.Post_id.to_string post.id)
    | Board.Reaction_comment ->
      List.exists
        (fun (comment : Board.comment) ->
           String.equal target_id (Board.Comment_id.to_string comment.id)
           && String.equal
                (Board.Post_id.to_string comment.post_id)
                (Board.Post_id.to_string post.id))
        comments
  in
  if post.reply_count < 0
  then
    Error
      (Board_types.Validation_error
         "Board reaction command routing post snapshot is invalid")
  else if not target_belongs_to_post
  then
    Error
      (Board_types.Validation_error
         "Board reaction command target differs from its routing post")
  else
    Result.map
      (fun audience ->
         Reaction
           { target_type
           ; target_id
           ; user_id
           ; emoji
           ; reacted
           ; created_at
           ; routing_post = routing_post_snapshot_of_post post
           ; audience
           })
      (audience_for_thread_activity
         ~post
         ~comments
         ~actor:user_id
         ~direct_content:"")
;;

let signal = function
  | Post { post; audience = _ } ->
    { kind = Board_post_created
    ; post_id = Board.Post_id.to_string post.id
    ; author = Board.Agent_id.to_string post.author
    ; title = post.title
    ; content = post.content
    ; hearth = post.hearth
    ; updated_at = Some post.updated_at
    }
  | Comment { comment; routing_post; audience = _ } ->
    { kind = Board_comment_added
    ; post_id = routing_post.post_id
    ; author = Board.Agent_id.to_string comment.author
    ; title = routing_post.title
    ; content = comment.content
    ; hearth = routing_post.hearth
    ; updated_at = Some comment.created_at
    }
  | Reaction
      { target_type
      ; target_id
      ; user_id
      ; emoji
      ; reacted
      ; created_at = _
      ; routing_post
      ; audience = _
      } ->
    { kind =
        Board_reaction_changed { target_type; target_id; user_id; emoji; reacted }
    ; post_id = routing_post.post_id
    ; author = user_id
    ; title = routing_post.title
    ; content = routing_post.content
    ; hearth = routing_post.hearth
    ; updated_at = Some routing_post.updated_at
    }
;;

let audience = function
  | Post { audience; _ }
  | Comment { audience; _ }
  | Reaction { audience; _ } -> audience
;;

let referenced_post_id = function
  | Post { post; _ } -> Board.Post_id.to_string post.id
  | Comment { routing_post; _ }
  | Reaction { routing_post; _ } -> routing_post.post_id
;;

let referenced_comment_id = function
  | Comment { comment; _ } -> Some (Board.Comment_id.to_string comment.id)
  | Reaction { target_type = Board.Reaction_comment; target_id; _ } -> Some target_id
  | Post _
  | Reaction { target_type = Board.Reaction_post; _ } -> None
;;

let apply store command =
  let application =
    match command with
    | Post { post; audience = _ } ->
      Result.map
        (fun (_ : Board.post Board.mutation_application) -> ())
        (Board.apply_prepared_post store post)
    | Comment { comment; routing_post; audience = _ } ->
      Result.map
        (fun (_ : Board.comment Board.mutation_application) -> ())
        (Board.apply_prepared_comment
           store
           ~parent_reply_count_before:routing_post.reply_count
           comment)
    | Reaction
        { target_type
        ; target_id
        ; user_id
        ; emoji
        ; reacted
        ; created_at
        ; routing_post = _
        ; audience = _
        } ->
      Result.map
        (fun (_ : Board.reaction_toggle_result) -> ())
        (Board.set_reaction
           store
           ~target_type
           ~target_id
           ~user_id
           ~emoji
           ~reacted
           ~created_at)
  in
  Result.map_error Board_types.show_board_error application
;;
