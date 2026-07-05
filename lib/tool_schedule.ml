type context =
  { config : Workspace.config
  ; agent_name : string
  }

let ( let* ) = Result.bind

let trim_nonempty value =
  let trimmed = String.trim value in
  if String.equal trimmed "" then None else Some trimmed
;;

let string_opt args key =
  match Json_util.get_string args key with
  | None -> None
  | Some value -> trim_nonempty value
;;

let required_string args key =
  match string_opt args key with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s is required" key)
;;

let optional_float args key = Json_util.get_float args key
let optional_int args key = Json_util.get_int args key
let optional_bool args key = Json_util.get_bool args key

let parse_due_at args =
  match optional_float args "due_at_unix", string_opt args "due_at_iso" with
  | Some due_at, _ -> Ok (Some due_at)
  | None, Some iso ->
    (match Masc_domain.parse_iso8601_opt iso with
     | Some due_at -> Ok (Some due_at)
     | None -> Error "due_at_iso must be a parseable ISO-8601 timestamp")
  | None, None -> Ok None
;;

let resolve_due_at ~requested_at recurrence args =
  let* due_at = parse_due_at args in
  match due_at with
  | Some due_at -> Ok due_at
  | None ->
    (match Schedule_domain.first_due_after ~now:requested_at recurrence with
     | Some due_at -> Ok due_at
     | None ->
       Error
         "one of due_at_unix or due_at_iso is required unless recurrence_kind is daily or cron")
;;

let actor_kind_of_arg args key default =
  match string_opt args key with
  | None -> Ok default
  | Some raw ->
    (match Schedule_domain.actor_kind_of_string raw with
     | Ok kind -> Ok kind
     | Error msg -> Error msg)
;;

let source_of_arg args =
  match string_opt args "source" with
  | None -> Ok Schedule_domain.Operator_request
  | Some raw ->
    (match Schedule_domain.schedule_source_of_string raw with
     | Ok source -> Ok source
     | Error msg -> Error msg)
;;

let risk_class_of_arg args =
  let* raw = required_string args "risk_class" in
  match Schedule_domain.risk_class_of_string raw with
  | Ok risk_class -> Ok risk_class
  | Error msg -> Error msg
;;

let status_of_arg args =
  match string_opt args "status" with
  | None -> Ok None
  | Some raw ->
    (match Schedule_domain.schedule_status_of_string raw with
     | Ok status -> Ok (Some status)
     | Error msg -> Error msg)
;;

let required_int args key =
  match optional_int args key with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s is required" key)
;;

let recurrence_of_arg args =
  match string_opt args "recurrence_kind" with
  | None | Some "one_shot" -> Ok Schedule_domain.One_shot
  | Some "interval" ->
    let* interval_sec = required_int args "recurrence_interval_sec" in
    Ok (Schedule_domain.Interval { interval_sec })
  | Some "daily" ->
    let* hour = required_int args "recurrence_hour" in
    let* minute = required_int args "recurrence_minute" in
    let second =
      (* DET-OK: missing seconds means the explicit daily schedule default at
         the API boundary, not provider/model-derived guessing. *)
      match optional_int args "recurrence_second" with
      | None -> 0
      | Some second -> second
    in
    let* timezone = required_string args "recurrence_timezone" in
    Ok (Schedule_domain.Daily { hour; minute; second; timezone })
  | Some "cron" ->
    let* expression = required_string args "recurrence_cron" in
    let* timezone = required_string args "recurrence_timezone" in
    Ok (Schedule_domain.Cron { expression; timezone })
  | Some other -> Error ("unknown recurrence_kind: " ^ other)
;;

let actor_from_args args ~prefix ~default_id ~default_kind =
  let id =
    match string_opt args (prefix ^ "_id") with
    | Some id -> id
    | None -> default_id
  in
  let* kind = actor_kind_of_arg args (prefix ^ "_kind") default_kind in
  let display_name = string_opt args (prefix ^ "_display_name") in
  if String.equal (String.trim id) ""
  then Error (prefix ^ "_id must not be empty")
  else Ok Schedule_domain.{ id; kind; display_name }
;;

let has_arg args key = Option.is_some (Json_util.assoc_member_opt key args)

let has_board_convenience_args args =
  List.exists
    (has_arg args)
    [ "board_content"
    ; "board_title"
    ; "board_hearth"
    ; "board_author"
    ; "board_thread_id"
    ; "board_ttl_hours"
    ; "board_meta"
    ]
;;

let optional_body_string args ~arg ~field fields =
  match string_opt args arg with
  | None -> Ok fields
  | Some value -> Ok ((field, `String value) :: fields)
;;

let optional_body_int args ~arg ~field fields =
  match Json_util.assoc_member_opt arg args with
  | None -> Ok fields
  | Some (`Int value) -> Ok ((field, `Int value) :: fields)
  | Some _ -> Error (arg ^ " must be an integer")
;;

let optional_nonnegative_body_int args ~arg ~field fields =
  match Json_util.assoc_member_opt arg args with
  | None -> Ok fields
  | Some (`Int value) when value >= 0 -> Ok ((field, `Int value) :: fields)
  | Some (`Int _) -> Error (arg ^ " must be non-negative")
  | Some _ -> Error (arg ^ " must be an integer")
;;

let optional_body_object args ~arg ~field fields =
  match Json_util.assoc_member_opt arg args with
  | None -> Ok fields
  | Some (`Assoc _ as value) -> Ok ((field, value) :: fields)
  | Some _ -> Error (arg ^ " must be an object")
;;

let board_post_payload_from_args args =
  let* content = required_string args "board_content" in
  let schema_version =
    (* DET-OK: board_* is a stable convenience projection for the existing
       masc.board_post v1 consumer. *)
    optional_int args "payload_schema_version" |> Option.value ~default:1
  in
  if schema_version <> 1
  then Error "board_* convenience fields only support payload_schema_version=1"
  else
    let* fields =
      optional_body_string args ~arg:"board_title" ~field:"title"
        [ "content", `String content ]
    in
    let* fields = optional_body_string args ~arg:"board_author" ~field:"author" fields in
    let* fields = optional_body_string args ~arg:"board_hearth" ~field:"hearth" fields in
    let* fields = optional_body_string args ~arg:"board_thread_id" ~field:"thread_id" fields in
    let* fields =
      optional_nonnegative_body_int args ~arg:"board_ttl_hours" ~field:"ttl_hours" fields
    in
    let* fields = optional_body_object args ~arg:"board_meta" ~field:"meta" fields in
    Ok
      (`Assoc
        [ "kind", `String "masc.board_post"
        ; "schema_version", `Int schema_version
        ; "body", `Assoc (List.rev fields)
        ])
;;

let generic_payload_from_args args =
  let* kind = required_string args "payload_kind" in
  let schema_version =
    (* DET-OK: absent schema_version means the stable schedule payload v1
       contract, not provider-derived guessing. *)
    optional_int args "payload_schema_version" |> Option.value ~default:1
  in
  let* body =
    match Json_util.assoc_member_opt "payload_body" args with
    | None -> Ok (`Assoc [])
    | Some (`Assoc _ as body) -> Ok body
    | Some _ -> Error "payload_body must be an object"
  in
  Ok
    (`Assoc
      [ "kind", `String kind; "schema_version", `Int schema_version; "body", body ])
;;

let payload_from_args args =
  match Json_util.assoc_member_opt "payload" args with
  | Some (`Assoc _ as payload) ->
    if has_board_convenience_args args
    then Error "use either payload or board_* convenience fields, not both"
    else Ok payload
  | Some _ -> Error "payload must be an object envelope"
  | None ->
    if has_board_convenience_args args
    then
      if has_arg args "payload_body"
      then Error "use either payload_body or board_* convenience fields, not both"
      else
        (match string_opt args "payload_kind" with
         | None -> board_post_payload_from_args args
         | Some kind when String.equal kind Schedule_supported_kinds.board_post ->
           board_post_payload_from_args args
         | Some kind ->
           Error
             ("board_* convenience fields require payload_kind omitted or masc.board_post, got "
              ^ kind))
    else generic_payload_from_args args
;;

let assoc_string_opt key fields =
  match List.assoc_opt key fields with
  | Some (`String value) -> trim_nonempty value
  | _ -> None
;;

let validate_payload_schema_version ~kind fields =
  match List.assoc_opt "schema_version" fields with
  | Some (`Int 1) -> Ok ()
  | Some (`Int _) -> Error (kind ^ " only supports payload_schema_version=1")
  | Some _ -> Error (kind ^ " payload.schema_version must be an integer")
  | None -> Error (kind ^ " payload requires schema_version=1")
;;

let body_object ~kind fields =
  match List.assoc_opt "body" fields with
  | Some (`Assoc body) -> Ok body
  | Some _ -> Error (kind ^ " payload.body must be an object")
  | None -> Error (kind ^ " payload requires object body")
;;

let validate_keeper_wake_body body =
  match assoc_string_opt "keeper_name" body, assoc_string_opt "message" body with
  | None, _ -> Error "masc.keeper_wake payload requires non-empty body.keeper_name"
  | _, None -> Error "masc.keeper_wake payload requires non-empty body.message"
  | Some keeper_name, Some _
    when not (Schedule_supported_kinds.valid_keeper_wake_target_name keeper_name) ->
    Error
      (Schedule_supported_kinds.keeper_wake_target_name_error
         ~field:"masc.keeper_wake payload body.keeper_name")
  | Some _, Some _ ->
    (match assoc_string_opt "urgency" body with
     | None -> Ok ()
     | Some raw ->
       (match Schedule_supported_kinds.keeper_wake_urgency_of_string raw with
        | Ok _ -> Ok ()
        | Error msg -> Error msg))
;;

let validate_known_payload_request ~payload ~risk_class =
  match payload with
  | `Assoc fields ->
    (match assoc_string_opt "kind" fields with
     | Some kind when String.equal kind Schedule_supported_kinds.board_post ->
       let* () =
         validate_payload_schema_version ~kind:Schedule_supported_kinds.board_post fields
       in
       if not (Schedule_domain.is_side_effecting risk_class)
       then Error "masc.board_post requires a side-effecting risk_class such as workspace_write"
       else (
         match body_object ~kind:Schedule_supported_kinds.board_post fields with
         | Ok body ->
           (match assoc_string_opt "content" body with
            | Some _ -> Ok ()
            | None ->
              Error
                "masc.board_post payload requires non-empty body.content; use board_content for board schedules")
         | Error _ ->
           Error
             "masc.board_post payload requires object body with non-empty content; use board_content for board schedules")
     | Some kind when String.equal kind Schedule_supported_kinds.keeper_wake ->
       let* () =
         validate_payload_schema_version ~kind:Schedule_supported_kinds.keeper_wake fields
       in
       if not (Schedule_domain.is_side_effecting risk_class)
       then
         Error
           "masc.keeper_wake requires a side-effecting risk_class such as workspace_write"
       else
         let* body = body_object ~kind:Schedule_supported_kinds.keeper_wake fields in
         validate_keeper_wake_body body
     | Some kind when Schedule_domain.is_side_effecting risk_class ->
       (* Only side-effecting work needs a consumer adapter that can dispatch
          it. Reject kinds the consumer cannot run so the queue is not filled
          with work that dies at dispatch. Read-only/reminder kinds carry no
          side effect, so their kind stays opaque to the schedule domain — a
          consumer that does not recognize one records a visible failed
          execution (fail_due_candidate), not a silent accept-then-die. *)
       Error (Schedule_supported_kinds.unsupported_error kind)
     | Some _ -> Ok ()
     | None -> Error "payload.kind is required")
  | _ -> Error "payload must be a JSON object"
;;

let schedule_request_json ?last_execution (request : Schedule_domain.schedule_request) =
  let next_due_at =
    if Schedule_domain.is_terminal request.status then None else Some request.due_at
  in
  let requires_grant = Schedule_domain.requires_separate_human_grant request in
  let payload_target, payload_summary =
    Schedule_payload_projection.target_summary request
  in
  match Schedule_domain.schedule_request_to_yojson request with
  | `Assoc fields ->
    `Assoc
      (fields
       @ [ ( "due_at_iso"
           , `String (Masc_domain.iso8601_of_unix_seconds request.due_at) )
         ; ( "next_due_at"
           , match next_due_at with
             | None -> `Null
             | Some ts -> `Float ts )
         ; ( "next_due_at_iso"
           , match next_due_at with
             | None -> `Null
             | Some ts -> `String (Masc_domain.iso8601_of_unix_seconds ts) )
         ; ( "requested_at_iso"
           , `String (Masc_domain.iso8601_of_unix_seconds request.requested_at) )
         ; ( "recurrence_kind"
           , `String (Schedule_domain.recurrence_kind_to_string request.recurrence) )
         ; ( "recurrence_summary"
           , `String (Schedule_domain.recurrence_summary request.recurrence) )
         ; ( "requires_separate_human_grant"
           , `Bool requires_grant )
         ; ( "approval_policy"
           , `String
               (if requires_grant
                then "separate_human_grant_required"
               else "no_separate_grant_required") )
         ; "payload_digest", `String (Schedule_domain.payload_digest request.payload)
         ; ( "payload_kind"
           , match Schedule_payload_projection.kind request with
             | None -> `Null
             | Some kind -> `String kind )
         ; ( "payload_target"
           , match payload_target with
             | None -> `Null
             | Some target -> `String target )
         ; ( "payload_summary"
           , match payload_summary with
             | None -> `Null
             | Some summary -> `String summary )
         ; ( "last_execution"
           , match last_execution with
             | None -> `Null
             | Some execution -> Schedule_domain.execution_record_to_yojson execution
           )
         ])
  | other -> other
;;

let ok ~tool_name ~start_time data =
  Tool_result.make_ok ~tool_name ~start_time ~data ()
;;

let workflow_error ~tool_name ~start_time message =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Workflow_rejection
    ~start_time
    ~data:(Tool_args.error_assoc [ "message", `String message ])
    message
;;

let runtime_error ~tool_name ~start_time message =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Runtime_failure
    ~start_time
    ~data:(Tool_args.error_assoc [ "message", `String message ])
    message
;;

let request_result ~tool_name ~start_time = function
  | Ok request -> ok ~tool_name ~start_time (schedule_request_json request)
  | Error msg -> workflow_error ~tool_name ~start_time msg
;;

(* TEL-OK: schedule tools return [Tool_result.t] through the shared
   [Tool_dispatch] paths; [Server_bootstrap_maintenance] installs the canonical
   dispatch observer that records tool telemetry and metrics once for keeper and
   MCP calls. *)
let handle_create ~tool_name ~start_time ctx args =
  let result =
    let* payload = payload_from_args args in
    let* risk_class = risk_class_of_arg args in
    let* () = validate_known_payload_request ~payload ~risk_class in
    let* source = source_of_arg args in
    let* recurrence = recurrence_of_arg args in
    let requested_at =
      (* NDT-OK: absent requested_at_unix means "schedule this from the tool
         dispatch boundary now"; replay/tests can pass requested_at_unix explicitly. *)
      optional_float args "requested_at_unix" |> Option.value ~default:start_time
    in
    let* due_at = resolve_due_at ~requested_at recurrence args in
    let* requested_by =
      actor_from_args args ~prefix:"requested_by" ~default_id:"operator"
        ~default_kind:Schedule_domain.Human_operator
    in
    let* scheduled_by =
      actor_from_args args ~prefix:"scheduled_by" ~default_id:ctx.agent_name
        ~default_kind:Schedule_domain.Automated_actor
    in
    let schedule_id = string_opt args "schedule_id" in
    let expires_at = optional_float args "expires_at_unix" in
    let approval_required =
      (* DET-OK: omitted approval_required uses the domain risk policy; callers
         must opt in only to stricter approval. *)
      optional_bool args "approval_required" |> Option.value ~default:false
    in
    Schedule_service.create ctx.config ?schedule_id ~requested_at ?expires_at
      ~approval_required ~requested_by ~scheduled_by ~due_at ~payload ~risk_class
      ~source ~recurrence ()
    |> Result.map_error Schedule_service.service_error_to_string
  in
  match result with
  | Error msg -> workflow_error ~tool_name ~start_time msg
  | Ok request -> request_result ~tool_name ~start_time (Ok request)
;;

let take limit items =
  let rec loop acc remaining = function
    | [] -> List.rev acc
    | _ when remaining <= 0 -> List.rev acc
    | item :: rest -> loop (item :: acc) (remaining - 1) rest
  in
  loop [] limit items
;;

let handle_list ~tool_name ~start_time ctx args =
  match status_of_arg args with
  | Error msg -> workflow_error ~tool_name ~start_time msg
  | Ok status ->
    let raw_limit =
      (* DET-OK: list limit is a bounded projection default for read ergonomics;
         it does not change schedule eligibility or ordering. *)
      optional_int args "limit" |> Option.value ~default:50
    in
    let limit = min 200 (max 1 raw_limit) in
    let state = Schedule_store.read_state ctx.config in
    let schedules =
      (match status with
       | None -> state.Schedule_store.schedules
       | Some expected ->
         List.filter
           (fun (request : Schedule_domain.schedule_request) ->
             request.status = expected)
           state.schedules)
      |> take limit
      |> List.map (fun (request : Schedule_domain.schedule_request) ->
        let last_execution =
          Schedule_store.last_execution_for_schedule state
            ~schedule_id:request.Schedule_domain.schedule_id
        in
        schedule_request_json ?last_execution request)
    in
    ok ~tool_name ~start_time
      (`Assoc
        [ "status", `String "ok"
        ; "limit", `Int limit
        ; "schedules", `List schedules
        ])
;;

let handle_get ~tool_name ~start_time ctx args =
  match required_string args "schedule_id" with
  | Error msg -> workflow_error ~tool_name ~start_time msg
  | Ok schedule_id ->
    let state = Schedule_store.read_state ctx.config in
    (match Schedule_service.get ctx.config ~schedule_id with
     | None -> workflow_error ~tool_name ~start_time "schedule not found"
     | Some request ->
       let last_execution =
         Schedule_store.last_execution_for_schedule state
           ~schedule_id:request.Schedule_domain.schedule_id
       in
       ok ~tool_name ~start_time (schedule_request_json ?last_execution request))
;;

let handle_cancel ~tool_name ~start_time ctx args =
  let result =
    let* schedule_id = required_string args "schedule_id" in
    let* cancelled_by_id = required_string args "cancelled_by_id" in
    let* cancelled_by_kind =
      actor_kind_of_arg args "cancelled_by_kind" Schedule_domain.Human_operator
    in
    let* reason = required_string args "reason" in
    let* request =
      Schedule_service.cancel ctx.config ~schedule_id
      |> Result.map_error Schedule_service.service_error_to_string
    in
    Ok (request, cancelled_by_id, cancelled_by_kind, reason)
  in
  match result with
  | Error msg -> workflow_error ~tool_name ~start_time msg
  | Ok (request, cancelled_by_id, cancelled_by_kind, reason) ->
    ok ~tool_name ~start_time
      (`Assoc
        [ "status", `String "ok"
        ; "schedule", schedule_request_json request
        ; ( "cancelled_by"
          , `Assoc
              [ "id", `String cancelled_by_id
              ; "kind", `String (Schedule_domain.actor_kind_to_string cancelled_by_kind)
              ] )
        ; "reason", `String reason
        ])
;;

let dispatch ctx ~name ~args : Tool_result.result option =
  let start_time = Time_compat.now () in
  let handle f =
    try Some (f ~tool_name:name ~start_time ctx args) with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Some
        (runtime_error ~tool_name:name ~start_time
           (Printf.sprintf "schedule tool failed: %s" (Printexc.to_string exn)))
  in
  let open Tool_schemas_schedule in
  match find_definition name with
  | Some { action = Create_request; _ } -> handle handle_create
  | Some { action = List_requests; _ } -> handle handle_list
  | Some { action = Get_request; _ } -> handle handle_get
  | Some { action = Cancel_request; _ } -> handle handle_cancel
  | _ -> None
;;

let schemas = Tool_schemas_schedule.schemas

let () =
  List.iter
    (fun (definition : Tool_schemas_schedule.definition) ->
      let schema : Masc_domain.tool_schema = definition.schema in
      let is_read_only = definition.read_only in
      Tool_spec.register
        (Tool_spec.create
           ~name:schema.name
           ~description:schema.description
           ~module_tag:Tool_dispatch.Mod_schedule
           ~input_schema:schema.input_schema
           ~handler_binding:Tag_dispatch
           ~is_read_only
           ~is_idempotent:is_read_only
           ~effect_domain:
             (if is_read_only
              then Tool_catalog.Read_only
              else Tool_catalog.Masc_workspace)
           ()))
    Tool_schemas_schedule.definitions
;;
