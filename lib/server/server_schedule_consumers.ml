(* TEL-OK: concrete scheduled consumer details are returned to
   [Schedule_runner] and persisted as execution records; the server maintenance
   loop logs aggregate dispatch counts for runtime telemetry. *)

let supported_payload_kinds = Schedule_payload_projection.supported_payload_kinds

let ( let* ) = Result.bind

let unsupported_payload_labels ~phase (request : Schedule_domain.schedule_request) =
  [ "phase", phase
  ; "risk_class", Schedule_domain.risk_class_to_string request.risk_class
  ]
;;

let record_unsupported_payload_dispatch request rejection =
  match rejection with
  | Schedule_payload_projection.Dispatch_unsupported_kind _ ->
    Otel_metric_store.inc_counter
      Otel_metric_store.metric_schedule_payload_unsupported_total
      ~labels:(unsupported_payload_labels ~phase:"dispatch" request)
      ()
  | Schedule_payload_projection.Dispatch_invalid_payload _
  | Schedule_payload_projection.Dispatch_invalid_supported_payload _ -> ()
;;

let accepts request =
  match Schedule_payload_projection.dispatch_view_detailed request with
  | Ok (_kind, _payload) -> Ok ()
  | Error rejection ->
    record_unsupported_payload_dispatch request rejection;
    Error (Schedule_payload_projection.dispatch_rejection_message rejection)
;;

let schedule_meta_json (request : Schedule_domain.schedule_request) payload user_meta =
  let base =
    [ "source", `String "scheduled_automation"
    ; "schedule_id", `String request.schedule_id
    ; "payload_kind", `String (Schedule_payload_projection.view_kind payload)
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
  let* content = Schedule_payload_projection.body_required_string payload "content" in
  let* title = Schedule_payload_projection.body_optional_string payload "title" in
  let* author = Schedule_payload_projection.body_optional_string payload "author" in
  let* hearth = Schedule_payload_projection.body_optional_string payload "hearth" in
  let* thread_id = Schedule_payload_projection.body_optional_string payload "thread_id" in
  let* ttl_hours = Schedule_payload_projection.body_optional_int payload "ttl_hours" in
  let* user_meta = Schedule_payload_projection.body_optional_assoc payload "meta" in
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
  match Schedule_payload_projection.dispatch_view_detailed request with
  | Error rejection ->
    Error (Schedule_payload_projection.dispatch_rejection_message rejection)
  | Ok (kind, payload) ->
    (match kind with
     | Schedule_payload_projection.Board_post -> dispatch_board_post request payload)
;;

let consumer : Schedule_runner.consumer = { accepts; dispatch }
