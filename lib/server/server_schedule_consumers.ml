(* TEL-OK: concrete scheduled consumer details are returned to
   [Schedule_runner] and persisted as execution records; the server maintenance
   loop logs aggregate dispatch counts for runtime telemetry. *)

let supported_payload_kinds = [ "masc.board_post" ]

let ( let* ) = Result.bind

let assoc_field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error ("missing field: " ^ name)
;;

let string_field name fields =
  let* value = assoc_field name fields in
  match value with
  | `String value when String.trim value <> "" -> Ok value
  | `String _ -> Error (name ^ " must be non-empty")
  | _ -> Error ("expected string field: " ^ name)
;;

let optional_string_field name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`String value) ->
    let value = String.trim value in
    if String.equal value "" then Ok None else Ok (Some value)
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

type payload_view =
  { kind : string
  ; schema_version : int
  ; body : (string * Yojson.Safe.t) list
  }

let payload_view (request : Schedule_domain.schedule_request) =
  match Schedule_domain.payload_to_yojson request.payload with
  | `Assoc fields ->
    let* kind = string_field "kind" fields in
    let* schema_version =
      match List.assoc_opt "schema_version" fields with
      | Some (`Int value) -> Ok value
      | Some _ -> Error "expected int field: schema_version"
      | None -> Error "missing field: schema_version"
    in
    let* body =
      match List.assoc_opt "body" fields with
      | Some (`Assoc fields) -> Ok fields
      | Some _ -> Error "payload.body must be an object"
      | None -> Error "missing field: body"
    in
    Ok { kind; schema_version; body }
  | _ -> Error "payload must be an object"
;;

let accepts_board_post (request : Schedule_domain.schedule_request) payload =
  if not (String.equal payload.kind "masc.board_post") then
    Error ("unsupported schedule payload kind: " ^ payload.kind)
  else if payload.schema_version <> 1 then
    Error "masc.board_post only supports schema_version=1"
  else if not (Schedule_domain.is_side_effecting request.risk_class) then
    Error "masc.board_post requires a side-effecting risk_class"
  else
    let* _content = string_field "content" payload.body in
    let* ttl_hours = optional_int_field "ttl_hours" payload.body in
    match ttl_hours with
    | Some ttl when ttl < 0 -> Error "ttl_hours must be non-negative"
    | _ -> Ok ()
;;

let accepts request =
  let* payload = payload_view request in
  accepts_board_post request payload
;;

let schedule_meta_json (request : Schedule_domain.schedule_request) payload user_meta =
  let base =
    [ "source", `String "scheduled_automation"
    ; "schedule_id", `String request.schedule_id
    ; "payload_kind", `String payload.kind
    ; "payload_digest", `String (Schedule_domain.payload_digest request.payload)
    ; "requested_by", `String request.requested_by.id
    ; "scheduled_by", `String request.scheduled_by.id
    ; "risk_class", `String (Schedule_domain.risk_class_to_string request.risk_class)
    ; "due_at", `Float request.due_at
    ]
  in
  match user_meta with
  | None -> `Assoc base
  | Some meta -> `Assoc (base @ [ "payload_meta", meta ])
;;

let dispatch_board_post request payload =
  let* content = string_field "content" payload.body in
  let* title = optional_string_field "title" payload.body in
  let* author = optional_string_field "author" payload.body in
  let* hearth = optional_string_field "hearth" payload.body in
  let* thread_id = optional_string_field "thread_id" payload.body in
  let* ttl_hours = optional_int_field "ttl_hours" payload.body in
  let* user_meta = optional_assoc_field "meta" payload.body in
  let author =
    (* DET-OK: absent board-post author maps to the stable scheduled automation
       actor label for auditability. *)
    match author with
    | None -> "schedule-bot"
    | Some author -> author
  in
  let meta_json = schedule_meta_json request payload user_meta in
  match
    Board_dispatch.create_post ~author ~content ?title ~post_kind:Board.System_post
      ~meta_json ~visibility:Board.Internal ?ttl_hours ?hearth ?thread_id ()
  with
  | Error err -> Error (Board_types.show_board_error err)
  | Ok post ->
    let post_id = Board.Post_id.to_string post.id in
    Ok
      (`Assoc
        [ "kind", `String "masc.board_post.created"
        ; "post_id", `String post_id
        ; "author", `String author
        ; ( "hearth"
          , match hearth with
            | None -> `Null
            | Some hearth -> `String hearth )
        ])
;;

let dispatch request =
  let* payload = payload_view request in
  let* () = accepts_board_post request payload in
  dispatch_board_post request payload
;;

let consumer : Schedule_runner.consumer = { accepts; dispatch }
