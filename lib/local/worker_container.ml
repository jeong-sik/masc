(** Worker_container — worker container, meta, checkpoint, and tool building. *)

open Printf

include Worker_container_types

let worker_container_root ~base_path =
  Filename.concat (Common.masc_dir_from_base_path ~base_path) "local-workers"

let safe_worker_token worker_name =
  worker_name
  |> String.to_seq
  |> Seq.map (function
       | ('a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.') as ch -> ch
       | _ -> '_')
  |> String.of_seq

let worker_container_dir ~base_path ~worker_name =
  Filename.concat
    (worker_container_root ~base_path)
    (safe_worker_token worker_name)

let worker_meta_path ~base_path ~worker_name =
  Filename.concat
    (worker_container_dir ~base_path ~worker_name)
    "meta.json"

let worker_checkpoint_path ~base_path ~worker_name =
  Filename.concat
    (worker_container_dir ~base_path ~worker_name)
    "checkpoint.json"

let worker_turn_log_path ~base_path ~worker_name =
  Filename.concat
    (worker_container_dir ~base_path ~worker_name)
    "turns.jsonl"

let worker_raw_trace_path ~base_path ~worker_name =
  Filename.concat
    (worker_container_dir ~base_path ~worker_name)
    "raw-trace.jsonl"

let oas_tool_error ?(recoverable = false) message : Agent_sdk.Types.tool_result =
  Error { Agent_sdk.Types.message; recoverable; error_class = None }

let ensure_worker_container_dirs ~base_path ~worker_name =
  let dir = worker_container_dir ~base_path ~worker_name in
  Fs_compat.mkdir_p dir;
  Fs_compat.save_file (Filename.concat dir ".keep") "";
  (try Sys.remove (Filename.concat dir ".keep") with Sys_error _ -> ())

let stable_worker_session_id worker_name =
  let basis =
    String.concat "\n"
      [
        worker_name;
        "global";
      ]
  in
  let digest = Digest.string basis |> Digest.to_hex in
  sprintf "worker-%s" (String.sub digest 0 12)

let oas_worker_evidence_session_id ~worker_run_id =
  String.trim worker_run_id

let evidence_session_id_of_worker_run = function
  | Some worker_run_id when String.trim worker_run_id <> "" ->
      Some (oas_worker_evidence_session_id ~worker_run_id)
  | _ -> None

let session_min_tool_names =
  Tool_catalog_surfaces.session_min_surface_tools

let worker_meta_allowed_fields =
  [
    "version";
    "worker_name";
    "mcp_session_id";
    "workspace_path";
    "role";
    "selection_note";
    "runtime_backend";
    "thinking_enabled";
    "timeout_seconds";
    "effective_model";
    "checkpoint_path";
    "turn_log_path";
    "mcp_client_session_started_at";
    "last_run_at";
  ]

let worker_meta_removed_fields =
  [ "max_turns_override"; "tool_profile"; "shell_profile"; "worker_class" ]

let validate_worker_meta_fields fields =
  let field_names = List.map fst fields in
  match List.find_opt (fun name -> List.mem name worker_meta_removed_fields) field_names with
  | Some field ->
      Error
        (Printf.sprintf
           "worker meta field %S has been removed; worker runtime state is now backend-only"
           field)
  | None -> (
      match List.find_opt
              (fun name -> not (List.mem name worker_meta_allowed_fields))
              field_names
      with
      | Some field ->
          Error (Printf.sprintf "unknown worker meta field %S" field)
      | None -> Ok ())

let worker_meta_to_yojson (meta : worker_container_meta) =
  `Assoc
    [
      ("version", `Int meta.version);
      ("worker_name", `String meta.worker_name);
      ("mcp_session_id", `String meta.mcp_session_id);
      ("workspace_path", `String meta.workspace_path);
      ("role", Option.fold ~none:`Null ~some:(fun s -> `String s) meta.role);
      ( "selection_note",
        Option.fold ~none:`Null ~some:(fun s -> `String s) meta.selection_note
      );
      ("runtime_backend", Worker_execution_backend.to_yojson meta.runtime_backend);
      ("thinking_enabled", Option.fold ~none:`Null ~some:(fun v -> `Bool v) meta.thinking_enabled);
      ("timeout_seconds", Option.fold ~none:`Null ~some:(fun n -> `Int n) meta.timeout_seconds);
      ("effective_model", `String meta.effective_model);
      ("checkpoint_path", `String meta.checkpoint_path);
      ("turn_log_path", `String meta.turn_log_path);
      ( "mcp_client_session_started_at",
        Option.fold ~none:`Null ~some:(fun ts -> `Float ts)
          meta.mcp_client_session_started_at );
      ( "last_run_at",
        Option.fold ~none:`Null ~some:(fun ts -> `Float ts) meta.last_run_at );
    ]

let worker_meta_of_yojson json =
  match json with
  | `Assoc fields -> (
      match validate_worker_meta_fields fields with
      | Error _ as err -> err
      | Ok () -> (
          match Json_util.get_string json "worker_name" with
          | None -> Error "worker meta missing worker_name"
          | Some worker_name -> (
              match Worker_execution_backend.of_yojson (Json_util.assoc_member_opt "runtime_backend" json |> Option.value ~default:`Null) with
              | Error _ as err -> err
              | Ok runtime_backend ->
                  Ok
                    {
                      version =
                        Json_util.get_int json "version"
                        |> Option.value ~default:worker_container_version;
                      worker_name;
                      mcp_session_id =
                        Json_util.get_string json "mcp_session_id"
                        |> Option.value ~default:(stable_worker_session_id worker_name);
                      workspace_path =
                        Json_util.get_string json "workspace_path"
                        |> Option.value ~default:"";
                      role = Json_util.get_string json "role";
                      selection_note =
                        Json_util.get_string json "selection_note";
                      runtime_backend;
                      thinking_enabled =
                        Json_util.get_bool json "thinking_enabled";
                      timeout_seconds =
                        Json_util.get_int json "timeout_seconds";
                      effective_model =
                        Json_util.get_string json "effective_model"
                        |> Option.value ~default:"";
                      checkpoint_path =
                        Json_util.get_string json "checkpoint_path"
                        |> Option.value ~default:"";
                      turn_log_path =
                        Json_util.get_string json "turn_log_path"
                        |> Option.value ~default:"";
                      mcp_client_session_started_at =
                        Json_util.get_float json "mcp_client_session_started_at";
                      last_run_at = Json_util.get_float json "last_run_at";
                    })))
  | _ -> Error "worker meta must be a JSON object"

let load_worker_meta ~base_path ~worker_name =
  let path = worker_meta_path ~base_path ~worker_name in
  if Sys.file_exists path then
    try
      match Safe_ops.read_json_eio path |> worker_meta_of_yojson with
      | Ok meta -> Some meta
      | Error msg ->
          Log.LocalWorker.warn "invalid worker meta for %s: %s" worker_name msg;
          None
    with Yojson.Json_error _ | Sys_error _ | Eio.Io _ -> None
  else
    None

let save_worker_meta ~base_path ~worker_name
    (meta : worker_container_meta) =
  try
    ensure_worker_container_dirs ~base_path ~worker_name;
    Fs_compat.save_file
      (worker_meta_path ~base_path ~worker_name)
      (meta |> worker_meta_to_yojson |> Yojson.Safe.pretty_to_string);
    Ok ()
  with Sys_error msg ->
    Error
      (sprintf "failed to save worker meta for %s: %s" worker_name msg)

let worker_container_state ~base_path ~worker_name =
  let meta_exists =
    Sys.file_exists (worker_meta_path ~base_path ~worker_name)
  in
  let checkpoint_exists =
    Sys.file_exists
      (worker_checkpoint_path ~base_path ~worker_name)
  in
  match meta_exists, checkpoint_exists with
  | false, false -> Worker_missing
  | _, true -> Worker_ready
  | true, false -> Worker_pending

let load_worker_checkpoint ~base_path ~worker_name =
  let path =
    worker_checkpoint_path ~base_path ~worker_name
  in
  if Sys.file_exists path then
    try
      let raw = In_channel.with_open_text path In_channel.input_all in
      (match Agent_sdk.Checkpoint.of_string raw with
       | Ok v -> Some v
       | Error detail ->
         Log.LocalWorker.warn "checkpoint parse error discarded for %s: %s" worker_name (Agent_sdk.Error.to_string detail);
         None)
    with Sys_error _ -> None
  else
    None

let save_worker_checkpoint ~base_path ~worker_name checkpoint =
  try
    ensure_worker_container_dirs ~base_path ~worker_name;
    Fs_compat.save_file
      (worker_checkpoint_path ~base_path ~worker_name)
      (Agent_sdk.Checkpoint.to_string checkpoint);
    Ok ()
  with Sys_error msg ->
    Error
      (sprintf "failed to save worker checkpoint for %s: %s" worker_name msg)

let append_worker_turn_log ~base_path ~worker_name json =
  try
    ensure_worker_container_dirs ~base_path ~worker_name;
    Fs_compat.append_file
      (worker_turn_log_path ~base_path ~worker_name)
      (Yojson.Safe.to_string json ^ "\n");
    Ok ()
  with Sys_error msg ->
    Error
      (sprintf "failed to append worker turn log for %s: %s" worker_name msg)

let resolved_mcp_session_id ~base_path ~worker_name =
  match load_worker_meta ~base_path ~worker_name with
  | Some meta when String.trim meta.mcp_session_id <> "" -> meta.mcp_session_id
  | _ -> stable_worker_session_id worker_name

let start_worker_heartbeat ~sw ~(auth_token : string option) ~session_id
    ~worker_name =
  let interval = local_worker_heartbeat_interval_sec () in
  match (interval, Eio_context.get_clock_opt ()) with
  | interval, _ when interval <= 0 -> fun () -> ()
  | _, None -> fun () -> ()
  | interval, Some clock ->
      let active = ref true in
      Eio.Fiber.fork ~sw (fun () ->
          let rec loop () =
            if !active then (
              Eio.Time.sleep clock (float_of_int interval);
              if !active then (
                match
                  call_masc_tool ~sw ~auth_token ~session_id
                    ~tool_name:"masc_heartbeat" ~args:(`Assoc [])
                with
                | Ok _ -> ()
                | Error e ->
                    Log.LocalWorker.warn "heartbeat error for %s: %s"
                      worker_name e;
                loop ()))
          in
          try loop ()
          with
          | Eio.Cancel.Cancelled _ as ex -> raise ex
          | exn ->
            Log.LocalWorker.error "heartbeat loop error for %s: %s"
              worker_name (Printexc.to_string exn));
      fun () -> active := false

let build_oas_mcp_tools ~sw ~auth_token ~session_id ~worker_name =
  let allowed_names = session_min_tool_names in
  let listed_schemas =
    list_masc_tools ~sw ~auth_token ~session_id ~names:(Some allowed_names) ()
  in
  Result.map
    (fun schemas ->
      schemas
      |> List.filter (fun (schema : Masc_domain.tool_schema) ->
             List.mem schema.name allowed_names)
      |> List.map (fun (schema : Masc_domain.tool_schema) ->
             let call_fn input =
               let args =
                 input
                 |> inject_default_agent_name ~worker_name
                      ~schema:(Some schema)
               in
               match
                 call_masc_tool ~sw ~auth_token ~session_id ~tool_name:schema.name
                   ~args
               with
               | Ok result when result.is_error ->
                 oas_tool_error result.text
               | Ok result ->
                 Ok { Agent_sdk.Types.content = result.text; _meta = None }
               | Error e ->
                 oas_tool_error e
             in
             Agent_sdk.Mcp.mcp_tool_to_sdk_tool ~call_fn
               {
                 Agent_sdk.Mcp.name = schema.name;
                 description = schema.description;
                 input_schema = schema.input_schema;
               }))
    listed_schemas

(** Convert a model label to an OAS Provider.config.
    Returns Error when the label cannot be parsed. *)
let oas_provider_of_label (label : string) :
    (Agent_sdk.Provider.config, string) result =
  match Runtime_model_string.parse_model_string label with
  | Some pc -> Ok (Agent_sdk.Provider.config_of_provider_config pc)
  | None ->
    let msg = Printf.sprintf "Cannot parse model label: %S (expected provider:model)" label in
    Log.Misc.error "%s" msg;
    Error msg

(** Resolve provider from a model label string.
    Returns the provider config and model_id on success. *)
let resolve_oas_provider_of_label (label : string) :
    (Agent_sdk.Provider.config * string, string) result =
  match Runtime_model_string.parse_model_string label with
  | None -> Error (Printf.sprintf "Cannot parse model: %s" label)
  | Some pc ->
    Ok
      ( Agent_sdk.Provider.config_of_provider_config pc,
        pc.Llm_provider.Provider_config.model_id )

let make_worker_meta ~base_path ~workspace_path ~worker_name
    ~mcp_session_id ~role ~selection_note ~runtime_backend
    ~effective_model ~thinking_enabled
    ~timeout_seconds =
  {
    version = worker_container_version;
    worker_name;
    mcp_session_id;
    workspace_path;
    role;
    selection_note;
    runtime_backend;
    thinking_enabled;
    timeout_seconds;
    effective_model;
    checkpoint_path =
      worker_checkpoint_path ~base_path ~worker_name;
    turn_log_path =
      worker_turn_log_path ~base_path ~worker_name;
    mcp_client_session_started_at = None;
    last_run_at = None;
  }

let append_worker_completion_log ~base_path ~worker_name
    ~prompt ~tool_names ~status ~output ?error ?raw_trace_run
    ?evidence_session_id () =
  append_worker_turn_log ~base_path ~worker_name
    (`Assoc
      [
        ("ts", `Float (Time_compat.now ()));
        ("status", `String status);
        ("prompt", `String (safe_text_for_followup prompt));
        ("tool_names", `List (List.map (fun name -> `String name) tool_names));
        ("output_preview", `String (safe_text_for_followup output));
        ( "raw_trace_run",
          match raw_trace_run with
          | Some run_ref -> Agent_sdk.Raw_trace.run_ref_to_yojson run_ref
          | None -> `Null );
        ( "evidence_session_id",
          Option.fold ~none:`Null ~some:(fun value -> `String value)
            evidence_session_id );
        ( "error",
          Option.fold ~none:`Null ~some:(fun value -> `String value) error );
      ])

(** Build (config, options) for Agent.resume — the continue_worker path.
    New workers use Worker_oas.build_agent (Builder pattern) instead.
    Accepts [~provider] + [~model_id] as resolved values. *)
let build_resume_config ~worker_name ~provider ~model_id ~system_prompt ~tools
    ~thinking_enabled ~hooks ~raw_trace ?(periodic_callbacks = [])
    () =
  let config =
    {
      Agent_sdk.Types.default_config with
      name = worker_name;
      model = model_id;
      system_prompt = Some system_prompt;
      enable_thinking = Some thinking_enabled;
    }
  in
  let options =
    {
      Agent_sdk.Agent.default_options with
      provider = Some provider;
      hooks;
      raw_trace = Some raw_trace;
      periodic_callbacks;
    }
  in
  (config, options)
