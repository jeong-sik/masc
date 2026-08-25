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

(* A page of the board asks about its rows together. The board list is a
   public, cached projection and reaction state is per viewer -- whether *you*
   reacted -- so the two cannot travel in one response, and the surface was
   asking once per row: twenty of the twenty-three requests that opening the
   board made. The cap is the page size the board list itself clamps to, so a
   caller cannot ask about more rows than it can be handed. *)
let batch_target_limit = 500

let targets_of_strings ~target_type ~target_ids =
  let* target_type = required_nonempty "target_type" target_type in
  let* target_ids = required_nonempty "target_ids" target_ids in
  match Board.reaction_target_type_of_string_opt target_type with
  | None ->
    Error
      (make_error
         ~code:Invalid_target_type
         ~status:`Bad_request
         (Printf.sprintf
            "target_type must be one of: %s"
            (String.concat ", " Board.valid_reaction_target_type_strings)))
  | Some target_type ->
    let ids =
      String.split_on_char ',' target_ids
      |> List.map String.trim
      |> List.filter (fun id -> not (String.equal id ""))
    in
    let count = List.length ids in
    if count = 0
    then
      Error
        (make_error
           ~code:Missing_field
           ~status:`Bad_request
           "target_ids must hold at least one id")
    else if count > batch_target_limit
    then
      Error
        (make_error
           ~code:Validation_error
           ~status:`Bad_request
           (Printf.sprintf
              "target_ids holds %d ids; at most %d are answered at once"
              count
              batch_target_limit))
    else Ok (List.map (fun target_id -> { target_type; target_id }) ids)
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
  | `List _ ->
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
  | Board.Unauthorized _ -> `Forbidden
  | Board.Io_error _ -> `Internal_server_error
;;

let code_and_details_of_board_error = function
  | Board.Invalid_id _ -> Invalid_id, []
  | Board.Post_not_found _ -> Post_not_found, []
  | Board.Comment_not_found _ -> Comment_not_found, []
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

(* Keyed by the id the caller asked about so a row it did not ask for cannot
   be read as an answer, and so an id the store has nothing for still comes
   back -- as an empty list rather than a gap the caller has to guess at. *)
let list_batch_json ~actor targets =
  let rows =
    Board_dispatch.list_reactions_batch
      ~targets:
        (List.map (fun target -> (target.target_type, target.target_id)) targets)
      ~user_id:actor
      ()
  in
  let summaries_for =
    let table = Hashtbl.create (List.length rows) in
    List.iter (fun (key, summaries) -> Hashtbl.replace table key summaries) rows;
    fun target ->
      Hashtbl.find_opt table (target.target_type, target.target_id)
      |> Option.value ~default:[]
  in
  `Assoc
    [ ( "targets"
      , `List
          (List.map
             (fun target ->
                `Assoc
                  [ "target_id", `String target.target_id
                  ; ( "reactions"
                    , `List
                        (List.map
                           Board.reaction_summary_to_yojson
                           (summaries_for target)) )
                  ])
             targets) )
    ; "supported_reaction_emojis", supported_reaction_emojis_json ()
    ]
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
