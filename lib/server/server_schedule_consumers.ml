(* TEL-OK: concrete scheduled consumer details are returned to
   [Schedule_runner] and persisted as execution records; the server maintenance
   loop logs aggregate dispatch counts for runtime telemetry. *)

let supported_payload_kinds = Schedule_payload_projection.supported_payload_kinds
let board_post_created_kind = "masc.board_post.created"
let keeper_wake_enqueued_kind = "masc.keeper_wake.enqueued"
let keeper_event_queue_label = "keeper_event_queue"
let reaction_ledger_recorded_label = "recorded"
let reaction_ledger_record_failed_label = "record_failed"

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

let keeper_name_field name fields =
  let* value = string_field name fields in
  if Schedule_supported_kinds.valid_keeper_wake_target_name value
  then Ok value
  else Error (Schedule_supported_kinds.keeper_wake_target_name_error ~field:name)
;;

let keeper_queue_urgency_of_schedule_urgency = function
  | Schedule_supported_kinds.Keeper_wake_immediate -> Keeper_event_queue.Immediate
  | Schedule_supported_kinds.Keeper_wake_normal -> Keeper_event_queue.Normal
  | Schedule_supported_kinds.Keeper_wake_low -> Keeper_event_queue.Low
;;

type keeper_wake_reaction_ledger_status =
  | Keeper_wake_reaction_ledger_recorded
  | Keeper_wake_reaction_ledger_record_failed of string

let keeper_wake_reaction_ledger_status_to_string = function
  | Keeper_wake_reaction_ledger_recorded -> reaction_ledger_recorded_label
  | Keeper_wake_reaction_ledger_record_failed _ -> reaction_ledger_record_failed_label
;;

let keeper_wake_reaction_ledger_error = function
  | Keeper_wake_reaction_ledger_recorded -> None
  | Keeper_wake_reaction_ledger_record_failed reason -> Some reason
;;

let keeper_wake_reaction_ledger_status_of_fields fields =
  match optional_string_field "reaction_ledger_status" fields with
  | Error reason -> Error reason
  | Ok None -> Ok None
  | Ok (Some value) when String.equal value reaction_ledger_recorded_label ->
    Ok (Some Keeper_wake_reaction_ledger_recorded)
  | Ok (Some value) when String.equal value reaction_ledger_record_failed_label ->
    let* reason = string_field "reaction_ledger_error" fields in
    Ok (Some (Keeper_wake_reaction_ledger_record_failed reason))
  | Ok (Some value) -> Error ("unsupported reaction_ledger_status: " ^ value)
;;

let keeper_wake_reaction_ledger_status_json_fields = function
  | None -> [ "reaction_ledger_status", `Null; "reaction_ledger_error", `Null ]
  | Some status ->
    [ "reaction_ledger_status"
    , `String (keeper_wake_reaction_ledger_status_to_string status)
    ; ( "reaction_ledger_error"
      , match keeper_wake_reaction_ledger_error status with
        | None -> `Null
        | Some reason -> `String reason )
    ]
;;

type dispatch_receipt =
  | Board_post_created of
      { post_id : string
      ; author : string
      ; hearth : string option
      }
  | Keeper_wake_enqueued of
      { keeper_name : string
      ; schedule_id : string
      ; urgency : string
      ; post_id : string
      ; queue : string
      ; stimulus : string
      ; stimulus_id : string option
      ; reaction_ledger_status : keeper_wake_reaction_ledger_status option
      }

let dispatch_receipt_of_detail = function
  | `Assoc fields ->
    let* kind = string_field "kind" fields in
    if String.equal kind board_post_created_kind
    then
      let* post_id = string_field "post_id" fields in
      let* author = string_field "author" fields in
      let* hearth = optional_string_field "hearth" fields in
      Ok (Board_post_created { post_id; author; hearth })
    else if String.equal kind keeper_wake_enqueued_kind
    then
      let* keeper_name = keeper_name_field "keeper_name" fields in
      let* schedule_id = string_field "schedule_id" fields in
      let* urgency = string_field "urgency" fields in
      let* post_id = string_field "post_id" fields in
      let* queue = string_field "queue" fields in
      let* stimulus = string_field "stimulus" fields in
      let* stimulus_id = optional_string_field "stimulus_id" fields in
      let* reaction_ledger_status =
        keeper_wake_reaction_ledger_status_of_fields fields
      in
      Ok
        (Keeper_wake_enqueued
           { keeper_name
           ; schedule_id
           ; urgency
           ; post_id
           ; queue
           ; stimulus
           ; stimulus_id
           ; reaction_ledger_status
           })
    else Error ("unsupported schedule dispatch receipt kind: " ^ kind)
  | _ -> Error "schedule dispatch receipt detail must be an object"
;;

let dispatch_receipt_to_yojson = function
  | Board_post_created { post_id; author; hearth } ->
    `Assoc
      [ "kind", `String board_post_created_kind
      ; "post_id", `String post_id
      ; "author", `String author
      ; "hearth", (match hearth with None -> `Null | Some hearth -> `String hearth)
      ]
  | Keeper_wake_enqueued
      { keeper_name
      ; schedule_id
      ; urgency
      ; post_id
      ; queue
      ; stimulus
      ; stimulus_id
      ; reaction_ledger_status
      } ->
    `Assoc
      ([ "kind", `String keeper_wake_enqueued_kind
       ; "queue", `String queue
       ; "stimulus", `String stimulus
       ; ( "stimulus_id"
         , match stimulus_id with
           | None -> `Null
           | Some value -> `String value )
       ; "keeper_name", `String keeper_name
       ; "schedule_id", `String schedule_id
       ; "urgency", `String urgency
       ; "post_id", `String post_id
       ]
       @ keeper_wake_reaction_ledger_status_json_fields reaction_ledger_status)
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
    Board_dispatch.create_post
      ~author
      ~content
      ?title
      ~post_kind:Board.System_post
      ~meta_json
      ~visibility:Board.Internal
      ?ttl_hours
      ?hearth
      ?thread_id
      ()
  with
  | Error err -> Error (Board_types.show_board_error err)
  | Ok post ->
    let post_id = Board.Post_id.to_string post.id in
    Ok
      (`Assoc
        [ "kind", `String board_post_created_kind
        ; "post_id", `String post_id
        ; "author", `String author
        ; ( "hearth"
          , match hearth with
            | None -> `Null
            | Some hearth -> `String hearth )
        ])
;;

let body_keeper_name payload =
  let* keeper_name =
    Schedule_payload_projection.body_required_string payload "keeper_name"
  in
  if Schedule_supported_kinds.valid_keeper_wake_target_name keeper_name
  then Ok keeper_name
  else
    Error
      (Schedule_supported_kinds.keeper_wake_target_name_error ~field:"keeper_name")
;;

let body_keeper_wake_urgency payload =
  let* raw = Schedule_payload_projection.body_optional_string payload "urgency" in
  match raw with
  | None -> Ok None
  | Some value ->
    let* urgency = Schedule_supported_kinds.keeper_wake_urgency_of_string value in
    Ok (Some urgency)
;;

let record_keeper_wake_stimulus ~base_path ~keeper_name stimulus =
  try
    Keeper_reaction_ledger.record_event_queue_stimulus ~base_path ~keeper_name stimulus;
    Keeper_wake_reaction_ledger_recorded
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Keeper_wake_reaction_ledger_record_failed
      (Printf.sprintf
         "failed to persist keeper reaction ledger stimulus: %s"
         (Printexc.to_string exn))
;;

let dispatch_keeper_wake config ~now (request : Schedule_domain.schedule_request) payload =
  let* keeper_name = body_keeper_name payload in
  let* message = Schedule_payload_projection.body_required_string payload "message" in
  let* title = Schedule_payload_projection.body_optional_string payload "title" in
  let* urgency = body_keeper_wake_urgency payload in
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
  let stimulus_id = Keeper_reaction_ledger.stimulus_id_of_event_queue stimulus in
  Keeper_registry_event_queue.enqueue
    ~base_path:config.Workspace_utils.base_path
    keeper_name
    stimulus;
  let reaction_ledger_status =
    record_keeper_wake_stimulus
      ~base_path:config.Workspace_utils.base_path
      ~keeper_name
      stimulus
  in
  (match reaction_ledger_status with
   | Keeper_wake_reaction_ledger_recorded -> ()
   | Keeper_wake_reaction_ledger_record_failed reason ->
     Log.Keeper.warn
       "schedule keeper wake reaction ledger append failed schedule_id=%s keeper=%s: %s"
       request.schedule_id
       keeper_name
       reason);
  Ok
    (`Assoc
      ([ "kind", `String keeper_wake_enqueued_kind
       ; "queue", `String keeper_event_queue_label
       ; "stimulus", `String (Keeper_event_queue.payload_kind_label stimulus.payload)
       ; "stimulus_id", `String stimulus_id
       ; "keeper_name", `String keeper_name
       ; "schedule_id", `String request.schedule_id
       ; "urgency", `String (Keeper_event_queue.urgency_to_string urgency)
       ; "post_id", `String stimulus.post_id
       ]
       @ keeper_wake_reaction_ledger_status_json_fields (Some reaction_ledger_status)))
;;

let dispatch config ~now request =
  match Schedule_payload_projection.dispatch_view_detailed request with
  | Error rejection ->
    Error (Schedule_payload_projection.dispatch_rejection_message rejection)
  | Ok (kind, payload) ->
    (match kind with
     | Schedule_payload_projection.Board_post -> dispatch_board_post request payload
     | Schedule_payload_projection.Keeper_wake ->
       dispatch_keeper_wake config ~now request payload)
;;

let consumer : Schedule_runner.consumer = { accepts; dispatch }
