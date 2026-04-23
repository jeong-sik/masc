(** Worker_container — worker container, meta, checkpoint, and tool building. *)

open Printf

include Worker_container_types

let tool_profile_to_string = function
  | Profile_session_min -> "session_min"
  | Profile_session_dev -> "session_dev"

let tool_profile_of_string = function
  | "session_min" -> Some Profile_session_min
  | "session_dev" -> Some Profile_session_dev
  | _ -> None

let shell_profile_to_string = function
  | Shell_none -> "none"
  | Shell_readonly -> "readonly"
  | Shell_dev -> "dev"

let shell_profile_of_string = function
  | "none" -> Some Shell_none
  | "readonly" -> Some Shell_readonly
  | "dev" -> Some Shell_dev
  | _ -> None

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

let oas_tool_error ?(recoverable = false) message : Oas.Types.tool_result =
  Error { Oas.Types.message; recoverable; error_class = None }

let oas_trace_session_root ~base_path =
  Filename.concat (Common.masc_dir_from_base_path ~base_path) "oas-runtime"

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
  Tool_catalog.tools_for_surface Tool_catalog.Session_min

(* Model tier inference removed (#4505). Cascade handles model selection
   without hardcoded name→tier mapping. *)

let default_tool_profile = Profile_session_dev
let default_shell_profile = Shell_dev

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
      ("thinking_enabled", Option.fold ~none:`Null ~some:(fun v -> `Bool v) meta.thinking_enabled);
      ("max_turns_override", Option.fold ~none:`Null ~some:(fun n -> `Int n) meta.max_turns_override);
      ("timeout_seconds", Option.fold ~none:`Null ~some:(fun n -> `Int n) meta.timeout_seconds);
      ("tool_profile", `String (tool_profile_to_string meta.tool_profile));
      ("shell_profile", `String (shell_profile_to_string meta.shell_profile));
      ( "worker_class",
        Option.fold ~none:`Null
          ~some:(fun kind ->
            `String (Worker_types.worker_class_to_string kind))
          meta.worker_class );
      ("effective_model", `String meta.effective_model);
      ("checkpoint_path", `String meta.checkpoint_path);
      ("turn_log_path", `String meta.turn_log_path);
      ( "last_run_at",
        Option.fold ~none:`Null ~some:(fun ts -> `Float ts) meta.last_run_at );
    ]

let worker_meta_of_yojson json =
  let open Yojson.Safe.Util in
  match json with
  | `Assoc _ -> (
      match json |> member "worker_name" |> to_string_option with
      | None -> None
      | Some worker_name ->
          Some
            {
              version =
                json |> member "version" |> to_int_option
                |> Option.value ~default:worker_container_version;
              worker_name;
              mcp_session_id =
                json |> member "mcp_session_id" |> to_string_option
                |> Option.value ~default:(stable_worker_session_id worker_name);
              workspace_path =
                json |> member "workspace_path" |> to_string_option
                |> Option.value ~default:"";
              role = json |> member "role" |> to_string_option;
              selection_note =
                json |> member "selection_note" |> to_string_option;
              thinking_enabled =
                json |> member "thinking_enabled" |> to_bool_option;
              max_turns_override =
                json |> member "max_turns_override" |> to_int_option;
              timeout_seconds =
                json |> member "timeout_seconds" |> to_int_option;
              tool_profile =
                (match json |> member "tool_profile" |> to_string_option with
                | Some value -> (
                    match tool_profile_of_string value with
                    | Some profile -> profile
                    | None -> default_tool_profile)
                | None -> default_tool_profile);
              shell_profile =
                (match json |> member "shell_profile" |> to_string_option with
                | Some value -> (
                    match shell_profile_of_string value with
                    | Some profile -> profile
                    | None -> default_shell_profile)
                | None -> default_shell_profile);
              worker_class =
                (match json |> member "worker_class" |> to_string_option with
                | Some value ->
                    Worker_types.worker_class_of_string
                      (String.lowercase_ascii (String.trim value))
                | None -> None);
              effective_model =
                json |> member "effective_model" |> to_string_option
                |> Option.value ~default:"";
              checkpoint_path =
                json |> member "checkpoint_path" |> to_string_option
                |> Option.value ~default:"";
              turn_log_path =
                json |> member "turn_log_path" |> to_string_option
                |> Option.value ~default:"";
              last_run_at = json |> member "last_run_at" |> to_float_option;
            })
  | _ -> None

let load_worker_meta ~base_path ~worker_name =
  let path = worker_meta_path ~base_path ~worker_name in
  if Sys.file_exists path then
    try
      Safe_ops.read_json_eio path |> worker_meta_of_yojson
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
      Oas.Checkpoint.of_string raw |> Result.to_option
    with Sys_error _ -> None
  else
    None

let save_worker_checkpoint ~base_path ~worker_name checkpoint =
  try
    ensure_worker_container_dirs ~base_path ~worker_name;
    Fs_compat.save_file
      (worker_checkpoint_path ~base_path ~worker_name)
      (Oas.Checkpoint.to_string checkpoint);
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

let build_oas_mcp_tools ~sw ~auth_token ~session_id ~worker_name ~prompt:_
    ~allowed_tools =
  let allowed_names =
    match allowed_tools |> List.map strip_mcp_prefix |> unique_preserve_order with
    | [] -> session_min_tool_names
    | names -> names
  in
  let listed_schemas =
    list_masc_tools ~sw ~auth_token ~session_id ~names:(Some allowed_names) ()
  in
  Result.map
    (fun schemas ->
      schemas
      |> List.filter (fun (schema : Types.tool_schema) ->
             List.mem schema.name allowed_names)
      |> List.map (fun (schema : Types.tool_schema) ->
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
                 Ok { Oas.Types.content = result.text }
               | Error e ->
                 oas_tool_error e
             in
             Oas.Mcp.mcp_tool_to_sdk_tool ~call_fn
               {
                 Oas.Mcp.name = schema.name;
                 description = schema.description;
                 input_schema = schema.input_schema;
               }))
    listed_schemas

let build_local_shell_tools ~room_config ~worker_name ~workdir =
  match Process_eio.get_proc_mgr (), Process_eio.get_clock () with
  | Ok proc_mgr, Ok clock -> (
      let on_exec ~tool_name ~success ~duration_ms =
        (match room_config, Fs_compat.get_fs_opt () with
        | Some config, Some fs -> (
            try
              Telemetry_eio.track_tool_called ~fs config ~tool_name ~success
                ~duration_ms ~agent_id:worker_name ()
            with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
              Log.LocalWorker.warn "telemetry error for %s/%s: %s"
                worker_name tool_name (Printexc.to_string exn))
        | _ -> ());
        ()
      in
      Ok
        (Worker_dev_tools.make_tools ~proc_mgr ~clock ~workdir
           ~on_exec ()))
  | Error e, _ | _, Error e -> Error e

(** Convert a model label to an OAS Provider.config.
    Returns Error when the label cannot be parsed. *)
let oas_provider_of_label (label : string) :
    (Oas.Provider.config, string) result =
  match Cascade_config.parse_model_string label with
  | Some pc -> Ok (Oas.Provider.config_of_provider_config pc)
  | None ->
    let msg = Printf.sprintf "Cannot parse model label: %S (expected provider:model)" label in
    Log.Misc.error "%s" msg;
    Error msg

(** Resolve provider from a model label string.
    Returns the provider config and model_id on success. *)
let resolve_oas_provider_of_label (label : string) :
    (Oas.Provider.config * string, string) result =
  match Cascade_config.parse_model_string label with
  | None -> Error (Printf.sprintf "Cannot parse model: %s" label)
  | Some pc ->
    Ok
      ( Oas.Provider.config_of_provider_config pc,
        pc.Llm_provider.Provider_config.model_id )

let oas_tool_names (tools : Oas.Tool.t list) =
  List.map (fun (tool : Oas.Tool.t) -> tool.schema.name) tools

let make_worker_meta ~base_path ~workspace_path ~worker_name
    ~mcp_session_id ~role ~selection_note ~worker_class
    ~effective_model ~thinking_enabled ~max_turns_override
    ~timeout_seconds =
  {
    version = worker_container_version;
    worker_name;
    mcp_session_id;
    workspace_path;
    role;
    selection_note;
    thinking_enabled;
    max_turns_override;
    timeout_seconds;
    tool_profile = default_tool_profile;
    shell_profile = default_shell_profile;
    worker_class;
    effective_model;
    checkpoint_path =
      worker_checkpoint_path ~base_path ~worker_name;
    turn_log_path =
      worker_turn_log_path ~base_path ~worker_name;
    last_run_at = None;
  }

let append_worker_completion_log ~base_path ~worker_name
    ~prompt ~tool_names ~status ~output ?error ?raw_trace_run
    ?evidence_session_id ?proof_run_id ?proof_result_status () =
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
          | Some run_ref -> Oas.Raw_trace.run_ref_to_yojson run_ref
          | None -> `Null );
        ( "evidence_session_id",
          Option.fold ~none:`Null ~some:(fun value -> `String value)
            evidence_session_id );
        ( "proof_run_id",
          Option.fold ~none:`Null ~some:(fun value -> `String value)
            proof_run_id );
        ( "proof_result_status",
          Option.fold ~none:`Null ~some:(fun value -> `String value)
            proof_result_status );
        ( "error",
          Option.fold ~none:`Null ~some:(fun value -> `String value) error );
      ])

(** Build (config, options) for Agent.resume — the continue_worker path.
    New workers use Worker_oas.build_agent (Builder pattern) instead.
    Accepts [~provider] + [~model_id] as resolved values. *)
let build_resume_config ~worker_name ~provider ~model_id ~system_prompt ~tools
    ~max_turns ~thinking_enabled ~hooks ~raw_trace ?(periodic_callbacks = [])
    ?(guardrails : Oas.Guardrails.t option)
    ?(tool_retry_policy : Oas.Tool_retry_policy.t option)
    () =
  let config =
    {
      Oas.Types.default_config with
      name = worker_name;
      model = model_id;
      system_prompt = Some system_prompt;
      max_tokens = Some (local_worker_max_tokens ());
      max_turns;
      temperature = Some Oas_worker_cascade.worker_temperature;
      top_p = Some Oas_worker_cascade.worker_top_p;
      top_k = Some Oas_worker_cascade.worker_top_k;
      (* min_p is effectively disabled (0.0) and some cloud providers
         reject the field itself even when the value is a no-op. *)
      min_p = None;
      enable_thinking = Some thinking_enabled;
      tool_choice = Some Oas.Types.Auto;
    }
  in
  let effective_guardrails =
    match guardrails with
    | Some g -> g
    | None ->
        { Oas.Guardrails.tool_filter =
            Oas.Guardrails.AllowList (oas_tool_names tools);
          max_tool_calls_per_turn = Some Oas_worker_cascade.worker_max_tool_calls_per_turn;
        }
  in
  let options =
    {
      Oas.Agent.default_options with
      provider = Some provider;
      hooks;
      guardrails = effective_guardrails;
      raw_trace = Some raw_trace;
      tool_retry_policy;
      periodic_callbacks;
    }
  in
  (config, options)

let materialize_direct_evidence ~base_path ~worker_name
    ~(worker_run_id : string option) ~(meta : worker_container_meta) ~prompt
    ~workspace_path ~agent ~raw_trace =
  match evidence_session_id_of_worker_run worker_run_id with
  | None -> ()
  | Some session_id ->
      let aliases =
        unique_preserve_order
          ([ worker_name ]
          @
          match meta.role with
          | Some role
            when String.trim role <> ""
                 && not (String.equal role worker_name) ->
              [ role ]
          | _ -> [])
      in
      let options =
        {
          Oas.Direct_evidence.session_root =
            Some (oas_trace_session_root ~base_path);
          session_id;
          goal = prompt;
          title = Some (Printf.sprintf "MASC worker %s" worker_name);
          tag = Some "masc-team-worker";
          worker_id =
            Some (stable_worker_session_id worker_name);
          runtime_actor = Some worker_name;
          role = meta.role;
          aliases;
          requested_provider = Some "local";
          requested_model = Some meta.effective_model;
          requested_policy = None;
          workdir = Some workspace_path;
        }
      in
      match Oas.Direct_evidence.persist ~agent ~raw_trace ~options () with
      | Ok _ -> ()
      | Error err ->
          Log.LocalWorker.error
            "direct evidence persist failed for %s/%s: %s"
            worker_name session_id (Oas.Error.to_string err)
