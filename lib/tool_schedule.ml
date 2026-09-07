type context =
  { config : Workspace.config
  ; agent_name : string
  ; stamp_keeper_wake_result_delivery :
      payload:Yojson.Safe.t -> (Yojson.Safe.t, string) result
  ; admit_keeper_wake_creation :
      Workspace.config ->
      keeper_name:string ->
      (unit ->
       (Schedule_domain.schedule_request, Schedule_service.service_error) result) ->
      (Schedule_domain.schedule_request, Schedule_service.service_error) result
  }

let ( let* ) = Result.bind

let string_opt args key =
  match Json_util.get_string args key with
  | None -> None
  | Some value -> String_util.trim_nonempty value
;;

let required_string args key =
  match string_opt args key with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s is required" key)
;;

let optional_float args key = Json_util.get_float args key
let optional_int args key = Json_util.get_int args key

let parse_due_at_iso8601 value =
  match Time_codec.parse_rfc3339_whole_seconds value with
  | Error Time_codec.Invalid_rfc3339 -> None
  | Ok timestamp -> Some timestamp
;;

let parse_due_at args =
  match optional_float args "due_at_unix", string_opt args "due_at_iso" with
  | Some due_at, _ -> Ok (Some due_at)
  | None, Some iso ->
    (match parse_due_at_iso8601 iso with
     | Some due_at -> Ok (Some due_at)
     | None ->
       Error
         "due_at_iso must be an RFC 3339 timestamp with Z or an explicit offset such as +09:00")
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

let validate_recurrence_arg recurrence = Schedule_domain.validate_recurrence recurrence

let recurrence_of_arg args =
  let* recurrence_kind =
    match string_opt args "recurrence_kind" with
    | None -> Ok Schedule_contract_values.One_shot
    | Some wire_value ->
      (match Schedule_contract_values.recurrence_kind_of_string wire_value with
       | Ok recurrence_kind -> Ok recurrence_kind
       | Error error ->
         Error (Schedule_contract_values.decode_error_to_string error))
  in
  match recurrence_kind with
  | Schedule_contract_values.One_shot ->
    validate_recurrence_arg Schedule_domain.One_shot
  | Schedule_contract_values.Interval ->
    let* interval_sec = required_int args "recurrence_interval_sec" in
    validate_recurrence_arg (Schedule_domain.Interval { interval_sec })
  | Schedule_contract_values.Daily ->
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
    validate_recurrence_arg (Schedule_domain.Daily { hour; minute; second; timezone })
  | Schedule_contract_values.Cron ->
    let* expression = required_string args "recurrence_cron" in
    let* timezone = required_string args "recurrence_timezone" in
    validate_recurrence_arg (Schedule_domain.Cron { expression; timezone })
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

(* The kind the runtime stamps on every schedule it creates. Written as a
   match on the projection's closed variant rather than as a constant: a
   second kind added there stops the build here, which is where the decision
   about what this tool asks a caller for belongs. *)
let stamped_kind : Schedule_payload_projection.known_kind -> string = function
  | Schedule_payload_projection.Keeper_wake -> Schedule_supported_kinds.keeper_wake
;;

(* One kind exists, so the tool takes its fields directly instead of an
   envelope the caller assembles. The envelope was three params -- kind,
   schema version, body -- whose only correct values were a fixed string, the
   integer 1, and an object with two required keys. Callers guessed, and two
   thirds of the calls were rejected on shape before the schedule was ever
   considered. [result_delivery] is absent on purpose: it is stamped from the
   creating turn's continuation and a supplied one is not honoured. *)
let payload_from_args args =
  let* keeper_name = required_string args "keeper_name" in
  let* message = required_string args "message" in
  let optional name = function
    | None -> []
    | Some value -> [ name, `String value ]
  in
  let body =
    [ "keeper_name", `String keeper_name; "message", `String message ]
    @ optional "title" (string_opt args "title")
    @ optional "urgency" (string_opt args "urgency")
  in
  Ok
    (`Assoc
      [ "kind", `String (stamped_kind Schedule_payload_projection.Keeper_wake)
      ; "body", `Assoc body
      ])
;;

(* [schedule_payload_unsupported_total] is no longer counted here. The label
   was phase=creation, and this tool stamps the kind, so an unsupported kind
   cannot arrive through it any more. The dispatch-phase producer in
   [Server_schedule_consumers] is what still meets one, on a row stored before
   a kind was retired. *)
let validate_known_payload_request ~payload =
  match
    Schedule_payload_projection.validate_request_payload_for_creation_detailed
      ~payload
  with
  | Ok () -> Ok ()
  | Error rejection ->
    Error (Schedule_payload_projection.creation_rejection_message rejection)
;;

(* A keeper_wake schedule whose target has no durable metadata can never be
   settled: dispatch defers activation with owner_absent and no Keeper turn
   ever closes the occurrence (#26092). Reject at creation unless the caller
   explicitly schedules for a keeper that will be registered later. The
   registry lookup arrives via [Workspace_hooks] so this tool module keeps no
   static keeper dependency (RFC-0194). *)
let allow_unregistered_keeper_of_args args =
  match Json_util.assoc_member_opt "allow_unregistered_keeper" args with
  | None | Some `Null -> Ok false
  | Some (`Bool value) -> Ok value
  | Some _ -> Error "allow_unregistered_keeper must be a boolean"
;;

let validate_keeper_wake_target ctx ~keeper_wake_target args =
  match keeper_wake_target with
  | None -> Ok ()
  | Some keeper_name ->
    let* allow_unregistered = allow_unregistered_keeper_of_args args in
    if allow_unregistered
    then Ok ()
    else (
      match
        (Atomic.get Workspace_hooks.schedule_wake_target_registered_fn)
          ctx.config
          keeper_name
      with
      | Ok true -> Ok ()
      | Ok false ->
        Error
          (Printf.sprintf
             "schedule target keeper '%s' has no durable metadata; register the \
              keeper first or pass allow_unregistered_keeper=true to schedule for \
              a keeper that will be created later"
             keeper_name)
      | Error detail ->
        Error
          (Printf.sprintf
             "schedule target keeper '%s' metadata read failed: %s"
             keeper_name
             detail))
;;

let schedule_request_json ?last_wake (request : Schedule_domain.schedule_request) =
  let next_due_at =
    match request.status with
    | Schedule_domain.Scheduled | Schedule_domain.Due -> Some request.due_at
    | Schedule_domain.Running
    | Schedule_domain.Succeeded
    | Schedule_domain.Failed
    | Schedule_domain.Cancelled
    | Schedule_domain.Expired ->
      None
  in
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
           (* [Schedule_domain.schedule_request_to_yojson] already emits the
              structured "recurrence" in [fields] above. Appending it a second
              time here produced an object with the key twice: readers that
              take the first binding and readers that take the last read
              different values from one result, and the checkpoint encoder --
              which rejects duplicate keys outright -- failed the whole turn
              at [message[_].content[_].json], after the tool had already run.
              One keeper lost 12 consecutive turns to that on 2026-08-29.
              The flattened pair below stays for the readers that use it. *)
         ; ( "recurrence_kind"
           , `String (Schedule_domain.recurrence_kind_to_string request.recurrence) )
         ; ( "recurrence_summary"
           , `String (Schedule_domain.recurrence_summary request.recurrence) )
         ; "payload_digest", `String (Schedule_domain.payload_digest request.payload)
         ; ( "payload_kind"
           , match Schedule_payload_projection.kind request with
             | None -> `Null
             | Some kind -> `String kind )
         ; ( "payload_support"
           , `String
               (request
                |> Schedule_payload_projection.support_status
                |> Schedule_payload_projection.support_status_to_string) )
         ; ( "payload_dispatch_tool"
             (* Display getter: non-logging result variant (see
                server_dashboard_http_runtime_info). Avoids a per-poll WARN on
                terminal unsupported-kind rows. *)
           , match Schedule_payload_projection.dispatch_tool_for_request_result request with
             | Ok tool_name -> `String tool_name
             | Error _ -> `Null )
         ; ( "payload_target"
           , match payload_target with
             | None -> `Null
             | Some target -> `String target )
         ; ( "payload_summary"
           , match payload_summary with
             | None -> `Null
             | Some summary -> `String summary )
         ; ( "last_wake"
           , match last_wake with
             | None -> `Null
             | Some wake -> Schedule_domain.wake_record_to_yojson wake
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

let schedule_read_runtime_error ~tool_name ~start_time err =
  runtime_error
    ~tool_name
    ~start_time
    ("schedule store read failed: " ^ Schedule_store.read_error_to_string err)
;;

let request_result ~tool_name ~start_time = function
  | Ok request -> ok ~tool_name ~start_time (schedule_request_json request)
  | Error msg -> workflow_error ~tool_name ~start_time msg
;;

(* TEL-OK: schedule tools return [Tool_result.t] through the shared
   [Tool_dispatch] paths; [Server_bootstrap_maintenance] installs the canonical
   dispatch observer that records tool telemetry and metrics once for keeper and
   MCP calls. *)
type write_action =
  | Create_schedule
  | Update_schedule

let handle_write ~action ~tool_name ~start_time ctx args =
  let result =
    let* payload = payload_from_args args in
    let* payload = ctx.stamp_keeper_wake_result_delivery ~payload in
    let* () = validate_known_payload_request ~payload in
    let* keeper_wake_target =
      Schedule_payload_projection.creation_keeper_wake_target ~payload
    in
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
    let* schedule_id =
      match action, string_opt args "schedule_id" with
      | Create_schedule, schedule_id -> Ok schedule_id
      | Update_schedule, Some schedule_id -> Ok (Some schedule_id)
      | Update_schedule, None -> Error "schedule_id is required"
    in
    let expires_at = optional_float args "expires_at_unix" in
    let write_request () =
      let* () =
        validate_keeper_wake_target ctx ~keeper_wake_target args
        |> Result.map_error (fun detail ->
          Schedule_service.Creation_rejected detail)
      in
      match action, schedule_id with
      | Create_schedule, schedule_id ->
        Schedule_service.create
          ctx.config ?schedule_id ~requested_at ?expires_at ~requested_by
          ~scheduled_by ~due_at ~payload ~source ~recurrence ()
      | Update_schedule, Some schedule_id ->
        Schedule_service.update
          ctx.config ~schedule_id ~requested_at ?expires_at ~requested_by
          ~scheduled_by ~due_at ~payload ~source ~recurrence ()
      | Update_schedule, None ->
        Error (Schedule_service.Invalid_request "schedule_id is required")
    in
    (match keeper_wake_target with
     | None -> write_request ()
     | Some keeper_name ->
       ctx.admit_keeper_wake_creation
         ctx.config
         ~keeper_name
         write_request)
    |> Result.map_error Schedule_service.service_error_to_string
  in
  match result with
  | Error msg -> workflow_error ~tool_name ~start_time msg
  | Ok request -> request_result ~tool_name ~start_time (Ok request)
;;

let handle_create = handle_write ~action:Create_schedule
let handle_update = handle_write ~action:Update_schedule

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
    (match Schedule_store.read_state_result ctx.config with
     | Error err -> schedule_read_runtime_error ~tool_name ~start_time err
     | Ok state ->
       let request_rows =
         (match status with
          | None -> state.Schedule_store.schedules
          | Some expected ->
            List.filter
              (fun (request : Schedule_domain.schedule_request) ->
                 request.status = expected)
              state.schedules)
         |> take limit
       in
       let schedules =
         request_rows
         |> List.map (fun (request : Schedule_domain.schedule_request) ->
           let last_wake =
             Schedule_store.last_wake_for_schedule_instance
               state
               ~schedule_instance_id:request.Schedule_domain.schedule_instance_id
               ~schedule_id:request.Schedule_domain.schedule_id
           in
           schedule_request_json ?last_wake request)
       in
       ok ~tool_name ~start_time
         (`Assoc
           [ "status", `String "ok"
           ; "limit", `Int limit
           ; "payload_support"
             , Schedule_payload_projection.support_summary_to_yojson request_rows
           ; "schedules", `List schedules
           ]))
;;

let handle_get ~tool_name ~start_time ctx args =
  match required_string args "schedule_id" with
  | Error msg -> workflow_error ~tool_name ~start_time msg
  | Ok schedule_id ->
    (match Schedule_store.read_state_result ctx.config with
     | Error err -> schedule_read_runtime_error ~tool_name ~start_time err
     | Ok state ->
       match
         List.find_opt
           (fun (request : Schedule_domain.schedule_request) ->
              String.equal request.schedule_id schedule_id)
           state.schedules
       with
     | None -> workflow_error ~tool_name ~start_time "schedule not found"
     | Some request ->
       let last_wake =
         Schedule_store.last_wake_for_schedule_instance state
           ~schedule_instance_id:request.Schedule_domain.schedule_instance_id
           ~schedule_id:request.Schedule_domain.schedule_id
       in
       ok ~tool_name ~start_time (schedule_request_json ?last_wake request))
;;

(* Takes the config alone, not the full [context]: cancel touches nothing but
   the schedule store, so requiring the creation-path hooks (or an agent name
   the arguments already carry) would be a dependency this action does not
   have. *)
let handle_cancel ~tool_name ~start_time (config : Workspace.config) args =
  let result =
    let* schedule_id = required_string args "schedule_id" in
    let* cancelled_by_id = required_string args "cancelled_by_id" in
    let* cancelled_by_kind =
      actor_kind_of_arg args "cancelled_by_kind" Schedule_domain.Human_operator
    in
    let* reason = required_string args "reason" in
    let* request =
      Schedule_service.cancel config ~schedule_id
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
  | Some { action = Update_request; _ } -> handle handle_update
  | Some { action = List_requests; _ } -> handle handle_list
  | Some { action = Get_request; _ } -> handle handle_get
  | Some { action = Cancel_request; _ } ->
      handle (fun ~tool_name ~start_time ctx ->
          handle_cancel ~tool_name ~start_time ctx.config)
  (* [None] is "not a schedule tool". Spelling it out rather than [_] keeps the
     action match exhaustive, so an action added to Tool_schemas_schedule is a
     compile error here instead of an advertised name with no route. *)
  | None -> None
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
           ()))
    Tool_schemas_schedule.definitions
;;
