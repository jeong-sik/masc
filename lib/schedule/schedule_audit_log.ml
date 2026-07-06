open Schedule_domain

type action =
  | Request_created
  | Grant_approved
  | Grant_rejected
  | Request_cancelled
  | Request_marked_due
  | Request_expired
  | Request_rescheduled
  | Execution_started
  | Execution_succeeded
  | Execution_failed
  | Due_candidate_failed

type event =
  { schema_version : int
  ; event_id : string
  ; recorded_at : float
  ; action : action
  ; schedule_id : string
  ; state_version : int
  ; previous_status : Schedule_domain.schedule_status option
  ; current_status : Schedule_domain.schedule_status
  ; payload_digest : string
  ; due_at : float
  ; actor : Schedule_domain.actor option
  ; detail : Yojson.Safe.t option
  }

type projection_coverage =
  | Events_recorded
  | No_lifecycle_events
  | Read_error

type backfill_policy = Not_synthesized_from_schedule_snapshot

let ( let* ) = Result.bind

let default_projection_limit = 10

let path config =
  Filename.concat (Workspace_utils.masc_dir config) "schedule_lifecycle_audit.jsonl"
;;

let action_to_string = function
  | Request_created -> "request_created"
  | Grant_approved -> "grant_approved"
  | Grant_rejected -> "grant_rejected"
  | Request_cancelled -> "request_cancelled"
  | Request_marked_due -> "request_marked_due"
  | Request_expired -> "request_expired"
  | Request_rescheduled -> "request_rescheduled"
  | Execution_started -> "execution_started"
  | Execution_succeeded -> "execution_succeeded"
  | Execution_failed -> "execution_failed"
  | Due_candidate_failed -> "due_candidate_failed"
;;

let action_of_string = function
  | "request_created" -> Ok Request_created
  | "grant_approved" -> Ok Grant_approved
  | "grant_rejected" -> Ok Grant_rejected
  | "request_cancelled" -> Ok Request_cancelled
  | "request_marked_due" -> Ok Request_marked_due
  | "request_expired" -> Ok Request_expired
  | "request_rescheduled" -> Ok Request_rescheduled
  | "execution_started" -> Ok Execution_started
  | "execution_succeeded" -> Ok Execution_succeeded
  | "execution_failed" -> Ok Execution_failed
  | "due_candidate_failed" -> Ok Due_candidate_failed
  | other -> Error ("unknown schedule audit action: " ^ other)
;;

let projection_coverage_to_string = function
  | Events_recorded -> "events_recorded"
  | No_lifecycle_events -> "no_lifecycle_events"
  | Read_error -> "read_error"
;;

let backfill_policy_to_string = function
  | Not_synthesized_from_schedule_snapshot ->
    "not_synthesized_from_schedule_snapshot"
;;

let stable_float value = Printf.sprintf "%.17g" value

let sha256_string value = Digestif.SHA256.(digest_string value |> to_hex)

let event_id
      ~recorded_at
      ~state_version
      ~action
      ~schedule_id
      ~previous_status
      ~current_status
      ~payload_digest
      ~due_at
  =
  String.concat
    "|"
    [ "schedule_audit"
    ; action_to_string action
    ; schedule_id
    ; string_of_int state_version
    ; stable_float recorded_at
    ; (match previous_status with
       | None -> ""
       | Some status -> Schedule_domain.schedule_status_to_string status)
    ; Schedule_domain.schedule_status_to_string current_status
    ; payload_digest
    ; stable_float due_at
    ]
  |> sha256_string
  |> Printf.sprintf "sched-audit-%s"
;;

let make
      ~recorded_at
      ~state_version
      ~action
      ?previous
      ~current
      ?actor
      ?detail
      ()
  =
  let previous_status =
    Option.map (fun (request : Schedule_domain.schedule_request) -> request.status) previous
  in
  let payload_digest = Schedule_domain.payload_digest current.payload in
  let current_status = current.status in
  let schedule_id = current.schedule_id in
  let due_at = current.due_at in
  let event_id =
    event_id
      ~recorded_at
      ~state_version
      ~action
      ~schedule_id
      ~previous_status
      ~current_status
      ~payload_digest
      ~due_at
  in
  { schema_version = 1
  ; event_id
  ; recorded_at
  ; action
  ; schedule_id
  ; state_version
  ; previous_status
  ; current_status
  ; payload_digest
  ; due_at
  ; actor
  ; detail
  }
;;

let status_option_to_json = function
  | None -> `Null
  | Some status -> `String (Schedule_domain.schedule_status_to_string status)
;;

let event_to_yojson event =
  `Assoc
    [ "schema", `String "masc.schedule.lifecycle_audit.v1"
    ; "schema_version", `Int event.schema_version
    ; "event_id", `String event.event_id
    ; "recorded_at", `Float event.recorded_at
    ; "action", `String (action_to_string event.action)
    ; "schedule_id", `String event.schedule_id
    ; "state_version", `Int event.state_version
    ; "previous_status", status_option_to_json event.previous_status
    ; "current_status", `String (Schedule_domain.schedule_status_to_string event.current_status)
    ; "payload_digest", `String event.payload_digest
    ; "due_at", `Float event.due_at
    ; ( "actor"
      , match event.actor with
        | None -> `Null
        | Some actor -> Schedule_domain.actor_to_yojson actor )
    ; ( "detail"
      , match event.detail with
        | None -> `Null
        | Some detail -> detail )
    ]
;;

let projection_to_yojson ~limit = function
  | Ok events ->
    let event_count = List.length events in
    let coverage =
      if event_count = 0 then No_lifecycle_events else Events_recorded
    in
    `Assoc
      [ "source", `String "schedule_lifecycle_audit_jsonl"
      ; "status", `String "ok"
      ; "limit", `Int limit
      ; "event_count", `Int event_count
      ; "coverage", `String (projection_coverage_to_string coverage)
      ; ( "backfill_policy"
        , `String
            (backfill_policy_to_string Not_synthesized_from_schedule_snapshot) )
      ; "events", `List (List.map event_to_yojson events)
      ; "error", `Null
      ]
  | Error msg ->
    `Assoc
      [ "source", `String "schedule_lifecycle_audit_jsonl"
      ; "status", `String "read_error"
      ; "limit", `Int limit
      ; "event_count", `Int 0
      ; "coverage", `String (projection_coverage_to_string Read_error)
      ; ( "backfill_policy"
        , `String
            (backfill_policy_to_string Not_synthesized_from_schedule_snapshot) )
      ; "events", `List []
      ; "error", `String msg
      ]
;;

let assoc_field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error ("missing field: " ^ name)
;;

let string_field name fields =
  let* value = assoc_field name fields in
  match value with
  | `String value -> Ok value
  | _ -> Error ("expected string field: " ^ name)
;;

let int_field name fields =
  let* value = assoc_field name fields in
  match value with
  | `Int value -> Ok value
  | _ -> Error ("expected int field: " ^ name)
;;

let float_field name fields =
  let* value = assoc_field name fields in
  match value with
  | `Float value -> Ok value
  | `Int value -> Ok (float_of_int value)
  | _ -> Error ("expected float field: " ^ name)
;;

let optional_status_field name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`String value) ->
    Schedule_domain.schedule_status_of_string value |> Result.map Option.some
  | Some _ -> Error ("expected nullable status field: " ^ name)
;;

let optional_actor_field name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some value -> Schedule_domain.actor_of_yojson value |> Result.map Option.some
;;

let optional_detail_field name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some value -> Ok (Some value)
;;

let event_of_yojson = function
  | `Assoc fields ->
    let* schema_version = int_field "schema_version" fields in
    let* event_id = string_field "event_id" fields in
    let* recorded_at = float_field "recorded_at" fields in
    let* action_name = string_field "action" fields in
    let* action = action_of_string action_name in
    let* schedule_id = string_field "schedule_id" fields in
    let* state_version = int_field "state_version" fields in
    let* previous_status = optional_status_field "previous_status" fields in
    let* current_status_name = string_field "current_status" fields in
    let* current_status = Schedule_domain.schedule_status_of_string current_status_name in
    let* payload_digest = string_field "payload_digest" fields in
    let* due_at = float_field "due_at" fields in
    let* actor = optional_actor_field "actor" fields in
    let* detail = optional_detail_field "detail" fields in
    Ok
      { schema_version
      ; event_id
      ; recorded_at
      ; action
      ; schedule_id
      ; state_version
      ; previous_status
      ; current_status
      ; payload_digest
      ; due_at
      ; actor
      ; detail
      }
  | _ -> Error "expected schedule audit event object"
;;

let append config event =
  try
    Fs_compat.append_jsonl (path config) (event_to_yojson event);
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Sys_error msg -> Error msg
  | Unix.Unix_error (err, fn, arg) ->
    Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message err))
  | Failure msg -> Error msg
;;

let append_many config events =
  try
    Fs_compat.append_jsonl_batch (path config) (List.map event_to_yojson events);
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Sys_error msg -> Error msg
  | Unix.Unix_error (err, fn, arg) ->
    Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message err))
  | Failure msg -> Error msg
;;

let read_lines path =
  if not (Sys.file_exists path)
  then Ok []
  else
    try
      let ic = open_in_bin path in
      let rec loop acc =
        match input_line ic with
        | line ->
          let trimmed = String.trim line in
          if String.equal trimmed "" then loop acc else loop (trimmed :: acc)
        | exception End_of_file -> Ok (List.rev acc)
      in
      let result =
        Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () -> loop [])
      in
      result
    with
    | Sys_error msg -> Error msg
    | Unix.Unix_error (err, fn, arg) ->
      Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message err))
;;

let read_all config =
  let* lines = read_lines (path config) in
  let rec loop acc line_no = function
    | [] -> Ok (List.rev acc)
    | line :: rest ->
      (match Yojson.Safe.from_string line with
       | json ->
         (match event_of_yojson json with
          | Ok event -> loop (event :: acc) (line_no + 1) rest
          | Error msg ->
            Error
              (Printf.sprintf "schedule audit line %d decode failed: %s" line_no msg))
       | exception Yojson.Json_error msg ->
         Error
           (Printf.sprintf "schedule audit line %d JSON parse failed: %s" line_no msg))
  in
  loop [] 1 lines
;;

let take limit items =
  let rec loop acc remaining = function
    | [] -> List.rev acc
    | _ when remaining <= 0 -> List.rev acc
    | item :: rest -> loop (item :: acc) (remaining - 1) rest
  in
  loop [] limit items
;;

let read_recent config ~limit =
  let limit = max 0 limit in
  let* all = read_all config in
  Ok (all |> List.rev |> take limit)
;;

let recent_for_schedule events ~schedule_id ~limit =
  let limit = max 0 limit in
  events
  |> List.rev
  |> List.filter (fun (event : event) -> String.equal event.schedule_id schedule_id)
  |> take limit
;;

let projection_for_schedule source ~schedule_id ~limit =
  match source with
  | Ok events -> Ok (recent_for_schedule events ~schedule_id ~limit)
  | Error msg -> Error msg
;;

let read_recent_for_schedule config ~schedule_id ~limit =
  let* all = read_all config in
  Ok (recent_for_schedule all ~schedule_id ~limit)
;;
