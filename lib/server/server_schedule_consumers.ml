(* TEL-OK: concrete scheduled consumer details are returned to
   [Schedule_runner] and persisted as execution records; the server maintenance
   loop logs aggregate dispatch counts for runtime telemetry. *)

let supported_payload_kinds = Schedule_supported_kinds.supported
let board_post_created_kind = "masc.board_post.created"
let keeper_wake_enqueued_kind = "masc.keeper_wake.enqueued"
let keeper_event_queue_label = "keeper_event_queue"
let reaction_ledger_recorded_label = "recorded"
let reaction_ledger_record_failed_label = "record_failed"

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

let optional_assoc_field name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`Assoc _ as value) -> Ok (Some value)
  | Some _ -> Error ("expected object field: " ^ name)
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
       ; "stimulus_id", (match stimulus_id with None -> `Null | Some value -> `String value)
       ; "keeper_name", `String keeper_name
       ; "schedule_id", `String schedule_id
       ; "urgency", `String urgency
       ; "post_id", `String post_id
       ]
       @ keeper_wake_reaction_ledger_status_json_fields reaction_ledger_status)
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
    let* _keeper_name = keeper_name_field "keeper_name" payload.body in
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
        [ "kind", `String board_post_created_kind
        ; "post_id", `String post_id
        ; "author", `String author
        ; ( "hearth"
          , match hearth with
            | None -> `Null
            | Some hearth -> `String hearth )
        ])
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
  let* keeper_name = keeper_name_field "keeper_name" payload.body in
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
