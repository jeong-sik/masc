(* TEL-OK: concrete scheduled consumer details are returned to
   [Schedule_runner] and persisted as execution records; the server maintenance
   loop logs aggregate dispatch counts for runtime telemetry. *)

let supported_payload_kinds = Schedule_supported_kinds.supported

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

let optional_keeper_wake_urgency_field name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`String value) ->
    let* urgency =
      Schedule_supported_kinds.keeper_wake_urgency_of_string (String.trim value)
    in
    Ok (Some urgency)
  | Some _ -> Error ("expected string field: " ^ name)
;;

let keeper_queue_urgency_of_schedule_urgency = function
  | Schedule_supported_kinds.Keeper_wake_immediate -> Keeper_event_queue.Immediate
  | Schedule_supported_kinds.Keeper_wake_normal -> Keeper_event_queue.Normal
  | Schedule_supported_kinds.Keeper_wake_low -> Keeper_event_queue.Low
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
  if not (String.equal payload.kind Schedule_supported_kinds.board_post) then
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

let accepts_keeper_wake (request : Schedule_domain.schedule_request) payload =
  if not (String.equal payload.kind Schedule_supported_kinds.keeper_wake) then
    Error ("unsupported schedule payload kind: " ^ payload.kind)
  else if payload.schema_version <> 1 then
    Error "masc.keeper_wake only supports schema_version=1"
  else if not (Schedule_domain.is_side_effecting request.risk_class) then
    Error "masc.keeper_wake requires a side-effecting risk_class"
  else
    let* _keeper_name = string_field "keeper_name" payload.body in
    let* _message = string_field "message" payload.body in
    let* _title = optional_string_field "title" payload.body in
    let* _urgency = optional_keeper_wake_urgency_field "urgency" payload.body in
    Ok ()
;;

let accepts request =
  let* payload = payload_view request in
  if String.equal payload.kind Schedule_supported_kinds.board_post
  then accepts_board_post request payload
  else accepts_keeper_wake request payload
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

let dispatch_keeper_wake config ~now (request : Schedule_domain.schedule_request) payload =
  let* keeper_name = string_field "keeper_name" payload.body in
  let* message = string_field "message" payload.body in
  let* title = optional_string_field "title" payload.body in
  let* urgency = optional_keeper_wake_urgency_field "urgency" payload.body in
  let urgency =
    urgency
    (* DET-OK: absent masc.keeper_wake urgency is the schema-v1 default;
       invalid or unknown urgency strings are rejected above. *)
    |> Option.value ~default:Schedule_supported_kinds.default_keeper_wake_urgency
    |> keeper_queue_urgency_of_schedule_urgency
  in
  let wake : Keeper_event_queue.scheduled_wake =
    { schedule_id = request.Schedule_domain.schedule_id
    ; due_at = request.due_at
    ; payload_digest = Schedule_domain.payload_digest request.payload
    ; title
    ; message
    }
  in
  let stimulus : Keeper_event_queue.stimulus =
    { post_id = Keeper_event_queue.schedule_due_post_id wake
    ; urgency
    ; arrived_at = now
    ; payload = Keeper_event_queue.Schedule_due wake
    }
  in
  Keeper_registry_event_queue.enqueue
    ~base_path:config.Workspace_utils.base_path
    keeper_name
    stimulus;
  Ok
    (`Assoc
      [ "kind", `String "masc.keeper_wake.enqueued"
      ; "keeper_name", `String keeper_name
      ; "schedule_id", `String request.schedule_id
      ; "urgency", `String (Keeper_event_queue.urgency_to_string urgency)
      ; "post_id", `String stimulus.post_id
      ])
;;

let dispatch config ~now request =
  let* payload = payload_view request in
  if String.equal payload.kind Schedule_supported_kinds.board_post
  then (
    let* () = accepts_board_post request payload in
    dispatch_board_post request payload)
  else (
    let* () = accepts_keeper_wake request payload in
    dispatch_keeper_wake config ~now request payload)
;;

let consumer : Schedule_runner.consumer = { accepts; dispatch }
