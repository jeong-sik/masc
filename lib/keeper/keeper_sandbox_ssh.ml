(** OpenSSH endpoint resolution for the [Remote_ssh] keeper sandbox profile.

    The runner itself is transport-neutral ({!Keeper_sandbox_remote}). This
    module owns what is OpenSSH-specific: the runtime.toml endpoint registry,
    the dedicated key and pinned host-key paths. *)

open Result.Syntax

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

(* The endpoint registry of the runtime.toml bytes last read. A [Remote_ssh]
   Keeper resolves its endpoint on every Execute call, and each call parsed
   the whole file on the caller's domain, which is the main one: 12 to 183 ms
   and 16 MB of allocation for a 74 KB runtime.toml ([Otoml.Parser.from_file]
   alone, 30 runs on a loaded host, 2026-11-11). On a live root that was the
   run after each read of a Keeper's TOML, 680 ms of one 30 s window.

   The file is still read on every call and compared byte for byte, so an
   edit applies to the next call as it did. This module reads the endpoint
   list of what is kept and nothing else: nothing in that list depends on
   the process environment, which other parts of a parsed runtime.toml do. *)
type registry_reading =
  { config_path : string
  ; bytes : string
  ; parsed : (Runtime_schema.config, Runtime_toml.parse_error list) result
  }

let last_registry_reading : registry_reading option Atomic.t = Atomic.make None

(* The errors [Runtime_toml.parse_file] gives for the same file. *)
let parse_registry ~config_path bytes =
  match Otoml.Parser.from_string bytes with
  | toml -> Runtime_toml.parse_toml toml
  | exception Otoml.Parse_error (_, message) ->
    Error [ { Runtime_toml.path = config_path; message } ]
;;

let registry_of_file config_path =
  match In_channel.with_open_bin config_path In_channel.input_all with
  | exception Sys_error message -> Error [ { Runtime_toml.path = config_path; message } ]
  | bytes ->
    (match Atomic.get last_registry_reading with
     | Some last
       when String.equal last.config_path config_path && String.equal last.bytes bytes ->
       last.parsed
     | Some _ | None ->
       let parsed = parse_registry ~config_path bytes in
       Atomic.set last_registry_reading (Some { config_path; bytes; parsed });
       parsed)
;;

let read_runtime_config ~base_path ~context =
  let* config_path =
    runtime_config_path ~base_path
    |> Option.to_result
         ~none:
           (Printf.sprintf
              "remote_ssh_runtime_config_missing: %s cannot be resolved because runtime.toml is unavailable"
              context)
  in
  registry_of_file config_path
    |> Result.map_error (fun errors ->
      let details =
        errors
        |> List.map Runtime_toml.show_parse_error
        |> String.concat "; "
      in
      Printf.sprintf
        "remote_ssh_runtime_config_invalid: %s: %s"
        context details)
;;

let configured_endpoints ~base_path =
  let* config = read_runtime_config ~base_path ~context:"endpoint catalog" in
  Ok config.Runtime_schema.exec_ssh_endpoints
;;

let resolve_endpoint_name ~base_path ~name:endpoint_name =
  let endpoint_name = String.trim endpoint_name in
  let* runtime_config =
    read_runtime_config ~base_path ~context:("endpoint " ^ endpoint_name)
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

let openssh_configuration ?ssh_bin ~base_path
    ~(endpoint : Exec_ssh_endpoint.t) () : Keeper_sandbox_remote.openssh =
  let ssh_bin =
    match ssh_bin with
    | Some path -> path
    | None -> Option.value (Atomic.get ssh_bin_override) ~default:"ssh"
  in
  { endpoint
  ; ssh_bin
  ; identity_file = resolve_path ~base_path endpoint.identity_file
  ; known_hosts_file = resolve_path ~base_path endpoint.known_hosts_file
  }
;;

let create ?ssh_bin ~base_path ~keeper_name
    ~(endpoint : Exec_ssh_endpoint.t) () =
  let* () =
    Exec_ssh_endpoint.validate_destination
      ~host:endpoint.host ~user:endpoint.user
  in
  let openssh = openssh_configuration ?ssh_bin ~base_path ~endpoint () in
  Ok
    (Keeper_sandbox_remote.of_openssh ~base_path ~keeper_name
       openssh)
;;

let sandbox_endpoint ~base_path ~workspace_root (endpoint : Exec_ssh_endpoint.t)
    : Masc_exec.Sandbox_target.ssh_endpoint =
  { name = endpoint.name
  ; host = endpoint.host
  ; user = endpoint.user
  ; port = endpoint.port
  ; identity_file = resolve_path ~base_path endpoint.identity_file
  ; known_hosts_file = resolve_path ~base_path endpoint.known_hosts_file
  ; remote_root = endpoint.remote_root
  ; workspace_root
  ; connect_timeout_sec = endpoint.connect_timeout_sec
  ; env_allowlist = endpoint.env_allowlist
  ; allowed_paths = endpoint.allowed_paths
  }
;;

module For_testing = struct
  let set_ssh_bin_override value = Atomic.set ssh_bin_override value
end
