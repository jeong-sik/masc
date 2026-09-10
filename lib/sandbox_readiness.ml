type architecture = Arm64 | X64
type host = Macos of { architecture : architecture; major : int } | Linux of architecture | Unsupported
type backend = Docker | Apple_container | Nerdctl_kata | Microsandbox | Remote_ssh
type state = Service_ready | Missing_prerequisite of string | Unsupported_host of string
  | Unsupported_capability of string | Probe_failed of string | Needs_configuration of string
type guest_verification = Not_run
type entry = { backend : backend; state : state; guest_verification : guest_verification }
type selection = { backend : backend; network_mode : Keeper_types_profile_sandbox.network_mode;
                   remote_endpoint : string option }
type command_error = Missing_command | Command_failed
type runner = string list -> (string, command_error) result
let all = [Docker; Apple_container; Nerdctl_kata; Microsandbox; Remote_ssh]
let backend_id = function Docker -> "docker" | Apple_container -> "apple_container"
  | Nerdctl_kata -> "nerdctl_kata" | Microsandbox -> "microsandbox" | Remote_ssh -> "remote_ssh"
let backend_of_id id = List.find_opt (fun b -> String.equal id (backend_id b)) all
let profile = function Docker -> Keeper_sandbox_config.Docker
  | Apple_container | Nerdctl_kata | Microsandbox -> Keeper_sandbox_config.Micro_vm
  | Remote_ssh -> Keeper_sandbox_config.Remote_ssh
let microvm_backend = function
  | Apple_container -> Some Keeper_microvm_backend.Apple_container
  | Nerdctl_kata -> Some Keeper_microvm_backend.Nerdctl_kata
  | Microsandbox -> Some Keeper_microvm_backend.Microsandbox
  | Docker | Remote_ssh -> None
let of_microvm = function Keeper_microvm_backend.Apple_container -> Apple_container
  | Nerdctl_kata -> Nerdctl_kata | Microsandbox -> Microsandbox
let architecture = function "arm64" | "aarch64" -> Some Arm64 | "x86_64" -> Some X64 | _ -> None
let detect_host ~run =
  match run ["uname"; "-s"], run ["uname"; "-m"] with
  | Ok os, Ok arch -> (match String.trim os, architecture (String.trim arch) with
    | "Linux", Some arch -> Linux arch
    | "Darwin", Some architecture -> (match run ["sw_vers"; "-productVersion"] with
      | Ok version -> (match String.split_on_char '.' (String.trim version) with
        | major :: _ -> (match int_of_string_opt major with
          | Some major when major > 0 -> Macos {architecture; major} | _ -> Unsupported)
        | [] -> Unsupported)
      | Error _ -> Unsupported)
    | _ -> Unsupported)
  | _ -> Unsupported
let system_runner argv =
  match Process_eio.run_argv_with_status_split_or_refusal
    ~timeout_sec:(Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Env_config_sandbox.Shell_timeout.Read ()) argv with
  | Ok (Unix.WEXITED 0, stdout, _) -> Ok stdout
  | Error (Process_eio.Executable_not_found _) -> Error Missing_command
  | Ok _ | Error _ -> Error Command_failed
let state_message = function
  | Service_ready -> "Service responded; image preparation and guest verification are still required."
  | Missing_prerequisite reason | Unsupported_host reason | Unsupported_capability reason
  | Probe_failed reason | Needs_configuration reason -> reason
let command ~run argv validate =
  match run argv with
  | Error Missing_command -> Missing_prerequisite (String.concat " " argv ^ ": executable missing")
  | Error Command_failed -> Probe_failed (String.concat " " argv ^ ": check failed; inspect the selected service")
  | Ok stdout -> validate stdout
let json stdout f =
  match Yojson.Safe.from_string stdout with
  | value -> f value
  | exception Yojson.Json_error _ -> Probe_failed "Service returned invalid JSON"
let probe ~host ~run ~require_rootless ~require_userns backend =
  let state = match backend, host with
  | Microsandbox, _ -> Unsupported_capability
      "microsandbox cannot express MASC's required cap-drop and read-only root filesystem constraints"
  | Remote_ssh, _ -> Needs_configuration
      "Select a configured SSH endpoint and verify its remote execution; SSH is not a disposable guest"
  | _, Unsupported -> Unsupported_host "Supported hosts are macOS and Linux on ARM64 or x64"
  | Apple_container, (Linux _ | Macos {architecture=X64; _}) ->
    Unsupported_host "Apple Container requires Apple Silicon and macOS 26 or newer"
  | Apple_container, Macos {major; _} when major < 26 ->
    Unsupported_host "Apple Container requires macOS 26 or newer"
  | Apple_container, Macos _ ->
    command ~run ["container"; "list"; "-a"; "--format"; "json"] (fun stdout ->
      json stdout (function `List _ -> Service_ready | _ -> Probe_failed "Apple Container returned an invalid inventory"))
  | Nerdctl_kata, Macos _ -> Unsupported_host "Kata setup requires a Linux host with hardware virtualization"
  | Nerdctl_kata, Linux _ ->
    command ~run ["nerdctl"; "info"; "--format"; "{{json .}}"] (fun stdout ->
      json stdout (function
        | `Assoc fields when List.assoc_opt "OSType" fields = Some (`String "linux") ->
          command ~run ["kata-runtime"; "check"; "--no-network-checks"] (fun _ -> Service_ready)
        | _ -> Probe_failed "nerdctl did not report a Linux containerd service"))
  | Docker, (Macos _ | Linux _) ->
    command ~run ["docker"; "info"; "--format"; "{{json .}}"] (fun stdout ->
      json stdout (function
        | `Assoc fields when List.assoc_opt "OSType" fields = Some (`String "linux") ->
          (match List.assoc_opt "SecurityOptions" fields with
           | Some (`List options) when List.for_all (function `String _ -> true | _ -> false) options ->
             let has name = List.mem (`String ("name=" ^ name)) options in
             if require_rootless && not (has "rootless") then
               Unsupported_capability "The selected Docker daemon is not rootless, as required by configuration"
             else if require_userns && not (has "userns") then
               Unsupported_capability "The selected Docker daemon lacks required user namespaces"
             else Service_ready
           | _ -> Probe_failed "Docker returned invalid SecurityOptions")
        | _ -> Probe_failed "Docker did not report a Linux engine"))
  in {backend; state; guest_verification=Not_run}
let recommend ~host ~configured entries =
  let ready backend = List.exists (fun (row : entry) -> row.backend = backend && row.state = Service_ready) entries in
  match configured with
  | Some backend when ready backend -> Some backend
  | _ ->
    let candidates = match host with
      | Macos {architecture=Arm64; major} when major >= 26 -> [Apple_container; Docker]
      | Macos _ | Linux _ -> [Docker]
      | Unsupported -> [] in
    List.find_opt ready candidates
let state_id = function Service_ready -> "service_ready" | Missing_prerequisite _ -> "missing_prerequisite"
  | Unsupported_host _ -> "unsupported_host" | Unsupported_capability _ -> "unsupported_capability"
  | Probe_failed _ -> "probe_failed" | Needs_configuration _ -> "needs_configuration"
let network_modes = function
  | Docker | Nerdctl_kata -> [Keeper_types_profile_sandbox.Network_none; Network_inherit]
  | Apple_container -> [Keeper_types_profile_sandbox.Network_none; Network_inherit; Network_policy]
  | Microsandbox -> []
  | Remote_ssh -> [Keeper_types_profile_sandbox.Network_inherit]
let catalog_json ~host ~configured entries =
  let recommended = recommend ~host ~configured entries in
  `Assoc ["schema", `String "masc.sandbox_readiness.v1";
    "recommended", (match recommended with None -> `Null | Some b -> `String (backend_id b));
    "candidates", `List (List.map (fun (row : entry) -> `Assoc [
      "id", `String (backend_id row.backend);
      "profile", `String (Keeper_sandbox_config.sandbox_profile_to_string (profile row.backend));
      "state", `String (state_id row.state); "reason", `String (state_message row.state);
      "guest_verification", `String "not_run";
      "capabilities", `Assoc [
        "execution_boundary", `String (match row.backend with Docker -> "container" | Apple_container | Nerdctl_kata | Microsandbox -> "virtual_machine" | Remote_ssh -> "remote_account");
        "network_modes", `List (List.map (fun mode -> `String (Keeper_types_profile_sandbox.network_mode_to_string mode)) (network_modes row.backend));
        "workspace_storage", `String (match row.backend with Docker -> "host_mount" | Apple_container | Nerdctl_kata | Microsandbox -> "guest_volume" | Remote_ssh -> "remote_directory")];
      "configured", `Bool (configured = Some row.backend);
      "setup_args", `List (List.map (fun value -> `String value)
        (["--sandbox-profile"; Keeper_sandbox_config.sandbox_profile_to_string (profile row.backend)]
         @ match microvm_backend row.backend with None -> []
           | Some backend -> ["--microvm-backend"; Keeper_microvm_backend.to_string backend]));
      "recommended", `Bool (recommended = Some row.backend);
      "advanced", `Bool (List.mem row.backend [Nerdctl_kata; Microsandbox; Remote_ssh])]) entries)]
let selection_of_contents ~host ~path ~contents ~profile:requested ~microvm_backend:requested_backend ~network_mode:requested_network =
  let open Result.Syntax in
  let* defaults = Keeper_types_profile.materialization_defaults_of_content ~path contents
    |> Result.map_error Keeper_types_profile.keeper_toml_load_error_to_string in
  let* chosen_profile = match requested, defaults.sandbox_profile with
    | Some p, _ -> Ok p
    | None, Some p -> Ok ((match p with Keeper_types_profile_sandbox.Docker -> Keeper_sandbox_config.Docker | Micro_vm -> Micro_vm | Remote_ssh -> Remote_ssh))
    | None, None -> Error "No sandbox profile is configured" in
  let* backend = match chosen_profile with
    | Keeper_sandbox_config.Docker -> Ok Docker
    | Remote_ssh -> Ok Remote_ssh
    | Micro_vm -> (match requested_backend, defaults.microvm_backend with
      | Some b, _ -> Ok (of_microvm b)
      | None, Some b -> Ok (of_microvm b)
      | None, None -> (match host with
        | Macos {architecture=Arm64; major} when major >= 26 -> Ok Apple_container
        | _ -> Error "Choose a microVM backend explicitly on this host")) in
  let sandbox_profile = match chosen_profile with Keeper_sandbox_config.Docker -> Keeper_types_profile_sandbox.Docker | Micro_vm -> Micro_vm | Remote_ssh -> Remote_ssh in
  let network_mode = match requested_network, defaults.network_mode with
    | Some mode, _ | None, Some mode -> mode
    | None, None -> Keeper_types_profile_sandbox.default_network_mode_for_profile sandbox_profile in
  let* () = match Keeper_types_profile_sandbox.network_mode_rejection sandbox_profile network_mode with
    | None -> Ok () | Some reason -> Error reason in
  let* () = if backend <> Microsandbox && not (List.mem network_mode (network_modes backend)) then
    Error (backend_id backend ^ " does not implement the selected network mode") else Ok () in
  let remote_endpoint = if backend = Remote_ssh then defaults.remote_endpoint else None in
  let* () = if backend = Remote_ssh && remote_endpoint = None then Error "Choose a configured SSH endpoint first" else Ok () in
  Ok {backend; network_mode; remote_endpoint}
let inspect ~base_path =
  let host = detect_host ~run:system_runner in
  let configured, configuration_error = match base_path with
    | None -> None, None
    | Some base_path ->
      let path = Keeper_sandbox_config.keeper_toml_path ~base_path ~agent_name:"imp" in
      (try
        let contents = In_channel.with_open_text path In_channel.input_all in
        match selection_of_contents ~host ~path ~contents ~profile:None
                ~microvm_backend:None ~network_mode:None with
        | Ok selection -> Some selection.backend, None
        | Error _ -> None, Some "imp's sandbox declaration needs repair before it can be prepared."
       with Sys_error _ -> None, Some "imp's sandbox declaration could not be read. Initialize or repair the workspace.") in
  let entries = List.map (probe ~host ~run:system_runner
    ~require_rootless:(Env_config_sandbox.Hardening.require_rootless ())
    ~require_userns:(Env_config_sandbox.Hardening.require_userns ())) all in
  match catalog_json ~host ~configured entries with
  | `Assoc fields -> `Assoc (("configuration_error",
      (match configuration_error with None -> `Null | Some message -> `String message)) :: fields)
  | json -> json

let stage_contents ~path ~contents selection =
  let edit contents key value = Toml_line_editor.edit_table_scalar contents ~path:"keeper" ~key ~value in
  let next = edit contents "sandbox_profile" (Some (Keeper_sandbox_config.sandbox_profile_to_string (profile selection.backend))) in
  let next = edit next "microvm_backend" (Option.map Keeper_microvm_backend.to_string (microvm_backend selection.backend)) in
  let next = edit next "network_mode" (Some (Keeper_types_profile_sandbox.network_mode_to_string selection.network_mode)) in
  let next = edit next "remote_endpoint" selection.remote_endpoint in
  Keeper_types_profile.materialization_defaults_of_content ~path next
  |> Result.map (fun _ -> next)
  |> Result.map_error Keeper_types_profile.keeper_toml_load_error_to_string

let commit_staged ~path ~original ~staged =
  let commit () =
    try
      if (Unix.lstat path).Unix.st_kind <> Unix.S_REG then
        Error "Sandbox manifest must be a regular file"
      else
      let current = In_channel.with_open_text path In_channel.input_all in
      if not (String.equal current original) then
        Error "imp configuration changed during setup; refresh the selection and retry"
      else if String.equal original staged then Ok ()
      else Fs_compat.save_file_atomic_strict path staged
    with
    | Sys_error reason -> Error reason
    | Unix.Unix_error (error, _, _) -> Error (Unix.error_message error) in
  match File_lock_eio.with_durable_lock_observed ~lock_path:(path ^ ".lock") commit with
  | File_lock_eio.Lock_not_acquired error -> Error (File_lock_eio.durable_lock_error_to_string error)
  | File_lock_eio.Body_completed {value=Error reason; _} -> Error reason
  | File_lock_eio.Body_completed {value=Ok (); release_error=None} -> Ok ()
  | File_lock_eio.Body_completed {value=Ok (); release_error=Some error} ->
    Error ("Selection was written, but releasing its lock failed: " ^ File_lock_eio.durable_lock_error_to_string error)
