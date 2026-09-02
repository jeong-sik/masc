(** OpenSSH endpoint resolution for the [Remote_ssh] keeper sandbox profile.

    The runner itself is transport-neutral ({!Keeper_sandbox_remote}). This
    module owns what is OpenSSH-specific: the runtime.toml endpoint registry,
    the dedicated key and pinned host-key paths, and the ControlPath
    directory. *)

let ( let* ) = Result.bind

let resolve_path ~base_path path =
  if Filename.is_relative path then Filename.concat base_path path else path
;;

let runtime_config_path ~base_path =
  (* Resolver SSOT (RFC-0121). The previous inline concat probed
     <base>/.masc/runtime.toml — a path the live layout has never used
     (runtime.toml lives under .masc/config/), so the probe always fell
     through to [Runtime.config_path]. The resolver names the real file. *)
  let workspace_path = Config_dir_resolver.runtime_toml_path_for_base_path ~base_path in
  if Sys.file_exists workspace_path then Some workspace_path else Runtime.config_path ()
;;

let resolve_endpoint_name ~base_path ~name:endpoint_name =
  let endpoint_name = String.trim endpoint_name in
  let* config_path =
    runtime_config_path ~base_path
    |> Option.to_result
         ~none:
           (Printf.sprintf
              "remote_ssh_runtime_config_missing: endpoint %s cannot be resolved because runtime.toml is unavailable"
              endpoint_name)
  in
  let* runtime_config =
    Runtime_toml.parse_file config_path
    |> Result.map_error (fun errors ->
      let details =
        errors
        |> List.map Runtime_toml.show_parse_error
        |> String.concat "; "
      in
      Printf.sprintf
        "remote_ssh_runtime_config_invalid: endpoint %s: %s"
        endpoint_name details)
  in
  Runtime_schema.exec_ssh_endpoint runtime_config endpoint_name
  |> Option.to_result
       ~none:
         (Printf.sprintf
            "remote_ssh_endpoint_unknown: endpoint %s is not declared in [exec.ssh.endpoints]"
            endpoint_name)
;;

let resolve_endpoint ~base_path ~keeper_name =
  let* defaults =
    Keeper_types_profile.load_keeper_profile_defaults_result_for_base_path
      ~base_path keeper_name
    |> Result.map_error Keeper_types_profile.keeper_toml_load_error_to_string
  in
  let* endpoint_name =
    match defaults.remote_endpoint with
    | Some name when String.trim name <> "" -> Ok (String.trim name)
    | _ ->
      Error
        (Printf.sprintf
           "remote_ssh_endpoint_missing: keeper %s has no remote_endpoint"
           keeper_name)
  in
  resolve_endpoint_name ~base_path ~name:endpoint_name
;;

let ssh_bin_override : string option Atomic.t = Atomic.make None

let ensure_control_path_dir path =
  try
    Fs_compat.mkdir_p path;
    Unix.chmod path 0o700;
    Ok ()
  with
  | Sys_error msg | Unix.Unix_error (_, _, msg) ->
    Error
      (Printf.sprintf
         "remote_ssh_control_path_unavailable: cannot create %s: %s"
         path msg)
;;

let create ?ssh_bin ~base_path ~keeper_name
    ~(endpoint : Exec_ssh_endpoint.t) () =
  let* () =
    Exec_ssh_endpoint.validate_destination
      ~host:endpoint.host ~user:endpoint.user
  in
  let ssh_bin =
    match ssh_bin with
    | Some path -> path
    | None -> Option.value (Atomic.get ssh_bin_override) ~default:"ssh"
  in
  let control_path_dir = Config_dir_resolver.run_ssh_dir ~base_path in
  let* () = ensure_control_path_dir control_path_dir in
  Ok
    (Keeper_sandbox_remote.of_openssh ~base_path ~keeper_name
       { endpoint
       ; ssh_bin
       ; identity_file = resolve_path ~base_path endpoint.identity_file
       ; known_hosts_file = resolve_path ~base_path endpoint.known_hosts_file
       ; control_path_dir
       })
;;

let sandbox_endpoint ~base_path (endpoint : Exec_ssh_endpoint.t)
    : Masc_exec.Sandbox_target.ssh_endpoint =
  { name = endpoint.name
  ; host = endpoint.host
  ; user = endpoint.user
  ; port = endpoint.port
  ; identity_file = resolve_path ~base_path endpoint.identity_file
  ; known_hosts_file = resolve_path ~base_path endpoint.known_hosts_file
  ; remote_root = endpoint.remote_root
  ; connect_timeout_sec = endpoint.connect_timeout_sec
  ; env_allowlist = endpoint.env_allowlist
  }
;;

module For_testing = struct
  let set_ssh_bin_override value = Atomic.set ssh_bin_override value
end
