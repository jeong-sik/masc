open Result.Syntax

type execution_mode =
  | Fresh_scope
  | Crash_resume of Agent_core.Agent.execution_locator

type terminal_record = Agent_core.Agent.execution_terminal_disposition

type prepare_error =
  | Runtime_owner_unavailable
  | Filesystem_unavailable
  | Scope_directory_creation_failed of
      { path : string
      ; detail : string
      }
  | Scope_directory_without_locator of string
  | Locator_invalid of
      { path : string
      ; detail : string
      }
  | Terminal_record_present of terminal_record
  | Terminal_record_invalid of
      { path : string
      ; detail : string
      }

type prepared =
  { operation_id : Keeper_agent_core_execution_identity.operation_id
  ; mode : execution_mode
  ; execution_store : Agent_core.Agent.execution_store
  }

type factory =
  Keeper_agent_core_execution_identity.t -> (prepared, prepare_error) result

let locator_leaf = "recovery-locator.json"
let terminal_leaf = "terminal-disposition.json"
let schema_version = 1

let operation_directory ~base_path operation_id =
  Filename.concat
    (Config_dir_resolver.agent_execution_journals_dir ~base_path)
    (Keeper_agent_core_execution_identity.operation_id_to_string operation_id)
;;

let execution_mode_to_string = function
  | Fresh_scope -> "fresh"
  | Crash_resume _ -> "crash_resume"
;;

let terminal_outcome_to_string = function
  | Agent_core.Agent.Terminal_succeeded -> "succeeded"
  | Agent_core.Agent.Terminal_failed -> "failed"
  | Agent_core.Agent.Terminal_cancelled -> "cancelled"
;;

let terminal_outcome_of_string = function
  | "succeeded" -> Ok Agent_core.Agent.Terminal_succeeded
  | "failed" -> Ok Agent_core.Agent.Terminal_failed
  | "cancelled" -> Ok Agent_core.Agent.Terminal_cancelled
  | value -> Error (Printf.sprintf "unknown terminal outcome %S" value)
;;

let recovery_action_to_string = function
  | Agent_core.Agent.Retire -> "retire"
  | Agent_core.Agent.Operator_repair_required Agent_core.Agent.Effect_outcome_unknown ->
    "operator_repair_required_effect_outcome_unknown"
;;

let recovery_action_of_string = function
  | "retire" -> Ok Agent_core.Agent.Retire
  | "operator_repair_required_effect_outcome_unknown" ->
    Ok
      (Agent_core.Agent.Operator_repair_required
         Agent_core.Agent.Effect_outcome_unknown)
  | value -> Error (Printf.sprintf "unknown recovery action %S" value)
;;

let terminal_record_to_yojson
      operation_id
      (terminal : Agent_core.Agent.execution_terminal_disposition)
  =
  `Assoc
    [ "schema_version", `Int schema_version
    ; ( "operation_id"
      , `String
          (Keeper_agent_core_execution_identity.operation_id_to_string operation_id)
      )
    ; "outcome", `String (terminal_outcome_to_string terminal.outcome)
    ; "recovery", `String (recovery_action_to_string terminal.recovery)
    ]
;;

let exact_fields expected fields =
  List.length fields = List.length expected
  && List.for_all
       (fun expected_name ->
          List.length
            (List.filter
               (fun (actual_name, _) -> String.equal expected_name actual_name)
               fields)
          = 1)
       expected
;;

let terminal_record_of_yojson ~operation_id = function
  | `Assoc fields
    when exact_fields [ "schema_version"; "operation_id"; "outcome"; "recovery" ] fields
    ->
    (match
       List.assoc "schema_version" fields,
       List.assoc "operation_id" fields,
       List.assoc "outcome" fields,
       List.assoc "recovery" fields
     with
     | `Int version, `String observed_operation_id, `String outcome, `String recovery
       when version = schema_version
            && String.equal
                 observed_operation_id
                 (Keeper_agent_core_execution_identity.operation_id_to_string
                    operation_id) ->
       let* outcome = terminal_outcome_of_string outcome in
       let* recovery = recovery_action_of_string recovery in
       Ok { Agent_core.Agent.outcome; recovery }
     | `Int version, _, _, _ when version <> schema_version ->
       Error (Printf.sprintf "unsupported terminal record schema version %d" version)
     | _, `String observed_operation_id, _, _ ->
       Error
         (Printf.sprintf
            "terminal record operation id mismatch: observed %S"
            observed_operation_id)
     | _ -> Error "terminal record fields have invalid types")
  | `Assoc _ -> Error "terminal record fields are missing, duplicated, or unknown"
  | _ -> Error "terminal record is not a JSON object"
;;

let locator_record_to_yojson operation locator =
  let operation_id =
    Keeper_agent_core_execution_identity.operation_id operation
  in
  `Assoc
    [ "schema_version", `Int schema_version
    ; ( "operation_id"
      , `String
          (Keeper_agent_core_execution_identity.operation_id_to_string operation_id)
      )
    ; "operation", Keeper_agent_core_execution_identity.to_yojson operation
    ; "locator", Agent_core.Agent.execution_locator_to_yojson locator
    ]
;;

let locator_record_of_yojson operation = function
  | `Assoc fields
    when exact_fields [ "schema_version"; "operation_id"; "operation"; "locator" ] fields
    ->
    let operation_id =
      Keeper_agent_core_execution_identity.operation_id operation
    in
    (match
       List.assoc "schema_version" fields,
       List.assoc "operation_id" fields,
       List.assoc "operation" fields,
       List.assoc "locator" fields
     with
     | `Int version, `String observed_operation_id, observed_operation, locator_json
       when version = schema_version
            && String.equal
                 observed_operation_id
                 (Keeper_agent_core_execution_identity.operation_id_to_string
                    operation_id)
            && observed_operation = Keeper_agent_core_execution_identity.to_yojson operation
       ->
       Agent_core.Agent.execution_locator_of_yojson locator_json
     | `Int version, _, _, _ when version <> schema_version ->
       Error (Printf.sprintf "unsupported locator schema version %d" version)
     | _, `String observed_operation_id, _, _
       when not
              (String.equal
                 observed_operation_id
                 (Keeper_agent_core_execution_identity.operation_id_to_string
                    operation_id)) ->
       Error
         (Printf.sprintf
            "locator operation id mismatch: observed %S"
            observed_operation_id)
     | _, _, observed_operation, _
       when observed_operation <> Keeper_agent_core_execution_identity.to_yojson operation
       -> Error "locator operation identity does not match its directory"
     | _ -> Error "locator record fields have invalid types")
  | `Assoc _ -> Error "locator record fields are missing, duplicated, or unknown"
  | _ -> Error "locator record is not a JSON object"
;;

let parse_json bytes =
  try Ok (Yojson.Safe.from_string bytes) with
  | Yojson.Json_error detail -> Error detail
;;

let load_optional path =
  try Ok (Some (Eio.Path.load path)) with
  | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> Ok None
  | Eio.Io _ as exn -> Error (Printexc.to_string exn)
;;

let load_locator operation path =
  let* stored = load_optional path in
  match stored with
  | None -> Ok None
  | Some bytes ->
    let* json = parse_json bytes in
    Result.map Option.some (locator_record_of_yojson operation json)
;;

let load_terminal operation_id path =
  let* stored = load_optional path in
  match stored with
  | None -> Ok None
  | Some bytes ->
    let* json = parse_json bytes in
    Result.map Option.some (terminal_record_of_yojson ~operation_id json)
;;

let same_locator left right =
  Agent_core.Agent.execution_locator_to_yojson left
  = Agent_core.Agent.execution_locator_to_yojson right
;;

let same_terminal
      (left : Agent_core.Agent.execution_terminal_disposition)
      (right : Agent_core.Agent.execution_terminal_disposition)
  =
  left = right
;;

let create_locator_exclusive ~parent ~path ~operation locator =
  let payload = locator_record_to_yojson operation locator |> Yojson.Safe.to_string in
  match
    Fs_compat.create_capability_file_exclusive
      ~parent
      ~leaf:locator_leaf
      ~permissions:0o600
      payload
  with
  | Ok () -> Ok ()
  | Error create_error ->
    (match load_locator operation path with
     | Ok (Some existing) when same_locator existing locator -> Ok ()
     | Ok (Some _) -> Error "a different recovery locator already owns this operation"
     | Ok None | Error _ ->
       Error (Fs_compat.capability_write_error_to_string create_error))
;;

let verify_resumed_locator ~path ~operation expected observed =
  if not (same_locator expected observed)
  then Error "Agent Core returned a different locator while resuming the scope"
  else
    match load_locator operation path with
    | Ok (Some durable) when same_locator durable expected -> Ok ()
    | Ok (Some _) -> Error "durable recovery locator changed before resume"
    | Ok None -> Error "durable recovery locator disappeared before resume"
    | Error detail -> Error ("durable recovery locator read failed: " ^ detail)
;;

let persist_terminal_exclusive ~parent ~path ~operation_id disposition =
  let payload =
    terminal_record_to_yojson operation_id disposition |> Yojson.Safe.to_string
  in
  match
    Fs_compat.create_capability_file_exclusive
      ~parent
      ~leaf:terminal_leaf
      ~permissions:0o600
      payload
  with
  | Ok () -> Ok ()
  | Error create_error ->
    (match load_terminal operation_id path with
     | Ok (Some existing) when same_terminal existing disposition -> Ok ()
     | Ok (Some _) -> Error "a different terminal disposition already owns this operation"
     | Ok None | Error _ ->
       Error (Fs_compat.capability_write_error_to_string create_error))
;;

let retire_locator ~parent locator_path =
  let* () =
    try
      Eio.Path.unlink locator_path;
      Ok ()
    with
    | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> Ok ()
    | Eio.Io _ as exn -> Error (Printexc.to_string exn)
  in
  Fs_compat.sync_directory_capability parent
  |> Result.map_error Fs_compat.capability_directory_sync_error_to_string
;;

let make_execution_store
      ~owner
      ~operation
      ~operation_id
      ~parent
      ~locator_path
      ~terminal_path
      ~mode
  =
  let on_scope_ready =
    match mode with
    | Fresh_scope -> create_locator_exclusive ~parent ~path:locator_path ~operation
    | Crash_resume expected ->
      verify_resumed_locator ~path:locator_path ~operation expected
  in
  let on_terminal_disposition disposition =
    let* () =
      persist_terminal_exclusive
        ~parent
        ~path:terminal_path
        ~operation_id
        disposition
    in
    match disposition.Agent_core.Agent.recovery with
    | Agent_core.Agent.Retire -> retire_locator ~parent locator_path
    | Agent_core.Agent.Operator_repair_required
        Agent_core.Agent.Effect_outcome_unknown -> Ok ()
  in
  let runtime = Runtime_agent_execution_owner.execution_runtime owner in
  match mode with
  | Fresh_scope ->
    Agent_core.Agent.execution_store
      ~runtime
      ~dir:parent
      ~on_scope_ready
      ~on_terminal_disposition
      ()
  | Crash_resume locator ->
    Agent_core.Agent.execution_store
      ~runtime
      ~dir:parent
      ~on_scope_ready
      ~on_terminal_disposition
      ~resume:locator
      ()
;;

let prepare ~base_path ~owner operation =
  match Fs_compat.get_fs_opt () with
  | None -> Error Filesystem_unavailable
  | Some fs ->
    let operation_id =
      Keeper_agent_core_execution_identity.operation_id operation
    in
    let root_path = Config_dir_resolver.agent_execution_journals_dir ~base_path in
    let directory_path = operation_directory ~base_path operation_id in
    let root = Eio.Path.(fs / root_path) in
    let parent = Eio.Path.(fs / directory_path) in
    let locator_path = Eio.Path.(parent / locator_leaf) in
    let terminal_path = Eio.Path.(parent / terminal_leaf) in
    (try
       Eio.Path.mkdirs ~exists_ok:true ~perm:0o700 root;
       match load_terminal operation_id terminal_path with
       | Error detail ->
         Error (Terminal_record_invalid { path = directory_path; detail })
       | Ok (Some disposition) -> Error (Terminal_record_present disposition)
       | Ok None ->
         (match load_locator operation locator_path with
          | Error detail -> Error (Locator_invalid { path = directory_path; detail })
          | Ok (Some locator) ->
            let mode = Crash_resume locator in
            let execution_store =
              make_execution_store
                ~owner
                ~operation
                ~operation_id
                ~parent
                ~locator_path
                ~terminal_path
                ~mode
            in
            Ok { operation_id; mode; execution_store }
          | Ok None ->
            (try
               Eio.Path.mkdir ~perm:0o700 parent;
               (match Fs_compat.sync_directory_capability root with
                | Error error ->
                  Error
                    (Scope_directory_creation_failed
                       { path = directory_path
                       ; detail =
                           Fs_compat.capability_directory_sync_error_to_string
                             error
                       })
                | Ok () ->
                  let mode = Fresh_scope in
                  let execution_store =
                    make_execution_store
                      ~owner
                      ~operation
                      ~operation_id
                      ~parent
                      ~locator_path
                      ~terminal_path
                      ~mode
                  in
                  Ok { operation_id; mode; execution_store })
             with
             | Eio.Io (Eio.Fs.E (Eio.Fs.Already_exists _), _) ->
               Error (Scope_directory_without_locator directory_path)
             | Eio.Io _ as exn ->
               Error
                 (Scope_directory_creation_failed
                    { path = directory_path; detail = Printexc.to_string exn })))
     with
     | Eio.Io _ as exn ->
       Error
         (Scope_directory_creation_failed
            { path = directory_path; detail = Printexc.to_string exn }))
;;

let current_owner_factory ~base_path operation =
  match Runtime_agent_execution_owner.current () with
  | Runtime_agent_execution_owner.Unavailable -> Error Runtime_owner_unavailable
  | Runtime_agent_execution_owner.Available owner -> prepare ~base_path ~owner operation
;;

let terminal_record_to_string
      (terminal : Agent_core.Agent.execution_terminal_disposition)
  =
  Printf.sprintf
    "%s/%s"
    (terminal_outcome_to_string terminal.outcome)
    (recovery_action_to_string terminal.recovery)
;;

let prepare_error_to_string = function
  | Runtime_owner_unavailable ->
    "application-lifetime Agent Core execution runtime is unavailable"
  | Filesystem_unavailable -> "Eio filesystem capability is unavailable"
  | Scope_directory_creation_failed { path; detail } ->
    Printf.sprintf "execution scope directory creation failed at %s: %s" path detail
  | Scope_directory_without_locator path ->
    Printf.sprintf
      "execution scope directory exists without a recovery locator at %s; operator repair is required"
      path
  | Locator_invalid { path; detail } ->
    Printf.sprintf "execution recovery locator is invalid at %s: %s" path detail
  | Terminal_record_present terminal ->
    Printf.sprintf
      "execution operation is already terminal (%s)"
      (terminal_record_to_string terminal)
  | Terminal_record_invalid { path; detail } ->
    Printf.sprintf "execution terminal record is invalid at %s: %s" path detail
;;

let prepare_error_to_core_error error =
  Agent_core.Error.Internal
    ("keeper Agent Core execution store: " ^ prepare_error_to_string error)
;;
