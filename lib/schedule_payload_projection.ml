(* TEL-OK: pure schedule payload projection/validation. Runtime telemetry for
   unsupported creation/dispatch lives at the tool/server caller boundaries. *)

type known_kind = Keeper_wake

type support_status =
  | Supported
  | Unsupported
  | Unknown

type creation_rejection =
  | Creation_invalid_payload of string
  | Creation_invalid_supported_payload of known_kind * string
  | Creation_unsupported_kind of string

type dispatch_rejection =
  | Dispatch_invalid_payload of string
  | Dispatch_invalid_supported_payload of known_kind * string
  | Dispatch_unsupported_kind of string

type payload_view =
  { raw_kind : string
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

let known_kind_to_string = function
  | Keeper_wake -> Schedule_supported_kinds.keeper_wake
;;

let dispatch_tool_name = function
  | Keeper_wake -> Schedule_supported_kinds.keeper_wake
;;

let known_kinds = [ Keeper_wake ]
let supported_payload_kinds = List.map known_kind_to_string known_kinds
let keeper_wake_kind = known_kind_to_string Keeper_wake

let support_status_to_string = function
  | Supported -> "supported"
  | Unsupported -> "unsupported"
  | Unknown -> "unknown"
;;

let creation_rejection_message = function
  | Creation_invalid_payload msg -> msg
  | Creation_invalid_supported_payload (_, msg) -> msg
  | Creation_unsupported_kind raw_kind ->
    Schedule_supported_kinds.unsupported_error raw_kind
;;

let dispatch_rejection_message = function
  | Dispatch_invalid_payload msg -> msg
  | Dispatch_invalid_supported_payload (_, msg) -> msg
  | Dispatch_unsupported_kind raw_kind ->
    "unsupported schedule payload kind: " ^ raw_kind
;;

let classify_kind = function
  | kind when String.equal kind (known_kind_to_string Keeper_wake) -> Some Keeper_wake
  | _ -> None
;;

let assoc_string key fields =
  match List.assoc_opt key fields with
  | Some (`String value) -> String_util.trim_nonempty value
  | _ -> None
;;

let remove_all_assoc key fields =
  List.filter (fun (name, _) -> not (String.equal name key)) fields
;;

let required_string_field name fields =
  match List.assoc_opt name fields with
  | Some (`String value) ->
    (match String_util.trim_nonempty value with
     | Some value -> Ok value
     | None -> Error (name ^ " must be non-empty"))
  | Some _ -> Error ("expected string field: " ^ name)
  | None -> Error ("missing field: " ^ name)
;;

let optional_string_field name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`String value) -> Ok (String_util.trim_nonempty value)
  | Some _ -> Error ("expected string field: " ^ name)
;;

let payload_view_of_json payload =
  match payload with
  | `Assoc fields ->
    let* raw_kind = required_string_field "kind" fields in
    let* body =
      match List.assoc_opt "body" fields with
      | Some (`Assoc body) -> Ok body
      | Some _ -> Error "payload.body must be an object"
      | None -> Error "missing field: body"
    in
    Ok { raw_kind; body }
  | _ -> Error "payload must be a JSON object"
;;

let payload_view (request : Schedule_domain.schedule_request) =
  Schedule_domain.payload_to_yojson request.payload |> payload_view_of_json
;;

let kind_of_json_result payload =
  let* view = payload_view_of_json payload in
  Ok view.raw_kind
;;

let result_delivery_of_body body =
  let ( let* ) = Result.bind in
  match List.assoc_opt "result_delivery" body with
  | None -> Ok None
  | Some (`Assoc fields) ->
    let names = List.map fst fields in
    if List.length names <> List.length (List.sort_uniq String.compare names)
    then Error (keeper_wake_kind ^ " body.result_delivery has duplicate fields")
    else
      (match List.assoc_opt "policy" fields with
       | Some (`String "none") ->
         if names = [ "policy" ]
         then Ok None
         else Error (keeper_wake_kind ^ " result_delivery none has unknown fields")
       | Some (`String "reply_to_origin") ->
         if
           List.sort String.compare names
           <> [ "channel"; "policy" ]
         then
           Error
             (keeper_wake_kind
              ^ " result_delivery reply_to_origin requires only policy and channel")
         else
           let* channel_json =
             match List.assoc_opt "channel" fields with
             | Some value -> Ok value
             | None -> Error (keeper_wake_kind ^ " result_delivery requires channel")
           in
           let* channel = Keeper_continuation_channel.of_yojson channel_json in
           if Keeper_continuation_channel.is_routable channel
           then Ok (Some channel)
           else Error (keeper_wake_kind ^ " result delivery channel must be routable")
       | Some (`String policy) ->
         Error (keeper_wake_kind ^ " unknown result_delivery policy " ^ policy)
       | Some _ | None ->
         Error (keeper_wake_kind ^ " result_delivery requires string policy"))
  | Some _ -> Error (keeper_wake_kind ^ " body.result_delivery must be an object")
;;

let set_keeper_wake_result_delivery ~payload ~channel =
  match payload with
  | `Assoc fields ->
    (match assoc_string "kind" fields with
     | Some raw_kind when classify_kind raw_kind = Some Keeper_wake ->
       (match List.assoc_opt "body" fields with
        | Some (`Assoc body) ->
          let channel =
            match channel with
            | Some channel when Keeper_continuation_channel.is_routable channel ->
              Some channel
            | Some _ | None -> None
          in
          let result_delivery =
            match channel with
            | None -> `Assoc [ "policy", `String "none" ]
            | Some channel ->
              `Assoc
                [ "policy", `String "reply_to_origin"
                ; "channel", Keeper_continuation_channel.to_yojson channel
                ]
          in
          let body =
            ("result_delivery", result_delivery)
            :: remove_all_assoc "result_delivery" body
          in
          Ok
            (`Assoc
               (("body", `Assoc body) :: remove_all_assoc "body" fields))
        | Some _ | None ->
          Error (keeper_wake_kind ^ " payload.body must be an object"))
     | Some _ -> Ok payload
     | None -> Error "payload.kind is required")
  | _ -> Error "payload must be a JSON object"
;;

(* Every field this contract reads. The body used to accept anything: an
   unknown key was persisted at creation and then dropped by the consumer,
   which is how a live schedule ended up carrying a channel_id that no
   dispatch ever saw (#25689). [result_delivery] already closed its own
   fields; this closes the body around it. *)
let keeper_wake_body_fields =
  [ "keeper_name"; "message"; "title"; "urgency"; "result_delivery" ]

let unknown_keeper_wake_body_fields body =
  List.filter
    (fun (name, _) ->
      not (List.exists (String.equal name) keeper_wake_body_fields))
    body
  |> List.map fst
  |> List.sort_uniq String.compare

let validate_keeper_wake_body body =
  let ( let* ) = Result.bind in
  let* () =
    match unknown_keeper_wake_body_fields body with
    | [] -> Ok ()
    | unknown ->
      Error
        (Printf.sprintf
           "%s payload body has unknown field(s): %s (known: %s)"
           keeper_wake_kind
           (String.concat ", " unknown)
           (String.concat ", " keeper_wake_body_fields))
  in
  let* _ = result_delivery_of_body body in
  match assoc_string "keeper_name" body, assoc_string "message" body with
  | None, _ -> Error (keeper_wake_kind ^ " payload requires non-empty body.keeper_name")
  | _, None -> Error (keeper_wake_kind ^ " payload requires non-empty body.message")
  | Some keeper_name, Some _
    when not (Schedule_supported_kinds.valid_keeper_wake_target_name keeper_name) ->
    Error
      (Schedule_supported_kinds.keeper_wake_target_name_error
         ~field:(keeper_wake_kind ^ " payload body.keeper_name"))
  | Some _, Some _ ->
    (match optional_string_field "urgency" body with
     | Error msg -> Error msg
     | Ok None -> Ok ()
     | Ok (Some raw) ->
       Schedule_supported_kinds.keeper_wake_urgency_of_string raw
       |> Result.map (fun _ -> ()))
;;


let validate_request_payload_for_creation_detailed ~payload =
  match payload with
  | `Assoc fields ->
    (match assoc_string "kind" fields with
     | Some raw_kind ->
       (match classify_kind raw_kind with
        | Some Keeper_wake ->
          let* body =
            match List.assoc_opt "body" fields with
            | Some (`Assoc body) -> Ok body
            | Some _ ->
              Error
                (Creation_invalid_supported_payload
                   (Keeper_wake, keeper_wake_kind ^ " payload.body must be an object"))
            | None ->
              Error
                (Creation_invalid_supported_payload
                   (Keeper_wake, keeper_wake_kind ^ " payload requires object body"))
          in
          validate_keeper_wake_body body
          |> Result.map_error (fun msg ->
            Creation_invalid_supported_payload (Keeper_wake, msg))
        | None -> Error (Creation_unsupported_kind raw_kind))
     | None -> Error (Creation_invalid_payload "payload.kind is required"))
  | _ -> Error (Creation_invalid_payload "payload must be a JSON object")
;;

let creation_keeper_wake_target ~payload =
  match payload with
  | `Assoc fields ->
    (match assoc_string "kind" fields with
     | Some raw_kind ->
       (match classify_kind raw_kind with
        | Some Keeper_wake ->
          (match List.assoc_opt "body" fields with
           | Some (`Assoc body) ->
             (match assoc_string "keeper_name" body with
              | Some keeper_name -> Ok (Some keeper_name)
              | None ->
                Error
                  (keeper_wake_kind ^ " payload requires non-empty body.keeper_name"))
           | Some _ | None -> Error (keeper_wake_kind ^ " payload.body must be an object"))
        | None -> Ok None)
     | None -> Error "payload.kind is required")
  | _ -> Error "payload must be a JSON object"
;;

let dispatch_view_detailed request =
  let* view =
    payload_view request |> Result.map_error (fun msg -> Dispatch_invalid_payload msg)
  in
  match classify_kind view.raw_kind with
  | Some Keeper_wake ->
    let* () =
      validate_keeper_wake_body view.body
      |> Result.map_error (fun msg ->
        Dispatch_invalid_supported_payload (Keeper_wake, msg))
    in
    Ok (Keeper_wake, view)
  | None -> Error (Dispatch_unsupported_kind view.raw_kind)
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
  | Keeper_wake ->
    `Assoc
      [ "kind", `String (known_kind_to_string kind)
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

let truncate_summary text =
  String.trim text
  |> String_util.utf8_safe ~max_bytes:160 ~suffix:"..."
  |> String_util.to_string
;;

let keeper_wake_keeper_name body = assoc_string "keeper_name" body

let keeper_wake_target body =
  match keeper_wake_keeper_name body with
  | Some keeper_name -> Some ("keeper:" ^ keeper_name)
  | None -> None
;;

let keeper_wake_summary body =
  match assoc_string "title" body, assoc_string "message" body with
  | Some title, _ -> Some (truncate_summary title)
  | None, Some message -> Some (truncate_summary message)
  | None, None -> None
;;

let target_summary_result (request : Schedule_domain.schedule_request) =
  match payload_view request with
  | Error msg -> Error msg
  | Ok view ->
    (match classify_kind view.raw_kind with
     | Some Keeper_wake -> Ok (keeper_wake_target view.body, keeper_wake_summary view.body)
     | None -> Ok (None, None))
;;

let target_summary request =
  match target_summary_result request with
  | Ok summary -> summary
  | Error msg ->
    log_projection_error request ~surface:"target_summary" msg;
    None, None
;;

let wake_keeper_name_result (request : Schedule_domain.schedule_request) =
  match payload_view request with
  | Error msg -> Error msg
  | Ok view ->
    (match classify_kind view.raw_kind with
     | Some Keeper_wake -> Ok (keeper_wake_keeper_name view.body)
     | None -> Ok None)
;;

let wake_keeper_name request =
  match wake_keeper_name_result request with
  | Ok name -> name
  | Error msg ->
    log_projection_error request ~surface:"wake_keeper_name" msg;
    None
;;

let result_delivery request =
  let ( let* ) = Result.bind in
  let* view = payload_view request in
  match classify_kind view.raw_kind with
  | Some Keeper_wake -> result_delivery_of_body view.body
  | None -> Ok None
;;

let body_required_string view name = required_string_field name view.body
let body_optional_string view name = optional_string_field name view.body
let body_result_delivery view = result_delivery_of_body view.body
