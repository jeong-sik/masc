open Result.Syntax

type target =
  { target_type : Board.reaction_target_type
  ; target_id : string
  }

type toggle_request =
  { target : target
  ; emoji : string
  }

type error_code =
  | Invalid_json
  | Missing_field
  | Invalid_target_type
  | Invalid_id
  | Post_not_found
  | Comment_not_found
  | Rate_limited
  | Capacity_exceeded
  | Io_error
  | Validation_error
  | Already_voted
  | Already_exists
  | Unauthorized

type http_status =
  [ `Bad_request
  | `Conflict
  | `Forbidden
  | `Internal_server_error
  | `Not_found
  | `Too_many_requests
  ]

type error =
  { code : error_code
  ; message : string
  ; status : http_status
  ; details : (string * Yojson.Safe.t) list
  }

let error_code_to_string = function
  | Invalid_json -> "invalid_json"
  | Missing_field -> "missing_field"
  | Invalid_target_type -> "invalid_target_type"
  | Invalid_id -> "invalid_id"
  | Post_not_found -> "post_not_found"
  | Comment_not_found -> "comment_not_found"
  | Rate_limited -> "rate_limited"
  | Capacity_exceeded -> "capacity_exceeded"
  | Io_error -> "io_error"
  | Validation_error -> "validation_error"
  | Already_voted -> "already_voted"
  | Already_exists -> "already_exists"
  | Unauthorized -> "unauthorized"
;;

let make_error ?(details = []) ~code ~status message =
  { code; message; status; details }
;;

let malformed_json message =
  make_error
    ~code:Invalid_json
    ~status:`Bad_request
    ("Board reaction request is not valid JSON: " ^ message)
;;

let required_nonempty field value =
  match Option.map String.trim value with
  | Some value when not (String.equal value "") -> Ok value
  | Some _ | None ->
    Error
      (make_error
         ~code:Missing_field
         ~status:`Bad_request
         (field ^ " is required"))
;;

let target_of_strings ~target_type ~target_id =
  let* target_type = required_nonempty "target_type" target_type in
  let* target_id = required_nonempty "target_id" target_id in
  match Board.reaction_target_type_of_string_opt target_type with
  | Some target_type -> Ok { target_type; target_id }
  | None ->
    Error
      (make_error
         ~code:Invalid_target_type
         ~status:`Bad_request
         (Printf.sprintf
            "target_type must be one of: %s"
            (String.concat ", " Board.valid_reaction_target_type_strings)))
;;

let toggle_request_of_json = function
  | `Assoc _ as json ->
    let* target =
      target_of_strings
        ~target_type:(Json_util.get_string json "target_type")
        ~target_id:(Json_util.get_string json "target_id")
    in
    let+ emoji = required_nonempty "emoji" (Json_util.get_string json "emoji") in
    { target; emoji }
  | `Null
  | `Bool _
  | `Int _
  | `Intlit _
  | `Float _
  | `String _
  | `List _
  | `Tuple _
  | `Variant _ ->
    Error
      (make_error
         ~code:Invalid_json
         ~status:`Bad_request
         "Board reaction request must be a JSON object")
;;

let status_of_board_error = function
  | Board.Invalid_id _
  | Board.Validation_error _ -> `Bad_request
  | Board.Already_voted _ | Board.Already_exists _ -> `Conflict
  | Board.Post_not_found _ | Board.Comment_not_found _ -> `Not_found
  | Board.Rate_limited _ | Board.Capacity_exceeded _ -> `Too_many_requests
  | Board.Unauthorized _ -> `Forbidden
  | Board.Io_error _ -> `Internal_server_error
;;

let code_and_details_of_board_error = function
  | Board.Invalid_id _ -> Invalid_id, []
  | Board.Post_not_found _ -> Post_not_found, []
  | Board.Comment_not_found _ -> Comment_not_found, []
  | Board.Rate_limited { retry_after } ->
    Rate_limited, [ "retry_after_seconds", `Float retry_after ]
  | Board.Capacity_exceeded { current; max } ->
    Capacity_exceeded, [ "current", `Int current; "max", `Int max ]
  | Board.Io_error _ -> Io_error, []
  | Board.Validation_error _ -> Validation_error, []
  | Board.Already_voted _ -> Already_voted, []
  | Board.Already_exists _ -> Already_exists, []
  | Board.Unauthorized _ -> Unauthorized, []
;;

let of_board_error board_error =
  let code, details = code_and_details_of_board_error board_error in
  let message =
    match board_error with
    | Board.Io_error detail ->
      Log.Server.error "Board reaction storage operation failed: %s" detail;
      "Board reaction storage operation failed"
    | _ -> Board_tool.board_error_to_string board_error
  in
  make_error
    ~code
    ~details
    ~status:(status_of_board_error board_error)
    message
;;

let supported_reaction_emojis_json () =
  `List (List.map (fun emoji -> `String emoji) Board.board_reaction_emojis)
;;

let catalog_json () =
  `Assoc [ "supported_reaction_emojis", supported_reaction_emojis_json () ]
;;

let reaction_state_json summaries =
  `Assoc
    [ ( "reactions"
      , `List (List.map Board.reaction_summary_to_yojson summaries) )
    ; "supported_reaction_emojis", supported_reaction_emojis_json ()
    ]
;;

let list_json ~actor target =
  Board_dispatch.list_reactions
    ~target_type:target.target_type
    ~target_id:target.target_id
    ~user_id:actor
    ()
  |> Result.map reaction_state_json
  |> Result.map_error of_board_error
;;

let toggle_json ~actor request =
  Board_dispatch.toggle_reaction
    ~target_type:request.target.target_type
    ~target_id:request.target.target_id
    ~user_id:actor
    ~emoji:request.emoji
  |> Result.map Board.reaction_toggle_result_to_yojson
  |> Result.map_error of_board_error
;;

let error_status error = error.status

let error_json error =
  Tool_args.error_assoc
    ([ "error_code", `String (error_code_to_string error.code)
     ; "message", `String error.message
     ]
     @ error.details)
;;
