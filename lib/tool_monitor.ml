(** RFC-0379 monitor tool handlers: masc_monitor_create / list / cancel.

    The caller's agent name is the monitor owner; list and cancel never see
    another keeper's monitors. Effects stay in {!Keeper_monitor_store}; the
    server-side runner is the only observer and wake producer. *)

type context =
  { config : Workspace.config
  ; agent_name : string
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

let parse_trigger args =
  let* kind = required_string args "trigger_kind" in
  match kind with
  | "port_up" | "port_down" ->
    let* host = required_string args "host" in
    let* port =
      match Json_util.get_int args "port" with
      | Some port -> Ok port
      | None -> Error "port is required for port_up/port_down"
    in
    if String.equal kind "port_up"
    then Ok (Monitor_domain.Port_up { host; port })
    else Ok (Monitor_domain.Port_down { host; port })
  | "file_changed" ->
    let* path = required_string args "path" in
    Ok (Monitor_domain.File_changed { path })
  | other -> Error (Printf.sprintf "unsupported trigger_kind %S" other)
;;

let ok ~tool_name ~start_time data = Tool_result.make_ok ~tool_name ~start_time ~data ()

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

let monitor_json (record : Monitor_domain.t) =
  `Assoc
    [ "monitor_id", `String record.id
    ; "trigger", Monitor_domain.trigger_to_yojson record.trigger
    ; "payload", record.payload
    ; "expires_at", `Float record.expires_at
    ; "max_fires", `Int record.max_fires
    ; "fired_count", `Int record.fired_count
    ; "created_at", `Float record.created_at
    ]
;;

let handle_create ~tool_name ~start_time ctx args =
  let result =
    let* trigger = parse_trigger args in
    let* payload = required_string args "payload" in
    let* expires_in_sec =
      match Json_util.get_float args "expires_in_sec" with
      | Some seconds when Float.compare seconds 0.0 > 0 -> Ok seconds
      | Some _ -> Error "expires_in_sec must be greater than zero"
      | None -> Error "expires_in_sec is required"
    in
    let max_fires =
      match Json_util.get_int args "max_fires" with
      | Some value -> value
      | None -> 1
    in
    let now = Time_compat.now () in
    let expires_at = now +. expires_in_sec in
    let* () =
      Monitor_domain.validate_create
        ~keeper:ctx.agent_name
        ~trigger
        ~expires_at
        ~max_fires
        ~now
    in
    let record : Monitor_domain.t =
      { id = Random_id.prefixed ~prefix:"mon-" ~bytes:8
      ; keeper = ctx.agent_name
      ; trigger
      ; payload = `String payload
      ; expires_at
      ; max_fires
      ; fired_count = 0
      ; created_at = now
      ; last_observation = None
      }
    in
    let* () = Keeper_monitor_store.create ~base_path:ctx.config.base_path record in
    Ok record
  in
  match result with
  | Error message -> workflow_error ~tool_name ~start_time message
  | Ok record ->
    ok ~tool_name ~start_time
      (`Assoc [ "status", `String "created"; "monitor", monitor_json record ])
;;

let handle_list ~tool_name ~start_time ctx (_ : Yojson.Safe.t) =
  match Keeper_monitor_store.load ~base_path:ctx.config.base_path with
  | Error message -> runtime_error ~tool_name ~start_time message
  | Ok records ->
    let own =
      List.filter
        (fun (record : Monitor_domain.t) ->
           String.equal record.keeper ctx.agent_name)
        records
    in
    ok ~tool_name ~start_time
      (`Assoc
        [ "status", `String "ok"
        ; "monitors", `List (List.map monitor_json own)
        ])
;;

let handle_cancel ~tool_name ~start_time ctx args =
  match required_string args "monitor_id" with
  | Error message -> workflow_error ~tool_name ~start_time message
  | Ok monitor_id ->
    (match
       Keeper_monitor_store.cancel
         ~base_path:ctx.config.base_path
         ~keeper:ctx.agent_name
         ~id:monitor_id
     with
     | Error message -> workflow_error ~tool_name ~start_time message
     | Ok cancelled ->
       ok ~tool_name ~start_time
         (`Assoc
           [ "status", `String (if cancelled then "cancelled" else "not_found")
           ; "monitor_id", `String monitor_id
           ]))
;;

let dispatch ctx ~name ~args : Tool_result.result option =
  let start_time = Time_compat.now () in
  let handle f =
    try Some (f ~tool_name:name ~start_time ctx args) with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Some
        (runtime_error ~tool_name:name ~start_time
           (Printf.sprintf "monitor tool failed: %s" (Printexc.to_string exn)))
  in
  let open Tool_schemas_monitor in
  match find_definition name with
  | Some { action = Create_monitor; _ } -> handle handle_create
  | Some { action = List_monitors; _ } -> handle handle_list
  | Some { action = Cancel_monitor; _ } -> handle handle_cancel
  | None -> None
;;

let schemas = Tool_schemas_monitor.schemas

let () =
  List.iter
    (fun (definition : Tool_schemas_monitor.definition) ->
       let schema : Masc_domain.tool_schema = definition.schema in
       Tool_spec.register
         (Tool_spec.create
            ~name:schema.name
            ~description:schema.description
            ~module_tag:Tool_dispatch.Mod_monitor
            ~input_schema:schema.input_schema
            ~handler_binding:Tag_dispatch
            ~is_read_only:definition.read_only
            ()))
    Tool_schemas_monitor.definitions
;;
