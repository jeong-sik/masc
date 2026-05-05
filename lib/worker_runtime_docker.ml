type preflight_subject = {
  worker_name : string;
  model_label : string;
}

type process_result = {
  exit_code : int;
  stdout : string;
  stderr : string;
}

let tail_display_max_chars = 4000

let tail_text ?(max_chars = tail_display_max_chars) text =
  let len = String.length text in
  if len <= max_chars then text
  else String.sub text (len - max_chars) max_chars

let exit_code_of_status = function
  | Unix.WEXITED code -> code
  | Unix.WSIGNALED code -> 128 + code
  | Unix.WSTOPPED code -> 256 + code

let run_process_with_timeout ?stdin_content ~clock_opt:_ ~timeout_sec ~prog:_ ~argv
    ~env () =
  let raw_source = String.concat " " (List.map Filename.quote argv) in
  let status, stdout, stderr =
    match stdin_content with
    | Some content ->
        Masc_exec.Exec_gate.run_argv_with_stdin_and_status_split
          ~actor:"system/worker_runtime_docker"
          ~raw_source
          ~summary:"worker runtime docker subprocess"
          ~timeout_sec:(float_of_int timeout_sec)
          ~env
          ~stdin_content:content
          argv
    | None ->
        Masc_exec.Exec_gate.run_argv_with_status_split
          ~actor:"system/worker_runtime_docker"
          ~raw_source
          ~summary:"worker runtime docker subprocess"
          ~timeout_sec:(float_of_int timeout_sec)
          ~env
          argv
  in
  { exit_code = exit_code_of_status status; stdout; stderr }

let helper_binary = "masc-worker-run"
let docker_host_alias = "host.docker.internal"
let container_counter = Atomic.make 0

let path_within ~root path =
  let root =
    if String.ends_with ~suffix:"/" root then root
    else root ^ "/"
  in
  path = String.sub root 0 (String.length root - 1)
  || String.starts_with ~prefix:root path

let host_is_linux () =
  Sys.os_type = "Unix" && Sys.file_exists "/proc/version"

let rewrite_loopback_url value =
  let uri = Uri.of_string value in
  if Masc_network_defaults.is_loopback_host_opt (Uri.host uri) then
    Uri.with_host uri (Some docker_host_alias) |> Uri.to_string
  else value

let docker_http_base_url () =
  match Worker_runtime_config.host_mcp_base_url_opt () with
  | Some url -> url
  | None -> rewrite_loopback_url (Env_config.masc_http_base_url ())

let docker_mcp_url () =
  match Sys.getenv_opt Env_config_core.mcp_url_env_key with
  | Some value when String.trim value <> "" -> rewrite_loopback_url value
  | _ -> docker_http_base_url () ^ "/mcp"

let docker_llama_server_url () =
  rewrite_loopback_url Env_config.Local_runtime.server_url

let rewrite_model_label_for_container model_label =
  if String.starts_with ~prefix:"custom:" model_label then
    match Cascade_config.parse_model_string model_label with
    | Some cfg ->
        let rewritten = rewrite_loopback_url cfg.Llm_provider.Provider_config.base_url in
        if String.equal rewritten cfg.Llm_provider.Provider_config.base_url then
          model_label
        else
          Printf.sprintf "custom:%s@%s"
            cfg.Llm_provider.Provider_config.model_id rewritten
    | None -> model_label
  else model_label

let rewrite_spec_for_container (spec : Worker_execution_spec.t) =
  { spec with model_label = rewrite_model_label_for_container spec.model_label }

let allowlisted_env_pairs () =
  let keys =
    Provider_adapter.all_auth_env_keys ()
    @ [
      "GOOGLE_CLOUD_PROJECT";
      "GOOGLE_CLOUD_LOCATION";
      Env_config_core.storage_type_env_key;
      Env_config_core.base_path_env_key;
      Env_config_core.config_dir_env_key;
      "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL";
      "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL_SCHEDULED_AUTONOMOUS";
    ]
  in
  let inherited =
    keys
    |> List.filter_map (fun key ->
           match Sys.getenv_opt key with
           | Some value when String.trim value <> "" -> Some (key, value)
           | _ -> None)
  in
  let overrides =
    [
      (Env_config_core.base_path_env_key, "");
      (Env_config_core.http_base_url_env_key, docker_http_base_url ());
      (Env_config_core.mcp_url_env_key, docker_mcp_url ());
      ("LLAMA_SERVER_URL", docker_llama_server_url ());
    ]
  in
  (* Keys with empty override values signal removal from inherited env. *)
  let cleared_keys =
    overrides
    |> List.filter_map (fun (key, value) ->
           if String.trim value = "" then Some key else None)
  in
  let inherited =
    inherited
    |> List.filter (fun (key, _) -> not (List.mem key cleared_keys))
  in
  let overrides =
    overrides
    |> List.filter_map (fun (key, value) ->
           let trimmed = String.trim value in
           if trimmed = "" then None else Some (key, trimmed))
  in
  Array.of_list (List.map (fun (key, value) -> key ^ "=" ^ value) (inherited @ overrides))

let container_name (spec : Worker_execution_spec.t) =
  let token =
    match spec.worker_run_id with
    | Some worker_run_id when String.trim worker_run_id <> "" ->
        worker_run_id
    | _ -> spec.worker_name
  in
  let unique_suffix =
    Printf.sprintf "%d-%d-%d" (Unix.getpid ())
      (int_of_float (Unix.gettimeofday () *. 1000.0))
      (Atomic.fetch_and_add container_counter 1)
  in
  Printf.sprintf "masc-worker-%s-%s"
    (String.lowercase_ascii (Coord_utils.safe_filename token))
    unique_suffix

let artifact_dir (spec : Worker_execution_spec.t) =
  Worker_container.worker_container_dir ~base_path:spec.base_path
    ~worker_name:spec.worker_name

let stderr_artifact_path (spec : Worker_execution_spec.t) =
  let suffix =
    match spec.worker_run_id with
    | Some worker_run_id when String.trim worker_run_id <> "" ->
        Coord_utils.safe_filename worker_run_id
    | _ -> "latest"
  in
  Filename.concat (artifact_dir spec)
    (Printf.sprintf "docker-stderr-%s.log" suffix)

let persist_stderr_artifact (spec : Worker_execution_spec.t) stderr =
  if String.trim stderr <> "" then (
    Worker_container.ensure_worker_container_dirs ~base_path:spec.base_path
      ~worker_name:spec.worker_name;
    Fs_compat.save_file (stderr_artifact_path spec) stderr)

let best_effort_remove_container ?clock_opt name =
  ignore
    (run_process_with_timeout ~clock_opt
       ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Sandbox ()) ~prog:"docker"
       ~argv:[ "docker"; "rm"; "-f"; name ]
       ~env:(Unix.environment ()) ())

let mount_args (spec : Worker_execution_spec.t) =
  let base_mount = [ "-v"; spec.base_path ^ ":" ^ spec.base_path ^ ":rw" ] in
  let config_mount =
    let resolution = Config_dir_resolver.resolve () in
    let config_root = resolution.Config_dir_resolver.config_root.path in
    if path_within ~root:spec.base_path config_root then []
    else [ "-v"; config_root ^ ":" ^ config_root ^ ":ro" ]
  in
  base_mount @ config_mount

let auth_requirements_of_model_label model_label =
  match Cascade_config.parse_model_string model_label with
  | None -> Ok []
  | Some cfg ->
    let keys = Provider_adapter.docker_auth_env_keys_of_provider_config cfg in
    let missing = List.filter (fun key ->
      match Sys.getenv_opt key with Some v -> String.trim v = "" | None -> true
    ) keys in
    if missing = [] then Ok keys
    else
      let kind_name = Provider_adapter.cascade_prefix_of_provider_kind cfg.Llm_provider.Provider_config.kind in
      Error (Printf.sprintf "%s Docker workers require %s" kind_name (String.concat ", " missing))

let missing_required_envs keys =
  keys
  |> List.filter (fun key ->
         match Sys.getenv_opt key with
         | Some value -> String.trim value = ""
         | None -> true)

let preflight_batch ?clock_opt (subjects : preflight_subject list) =
  let image = Worker_runtime_config.docker_image () in
  if String.trim image = "" then
    Error "worker runtime Docker image is not configured"
  else
      let info_result =
        run_process_with_timeout ~clock_opt
          ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Sandbox ()) ~prog:"docker"
          ~argv:[ "docker"; "info" ]
          ~env:(Unix.environment ()) ()
    in
    if info_result.exit_code <> 0 then
      Error
        (Printf.sprintf "docker info failed: %s"
           (tail_text info_result.stderr))
    else
        let image_result =
          run_process_with_timeout ~clock_opt
            ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Sandbox ()) ~prog:"docker"
            ~argv:[ "docker"; "image"; "inspect"; image ]
            ~env:(Unix.environment ()) ()
      in
      if image_result.exit_code <> 0 then
        Error
          (Printf.sprintf "docker image inspect failed for %s: %s" image
             (tail_text image_result.stderr))
      else
        let rec check_auth = function
          | [] -> Ok ()
          | subject :: rest -> (
              match auth_requirements_of_model_label subject.model_label with
              | Error msg ->
                  Error
                    (Printf.sprintf "%s (%s)" msg subject.worker_name)
              | Ok keys -> (
                  match missing_required_envs keys with
                  | [] -> check_auth rest
                  | missing ->
                      Error
                        (Printf.sprintf
                           "missing env for Docker worker %s: %s"
                           subject.worker_name
                           (String.concat ", " missing))))
        in
        check_auth subjects

let docker_argv ~container_name (spec : Worker_execution_spec.t) =
  let image = Worker_runtime_config.docker_image () in
  let env_flags =
    allowlisted_env_pairs ()
    |> Array.to_list
    |> List.filter_map (fun pair ->
           match String.index_opt pair '=' with
           | Some idx ->
               let key = String.sub pair 0 idx in
               let value =
                 String.sub pair (idx + 1) (String.length pair - idx - 1)
               in
               if String.trim value = "" then None
               else Some [ "-e"; key ^ "=" ^ value ]
           | None -> None)
    |> List.flatten
  in
  let linux_host_flags =
    if host_is_linux () then
      [ "--add-host"; docker_host_alias ^ ":host-gateway" ]
    else []
  in
  [
    "docker";
    "run";
    "--rm";
    "--name";
    container_name;
    "-i";
    "--cap-drop=ALL";
    "--security-opt";
    "no-new-privileges";
    "--pids-limit";
    "256";
    "--memory";
    "4g";
    "--workdir";
    (match spec.working_dir with
    | Some dir when String.trim dir <> "" -> dir
    | _ -> spec.base_path);
  ]
  @ linux_host_flags @ mount_args spec @ env_flags
  @ [ "--entrypoint"; helper_binary; image; "--spec-stdin" ]

let run_worker_spec ?clock_opt (spec : Worker_execution_spec.t) :
    (Worker_container_types.run_result, string) result =
  let name = container_name spec in
  Fun.protect
    ~finally:(fun () -> best_effort_remove_container ?clock_opt name)
    (fun () ->
      let effective_timeout_sec = max 10 spec.timeout_sec in
      let stdin_content =
        Worker_execution_spec.to_yojson spec |> Yojson.Safe.to_string
      in
      let result =
        run_process_with_timeout ~clock_opt
          ~stdin_content ~timeout_sec:effective_timeout_sec
          ~prog:"docker" ~argv:(docker_argv ~container_name:name spec)
          ~env:(Unix.environment ()) ()
      in
      persist_stderr_artifact spec result.stderr;
      match result.exit_code with
      | 0 -> (
          match Worker_runtime_helper_protocol.parse_stdout result.stdout with
          | Ok (Ok run_result) -> Ok run_result
          | Ok (Error payload) ->
              Error
                (Printf.sprintf "Docker worker runtime error (%s): %s"
                   (Worker_runtime_helper_protocol.error_kind_to_string
                      payload.kind)
                   payload.message)
          | Error msg ->
              Error
                (Printf.sprintf
                   "failed to decode Docker worker output: %s%s"
                   msg
                   (if String.trim result.stderr = "" then ""
                    else
                      "\n[stderr]\n"
                      ^ tail_text result.stderr)))
      | 124 ->
          Error
            (Printf.sprintf "Docker worker timed out after %ds%s"
               effective_timeout_sec
               (if String.trim result.stderr = "" then ""
                else
                  "\n[stderr]\n"
                  ^ tail_text result.stderr))
      | _ ->
          let stderr_tail =
            if String.trim result.stderr = "" then ""
            else
              "\n[stderr]\n"
              ^ tail_text result.stderr
          in
          (match Worker_runtime_helper_protocol.parse_stdout result.stdout with
          | Ok (Ok _run_result) ->
              Error
                (Printf.sprintf
                   "docker run exited with code %d after producing a success envelope%s"
                   result.exit_code stderr_tail)
          | Ok (Error payload) ->
              Error
                (Printf.sprintf "Docker worker failed (%s): %s%s"
                   (Worker_runtime_helper_protocol.error_kind_to_string
                      payload.kind)
                   payload.message stderr_tail)
          | Error _ ->
              Error
                (Printf.sprintf "docker run exited with code %d%s"
                   result.exit_code stderr_tail)))
