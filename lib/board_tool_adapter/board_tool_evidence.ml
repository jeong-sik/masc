open Masc_board_handlers

type t =
  | Comment_added of
      { post_id : string
      ; comment_id : string
      ; parent_id : string option
      ; author : string
      }
  | Reaction_changed of
      { post_id : string
      ; target_type : Board.reaction_target_type
      ; target_id : string
      ; user_id : string
      ; emoji : string
      ; reacted : bool
      }

let schema = "masc.board-action-evidence/v1"
let metadata_key = "masc.board_action_evidence"

let comment (value : Board.comment) =
  Comment_added
    { post_id = Board.Post_id.to_string value.post_id
    ; comment_id = Board.Comment_id.to_string value.id
    ; parent_id = Option.map Board.Comment_id.to_string value.parent_id
    ; author = Board.Agent_id.to_string value.author
    }

let reaction ~post_id (value : Board.reaction_toggle_result) =
  Reaction_changed
    { post_id = Board.Post_id.to_string post_id
    ; target_type = value.target_type
    ; target_id = value.target_id
    ; user_id = value.user_id
    ; emoji = value.emoji
    ; reacted = value.reacted
    }

let to_yojson = function
  | Comment_added value ->
    `Assoc
      [ "schema", `String schema
      ; "kind", `String "comment_added"
      ; "post_id", `String value.post_id
      ; "comment_id", `String value.comment_id
      ; "parent_id", (match value.parent_id with None -> `Null | Some id -> `String id)
      ; "author", `String value.author
      ]
  | Reaction_changed value ->
    `Assoc
      [ "schema", `String schema
      ; "kind", `String "reaction_changed"
      ; "post_id", `String value.post_id
      ; "target_type", `String (Board.reaction_target_type_to_string value.target_type)
      ; "target_id", `String value.target_id
      ; "user_id", `String value.user_id
      ; "emoji", `String value.emoji
      ; "reacted", `Bool value.reacted
      ]

let ( let* ) = Result.bind

let text name fields =
  match List.assoc_opt name fields with
  | Some (`String value) when String.trim value <> "" -> Ok value
  | Some _ | None -> Error ("Board evidence requires " ^ name)

let exact_fields expected fields =
  if List.sort String.compare (List.map fst fields) = List.sort String.compare expected
  then Ok ()
  else Error "Board evidence fields are missing, duplicated or unknown"

let canonical parse print value =
  match parse value with
  | Ok id when String.equal (print id) value -> Ok value
  | Ok _ | Error _ -> Error "Board evidence has a non-canonical identity"

let post_id = canonical Board.Post_id.of_string Board.Post_id.to_string
let comment_id = canonical Board.Comment_id.of_string Board.Comment_id.to_string
let agent_id = canonical Board.Agent_id.parse Board.Agent_id.to_string

let of_yojson = function
  | `Assoc fields ->
    let* received_schema = text "schema" fields in
    if not (String.equal received_schema schema)
    then Error "Board evidence schema is unsupported"
    else
      let* kind = text "kind" fields in
      let* raw_post = text "post_id" fields in
      let* post_id = post_id raw_post in
      (match kind with
       | "comment_added" ->
         let* () = exact_fields
             [ "schema"; "kind"; "post_id"; "comment_id"; "parent_id"; "author" ] fields in
         let* raw_comment = text "comment_id" fields in
         let* id = comment_id raw_comment in
         let* raw_author = text "author" fields in
         let* author = agent_id raw_author in
         let* parent_id =
           match List.assoc_opt "parent_id" fields with
           | Some `Null -> Ok None
           | Some (`String value) -> Result.map Option.some (comment_id value)
           | Some _ | None -> Error "Board evidence parent identity is invalid"
         in
         Ok (Comment_added { post_id; comment_id = id; parent_id; author })
       | "reaction_changed" ->
         let* () = exact_fields
             [ "schema"; "kind"; "post_id"; "target_type"; "target_id"
             ; "user_id"; "emoji"; "reacted" ] fields in
         let* raw_type = text "target_type" fields in
         let* target_type =
           match Board.reaction_target_type_of_string_opt raw_type with
           | Some value -> Ok value
           | None -> Error "Board evidence reaction target is invalid"
         in
         let* raw_target = text "target_id" fields in
         let* target_id =
           match target_type with
           | Board.Reaction_post ->
             let* target = canonical Board.Post_id.of_string Board.Post_id.to_string raw_target in
             if String.equal target post_id then Ok target
             else Error "Board evidence reaction post does not match its target"
           | Board.Reaction_comment -> comment_id raw_target
         in
         let* raw_user = text "user_id" fields in
         let* user_id = agent_id raw_user in
         let* emoji = text "emoji" fields in
         let* () =
           if List.exists (String.equal emoji) Board.board_reaction_emojis then Ok ()
           else Error "Board evidence reaction emoji is invalid"
         in
         let* reacted =
           match List.assoc_opt "reacted" fields with
           | Some (`Bool value) -> Ok value
           | Some _ | None -> Error "Board evidence reaction state is invalid"
         in
         Ok (Reaction_changed { post_id; target_type; target_id; user_id; emoji; reacted })
       | _ -> Error "Board evidence action is unsupported")
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error "Board evidence must be an object"

let metadata evidence = `Assoc [ metadata_key, to_yojson evidence ]

let with_metadata evidence previous =
  let fields = match previous with
    | Some (`Assoc fields) ->
      List.filter (fun (key, _) -> not (String.equal key metadata_key)) fields
    | Some value -> [ "producer", value ]
    | None -> [] in
  let value = match evidence with
    | Ok evidence -> to_yojson evidence
    | Error _ -> `Assoc [ "schema", `String schema; "kind", `String "invalid" ] in
  `Assoc ((metadata_key, value) :: fields)

let of_metadata metadata =
  let rec find = function
    | `Assoc fields ->
      (match List.filter (fun (key, _) -> String.equal key metadata_key) fields with
       | [ _, value ] -> Some (of_yojson value)
       | _ :: _ -> Some (Error "Board evidence metadata is duplicated")
       | [] ->
         (match List.filter (fun (key, _) -> String.equal key "producer") fields with
          | [ _, value ] -> find value
          | _ :: _ -> Some (Error "Board evidence producer metadata is duplicated")
          | [] -> None))
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
  in
  Option.bind metadata find

let for_tool ~tool_name evidence =
  let open Tool_name.Board_name in
  match evidence with
  | Error _ as error -> error
  | Ok evidence ->
    (match of_string tool_name with
     | Some Board_comment ->
       (match evidence with
        | Comment_added _ -> Ok evidence
        | Reaction_changed _ -> Error "Board comment producer returned another write kind")
     | Some Board_reaction ->
       (match evidence with
        | Reaction_changed _ -> Ok evidence
        | Comment_added _ -> Error "Board reaction producer returned another write kind")
     | Some (Board_post | Board_post_update | Board_list | Board_post_get
            | Board_vote | Board_stats | Board_search | Board_comment_vote
            | Board_profile | Board_hearths | Board_curation_read | Board_curation_submit
            | Board_delete | Board_cleanup | Board_close | Board_reopen
            | Board_sub_board_create | Board_sub_board_list | Board_sub_board_get
            | Board_sub_board_update | Board_sub_board_delete)
     | None -> Error "Board evidence has no matching host write producer")
