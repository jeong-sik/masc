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

let close_fd_quietly fd =
  try Unix.close fd with
  | Unix.Unix_error _ -> ()

let remove_path_quietly path =
  try Sys.remove path with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ -> ()

let rec waitpid_nointr flags pid =
  try Unix.waitpid flags pid with
  | Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_nointr flags pid

let wait_for_pid_with_timeout ~clock_opt ~timeout_sec pid =
  let start = Unix.gettimeofday () in
  let rec loop () =
    match waitpid_nointr [ Unix.WNOHANG ] pid with
    | 0, _ ->
        if Unix.gettimeofday () -. start >= float_of_int timeout_sec then
          `Timeout
        else (
          (match clock_opt with
          | Some clock -> Eio.Time.sleep clock 0.2
          | None -> Time_compat.sleep 0.2);
          loop ())
    | _, status -> `Exited status
  in
  loop ()

let run_process_with_timeout ?stdin_content ~clock_opt ~timeout_sec ~prog ~argv ~env () =
  let stdin_path_opt = ref None in
  let stdin_fd_opt = ref None in
  let stdout_fd_opt = ref None in
  let stderr_fd_opt = ref None in
  let stdout_path = Filename.temp_file "masc_docker_stdout_" ".log" in
  let stderr_path = Filename.temp_file "masc_docker_stderr_" ".log" in
  let cleanup_setup () =
    Option.iter close_fd_quietly !stdin_fd_opt;
    stdin_fd_opt := None;
    Option.iter close_fd_quietly !stdout_fd_opt;
    stdout_fd_opt := None;
    Option.iter close_fd_quietly !stderr_fd_opt;
    stderr_fd_opt := None;
    Option.iter remove_path_quietly !stdin_path_opt;
    stdin_path_opt := None;
    remove_path_quietly stdout_path;
    remove_path_quietly stderr_path
  in
  let pid =
    try
      let stdin_fd =
        match stdin_content with
        | None -> Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0
        | Some content ->
            let stdin_path, oc =
              Filename.open_temp_file ~mode:[ Open_wronly; Open_creat; Open_trunc; Open_binary ]
                ~perms:0o600 "masc_docker_stdin_" ".log"
            in
            stdin_path_opt := Some stdin_path;
            Out_channel.output_string oc content;
            close_out oc;
            Unix.openfile stdin_path [ Unix.O_RDONLY ] 0
      in
      stdin_fd_opt := Some stdin_fd;
      let stdout_fd =
        Unix.openfile stdout_path
          [ Unix.O_CREAT; Unix.O_TRUNC; Unix.O_WRONLY ] 0o600
      in
      stdout_fd_opt := Some stdout_fd;
      let stderr_fd =
        Unix.openfile stderr_path
          [ Unix.O_CREAT; Unix.O_TRUNC; Unix.O_WRONLY ] 0o600
      in
      stderr_fd_opt := Some stderr_fd;
      let pid =
        Unix.create_process_env prog (Array.of_list argv) env stdin_fd stdout_fd
          stderr_fd
      in
      close_fd_quietly stdin_fd;
      stdin_fd_opt := None;
      close_fd_quietly stdout_fd;
      stdout_fd_opt := None;
      close_fd_quietly stderr_fd;
      stderr_fd_opt := None;
      pid
    with exn ->
      cleanup_setup ();
      raise exn
  in
  let finalize exit_code =
    let stdout = In_channel.with_open_bin stdout_path In_channel.input_all in
    let stderr = In_channel.with_open_bin stderr_path In_channel.input_all in
    (match !stdin_path_opt with
    | Some stdin_path -> (
        try Sys.remove stdin_path
        with Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
             Log.Worker.warn "failed to remove stdin tmpfile %s: %s" stdin_path
               (Printexc.to_string exn))
    | None -> ());
    (try Sys.remove stdout_path with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      Log.Worker.warn "failed to remove stdout tmpfile %s: %s" stdout_path (Printexc.to_string exn));
    (try Sys.remove stderr_path with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      Log.Worker.warn "failed to remove stderr tmpfile %s: %s" stderr_path (Printexc.to_string exn));
    { exit_code; stdout; stderr }
  in
  match wait_for_pid_with_timeout ~clock_opt ~timeout_sec pid with
  | `Exited (Unix.WEXITED code) -> finalize code
  | `Exited (Unix.WSIGNALED code) -> finalize (128 + code)
  | `Exited (Unix.WSTOPPED code) -> finalize (256 + code)
  | `Timeout ->
      (try Unix.kill pid Sys.sigterm with
       | Unix.Unix_error (Unix.ESRCH, _, _) -> ()
       | exn -> Log.Worker.warn "sigterm pid %d: %s" pid (Printexc.to_string exn));
      (match clock_opt with
      | Some clock -> Eio.Time.sleep clock 1.0
      | None -> Time_compat.sleep 1.0);
      (match waitpid_nointr [ Unix.WNOHANG ] pid with
      | 0, _ ->
          (try Unix.kill pid Sys.sigkill with
           | Unix.Unix_error (Unix.ESRCH, _, _) -> ()
           | exn -> Log.Worker.warn "sigkill pid %d: %s" pid (Printexc.to_string exn));
          ignore (waitpid_nointr [] pid)
      | _, _ -> ());
      finalize 124

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

let is_loopback_host = function
  | Some "localhost" | Some "127.0.0.1" -> true
  | Some host when String.starts_with ~prefix:"127." host -> true
  | _ -> false

let rewrite_loopback_url value =
  let uri = Uri.of_string value in
  if is_loopback_host (Uri.host uri) then
    Uri.with_host uri (Some docker_host_alias) |> Uri.to_string
  else value

let docker_http_base_url () =
  match Worker_runtime_config.host_mcp_base_url_opt () with
  | Some url -> url
  | None -> rewrite_loopback_url (Env_config.masc_http_base_url ())

let docker_mcp_url () =
  match Sys.getenv_opt "MASC_MCP_URL" with
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
      "MASC_STORAGE_TYPE";
      "MASC_BASE_PATH";
      "MASC_CONFIG_DIR";
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
      ("MASC_BASE_PATH", "");
      ("MASC_HTTP_BASE_URL", docker_http_base_url ());
      ("MASC_MCP_URL", docker_mcp_url ());
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
    (String.lowercase_ascii (Room_utils.safe_filename token))
    unique_suffix

let artifact_dir (spec : Worker_execution_spec.t) =
  Worker_container.worker_container_dir ~base_path:spec.base_path
    ~worker_name:spec.worker_name

let stderr_artifact_path (spec : Worker_execution_spec.t) =
  let suffix =
    match spec.worker_run_id with
    | Some worker_run_id when String.trim worker_run_id <> "" ->
        Room_utils.safe_filename worker_run_id
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
       ~timeout_sec:10 ~prog:"docker"
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
          ~timeout_sec:20 ~prog:"docker"
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
            ~timeout_sec:20 ~prog:"docker"
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
