type known_kind = Board_post

type support_status =
  | Supported
  | Unsupported
  | Unknown

type creation_rejection =
  | Creation_invalid_payload of string
  | Creation_invalid_supported_payload of known_kind * string
  | Creation_unsupported_side_effecting_kind of string

type dispatch_rejection =
  | Dispatch_invalid_payload of string
  | Dispatch_invalid_supported_payload of known_kind * string
  | Dispatch_unsupported_kind of string

type payload_view =
  { raw_kind : string
  ; schema_version : int
  ; body : (string * Yojson.Safe.t) list
  }

type unsupported_kind_count =
  { raw_kind : string
  ; count : int
  }

type support_summary =
  { supported_kinds : string list
  ; unsupported_request_count : int
  ; unsupported_kinds : unsupported_kind_count list
  ; unknown_request_count : int
  }

let ( let* ) = Result.bind

let trim_nonempty value =
  let trimmed = String.trim value in
  if String.equal trimmed "" then None else Some trimmed
;;

let known_kind_to_string = function
  | Board_post -> Schedule_supported_kinds.board_post
;;

let dispatch_tool_name = function
  | Board_post -> Tool_name.Board_name.(to_string Board_post)
;;

let known_kinds = [ Board_post ]
let supported_payload_kinds = List.map known_kind_to_string known_kinds
let board_post_kind = known_kind_to_string Board_post

let support_status_to_string = function
  | Supported -> "supported"
  | Unsupported -> "unsupported"
  | Unknown -> "unknown"
;;

let creation_rejection_message = function
  | Creation_invalid_payload msg -> msg
  | Creation_invalid_supported_payload (_, msg) -> msg
  | Creation_unsupported_side_effecting_kind raw_kind ->
    Schedule_supported_kinds.unsupported_error raw_kind
;;

let dispatch_rejection_message = function
  | Dispatch_invalid_payload msg -> msg
  | Dispatch_invalid_supported_payload (_, msg) -> msg
  | Dispatch_unsupported_kind raw_kind ->
    "unsupported schedule payload kind: " ^ raw_kind
;;

let classify_kind = function
  | kind when String.equal kind (known_kind_to_string Board_post) -> Some Board_post
  | _ -> None
;;

let assoc_string key fields =
  match List.assoc_opt key fields with
  | Some (`String value) -> trim_nonempty value
  | _ -> None
;;

let required_string_field name fields =
  match List.assoc_opt name fields with
  | Some (`String value) ->
    (match trim_nonempty value with
     | Some value -> Ok value
     | None -> Error (name ^ " must be non-empty"))
  | Some _ -> Error ("expected string field: " ^ name)
  | None -> Error ("missing field: " ^ name)
;;

let optional_string_field name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`String value) -> Ok (trim_nonempty value)
  | Some _ -> Error ("expected string field: " ^ name)
;;

let optional_int_field name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`Int value) -> Ok (Some value)
  | Some _ -> Error ("expected int field: " ^ name)
;;

let optional_assoc_field name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`Assoc _ as value) -> Ok (Some value)
  | Some _ -> Error ("expected object field: " ^ name)
;;

let payload_view_of_json payload =
  match payload with
  | `Assoc fields ->
    let* raw_kind = required_string_field "kind" fields in
    let* schema_version =
      match List.assoc_opt "schema_version" fields with
      | Some (`Int value) -> Ok value
      | Some _ -> Error "expected int field: schema_version"
      | None -> Error "missing field: schema_version"
    in
    let* body =
      match List.assoc_opt "body" fields with
      | Some (`Assoc body) -> Ok body
      | Some _ -> Error "payload.body must be an object"
      | None -> Error "missing field: body"
    in
    Ok { raw_kind; schema_version; body }
  | _ -> Error "payload must be a JSON object"
;;

let payload_view (request : Schedule_domain.schedule_request) =
  Schedule_domain.payload_to_yojson request.payload |> payload_view_of_json
;;

let kind_of_json_result payload =
  let* view = payload_view_of_json payload in
  Ok view.raw_kind
;;

let board_schema_version_error ~creation schema_version =
  if schema_version = 1
  then Ok ()
  else if creation
  then Error (board_post_kind ^ " only supports payload_schema_version=1")
  else Error (board_post_kind ^ " only supports schema_version=1")
;;

let validate_board_post_common ~content_error view =
  let* _content =
    match assoc_string "content" view.body with
    | Some content -> Ok content
    | None -> Error content_error
  in
  let* ttl_hours = optional_int_field "ttl_hours" view.body in
  match ttl_hours with
  | Some ttl when ttl < 0 -> Error "ttl_hours must be non-negative"
  | _ -> Ok ()
;;

let validate_board_post_for_creation ~risk_class view =
  let* () = board_schema_version_error ~creation:true view.schema_version in
  if not (Schedule_domain.is_side_effecting risk_class)
  then
    Error
      (board_post_kind
       ^ " requires a side-effecting risk_class such as workspace_write")
  else
    validate_board_post_common
      ~content_error:
        (board_post_kind
         ^ " payload requires non-empty body.content; use board_content for board schedules")
      view
;;

let validate_board_post_for_dispatch request view =
  let* () = board_schema_version_error ~creation:false view.schema_version in
  if not (Schedule_domain.is_side_effecting request.Schedule_domain.risk_class)
  then Error (board_post_kind ^ " requires a side-effecting risk_class")
  else
    validate_board_post_common
      ~content_error:"missing field: content"
      view
;;

let validate_request_payload_for_creation_detailed ~payload ~risk_class =
  match payload with
  | `Assoc fields ->
    (match assoc_string "kind" fields with
     | Some raw_kind ->
       (match classify_kind raw_kind with
        | Some Board_post ->
          let* schema_version =
            match List.assoc_opt "schema_version" fields with
            | Some (`Int value) -> Ok value
            | Some _ ->
              Error
                (Creation_invalid_supported_payload
                   ( Board_post
                   , board_post_kind ^ " payload.schema_version must be an integer" ))
            | None ->
              Error
                (Creation_invalid_supported_payload
                   (Board_post, board_post_kind ^ " payload requires schema_version=1"))
          in
          let* body =
            match List.assoc_opt "body" fields with
            | Some (`Assoc body) -> Ok body
            | Some _ ->
              Error
                (Creation_invalid_supported_payload
                   (Board_post, board_post_kind ^ " payload.body must be an object"))
            | None ->
              Error
                (Creation_invalid_supported_payload
                   ( Board_post
                   , board_post_kind
                     ^ " payload requires object body with non-empty content; use board_content for board schedules"
                   ))
          in
          validate_board_post_for_creation ~risk_class
            { raw_kind; schema_version; body }
          |> Result.map_error (fun msg ->
            Creation_invalid_supported_payload (Board_post, msg))
        | None when Schedule_domain.is_side_effecting risk_class ->
          Error (Creation_unsupported_side_effecting_kind raw_kind)
        | None -> Ok ())
     | None -> Error (Creation_invalid_payload "payload.kind is required"))
  | _ -> Error (Creation_invalid_payload "payload must be a JSON object")
;;

let validate_request_payload_for_creation ~payload ~risk_class =
  validate_request_payload_for_creation_detailed ~payload ~risk_class
  |> Result.map_error creation_rejection_message
;;

let dispatch_view_detailed request =
  let* view =
    payload_view request |> Result.map_error (fun msg -> Dispatch_invalid_payload msg)
  in
  match classify_kind view.raw_kind with
  | Some Board_post ->
    let* () =
      validate_board_post_for_dispatch request view
      |> Result.map_error (fun msg ->
        Dispatch_invalid_supported_payload (Board_post, msg))
    in
    Ok (Board_post, view)
  | None -> Error (Dispatch_unsupported_kind view.raw_kind)
;;

let dispatch_view request =
  dispatch_view_detailed request |> Result.map_error dispatch_rejection_message
;;

let log_projection_error (request : Schedule_domain.schedule_request) ~surface message =
  Log.Misc.warn
    "schedule_payload_projection.%s failed schedule_id=%s: %s"
    surface
    request.schedule_id
    message
;;

let support_status_result request =
  match payload_view request with
  | Error msg -> Error msg
  | Ok view ->
    (match classify_kind view.raw_kind with
     | Some _ -> Ok Supported
     | None -> Ok Unsupported)
;;

let support_status request =
  match support_status_result request with
  | Ok status -> status
  | Error msg ->
    log_projection_error request ~surface:"support_status" msg;
    Unknown
;;

let kind_result (request : Schedule_domain.schedule_request) =
  Schedule_domain.payload_to_yojson request.payload |> kind_of_json_result
;;

let kind request =
  match kind_result request with
  | Ok raw_kind -> Some raw_kind
  | Error msg ->
    log_projection_error request ~surface:"kind" msg;
    None
;;

let dispatch_tool_for_request_result request =
  match dispatch_view_detailed request with
  | Ok (kind, _) -> Ok (dispatch_tool_name kind)
  | Error err -> Error err
;;

let dispatch_tool_for_request request =
  match dispatch_tool_for_request_result request with
  | Ok tool_name -> Some tool_name
  | Error err ->
    log_projection_error
      request
      ~surface:"dispatch_tool_for_request"
      (dispatch_rejection_message err);
    None
;;

let known_kind_contract_to_yojson kind =
  match kind with
  | Board_post ->
    `Assoc
      [ "kind", `String (known_kind_to_string kind)
      ; "schema_versions", `List [ `Int 1 ]
      ; "dispatch_tool", `String (dispatch_tool_name kind)
      ; "side_effecting_risk_required", `Bool true
      ; "creation_contract", `String "per_kind_validator_required"
      ; "dispatch_contract", `String "consumer_supported"
      ]
;;

let supported_contracts_to_yojson () =
  `List (List.map known_kind_contract_to_yojson known_kinds)
;;

let support_summary schedules =
  let bump kind counts =
    let rec loop acc = function
      | [] -> List.rev ((kind, 1) :: acc)
      | (existing, count) :: rest when String.equal existing kind ->
        List.rev_append acc ((existing, count + 1) :: rest)
      | item :: rest -> loop (item :: acc) rest
    in
    loop [] counts
  in
  let unsupported_request_count, unknown_request_count, unsupported_kinds =
    List.fold_left
      (fun (unsupported_count, unknown_count, kind_counts)
        (request : Schedule_domain.schedule_request) ->
         match support_status request with
         | Supported -> unsupported_count, unknown_count, kind_counts
         | Unsupported ->
           (match kind request with
            | Some raw_kind ->
              unsupported_count + 1, unknown_count, bump raw_kind kind_counts
            | None -> unsupported_count, unknown_count + 1, kind_counts)
         | Unknown -> unsupported_count, unknown_count + 1, kind_counts)
      (0, 0, [])
      schedules
  in
  let unsupported_kinds =
    unsupported_kinds
    |> List.sort (fun (left_kind, left_count) (right_kind, right_count) ->
      match compare right_count left_count with
      | 0 -> String.compare left_kind right_kind
      | order -> order)
    |> List.map (fun (raw_kind, count) -> { raw_kind; count })
  in
  let supported_kinds = List.sort_uniq String.compare supported_payload_kinds in
  { supported_kinds
  ; unsupported_request_count
  ; unsupported_kinds
  ; unknown_request_count
  }
;;

let support_summary_yojson summary =
  `Assoc
    [ ( "supported_kinds"
      , `List
          (List.map (fun raw_kind -> `String raw_kind) summary.supported_kinds)
      )
    ; "supported_contracts", supported_contracts_to_yojson ()
    ; "unsupported_request_count", `Int summary.unsupported_request_count
    ; ( "unsupported_kinds"
      , `List
          (List.map
             (fun { raw_kind; count } ->
                `Assoc [ "kind", `String raw_kind; "count", `Int count ])
             summary.unsupported_kinds) )
    ; "unknown_request_count", `Int summary.unknown_request_count
    ]
;;

let support_summary_to_yojson schedules =
  schedules |> support_summary |> support_summary_yojson
;;

let board_target body =
  match assoc_string "thread_id" body, assoc_string "hearth" body with
  | Some thread_id, _ -> Some ("thread:" ^ thread_id)
  | None, Some hearth -> Some ("hearth:" ^ hearth)
  | None, None -> Some "board:default"
;;

let truncate_summary text =
  String.trim text
  |> String_util.utf8_safe ~max_bytes:160 ~suffix:"..."
  |> String_util.to_string
;;

let board_summary body =
  match assoc_string "title" body, assoc_string "content" body with
  | Some title, _ -> Some (truncate_summary title)
  | None, Some content -> Some (truncate_summary content)
  | None, None -> None
;;

let target_summary_result (request : Schedule_domain.schedule_request) =
  match payload_view request with
  | Error msg -> Error msg
  | Ok view ->
    (match classify_kind view.raw_kind with
     | Some Board_post -> Ok (board_target view.body, board_summary view.body)
     | None -> Ok (None, None))
;;

let target_summary request =
  match target_summary_result request with
  | Ok summary -> summary
  | Error msg ->
    log_projection_error request ~surface:"target_summary" msg;
    None, None
;;

let view_kind (view : payload_view) = view.raw_kind
let view_schema_version (view : payload_view) = view.schema_version
let body_required_string view name = required_string_field name view.body
let body_optional_string view name = optional_string_field name view.body
let body_optional_int view name = optional_int_field name view.body
let body_optional_assoc view name = optional_assoc_field name view.body
