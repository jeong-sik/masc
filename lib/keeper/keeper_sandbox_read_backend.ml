(** See .mli for contract.

    The current Docker invocation mirrors the hardened-Execute sandbox in
    [keeper_tool_command_runtime.ml] (read-only rootfs, no caps, no network) with the
    playground mounted read-only and the default read program reduced to a
    single [cat]. The argv assembly is duplicated rather than shared so a
    future surgical change to either path does not need to wade through the
    other's flags. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

let is_hardened = function
  | Docker -> true
  | Local -> false

let should_route_read ~(meta : keeper_meta) : bool =
  is_hardened meta.sandbox_profile

let strip_trailing_slashes = Env_config_core.strip_trailing_slashes

let host_playground_root ~config ~(meta : keeper_meta) =
  Keeper_sandbox.host_root_abs_of_meta ~config meta
  |> Keeper_alerting_path.normalize_path_for_check
  |> strip_trailing_slashes

let container_root ~(meta : keeper_meta) =
  Keeper_sandbox.container_root meta.name

let container_path_of_host ~config ~(meta : keeper_meta) ~host_path
    : (string, string) result =
  let host_root = host_playground_root ~config ~meta in
  let host_norm =
    Keeper_alerting_path.normalize_path_for_check host_path
    |> strip_trailing_slashes
  in
  let croot = container_root ~meta in
  if host_norm = host_root then Ok croot
  else if String.starts_with ~prefix:(host_root ^ "/") host_norm then
    let suffix =
      String.sub host_norm
        (String.length host_root + 1)
        (String.length host_norm - String.length host_root - 1)
    in
    Ok (Filename.concat croot suffix)
  else
    Error
      (Printf.sprintf
         "container_path_of_host: %s is not inside playground %s"
         host_norm host_root)

(* Argv prefix kept private — distinct from keeper_tool_command_runtime's bash
   argv to avoid coupling the two surfaces. The trailing
   [program ; arg1 ; ... ] is appended by the caller via
   [build_docker_argv ~command_argv]. *)
let build_docker_argv ~image ~container_name ~base_path ~host_root ~croot
    ~uid ~gid ~seccomp_args ~secret_args ~command_argv =
  Keeper_sandbox_runtime.docker_command_argv ()
  @ [
      "run";
      "--rm";
      "--name";
      container_name;
      "-i";
      "--user";
      Printf.sprintf "%d:%d" uid gid;
    ]
  @ Keeper_sandbox_runtime.docker_run_pull_never_args ()
  @ Keeper_sandbox_runtime.docker_sandbox_env_args
      ~base_path
      ~container_root:croot
  @ Keeper_sandbox_runtime.docker_nofile_args ()
  @ Env_config_sandbox.Hardening.read_only_rootfs_args ()
  @ [ "--tmpfs"
    ; Env_config_sandbox.Hardening.tmpfs_mount ()
    ; "--cap-drop=ALL"
    ; "--security-opt"
    ; "no-new-privileges"
  ]
  @ seccomp_args
  @ [
    "--pids-limit";
    string_of_int (Env_config_sandbox.Hardening.pids_limit ());
    "--memory"; Env_config_sandbox.Hardening.memory ();
    "-v"; host_root ^ ":" ^ croot ^ ":ro";
    "--workdir"; croot;
    "--network"; "none";
  ]
  @ Keeper_sandbox_runtime.docker_config_mount_args
      ~base_path
      ~container_root:croot
  @ Keeper_sandbox_runtime.docker_workspace_state_mount_args
      ~base_path
      ~container_root:croot
  @ secret_args
  @ [
    image;
  ]
  @ command_argv

let container_name_of meta =
  Printf.sprintf "masc-keeper-read-%s-%d-%d"
    (Workspace_utils.safe_filename meta.name)
    (Unix.getpid ())
    (int_of_float (Unix.gettimeofday () *. 1000.0))

let run_command_with_status ?turn_sandbox_factory
    ?(ok_exit_codes = [ 0 ])
    ~config ~(meta : keeper_meta)
    ~(command_argv : string list) ~(max_bytes : int)
    ~(timeout_sec : float) () : (Unix.process_status * string, string) result =
  let cwd = host_playground_root ~config ~meta in
  let resolve_result =
    Keeper_sandbox_factory.resolve_opt turn_sandbox_factory ~cwd
  in
  let image =
    match meta.sandbox_image with
    | Some img when String.trim img <> "" -> img
    | _ -> Env_config_sandbox.Runtime.docker_image ()
  in
  let no_runtime =
    match resolve_result with
    | Runtime _ -> false
    | No_factory | Local_profile -> true
  in
  if no_runtime && String.trim image = "" then
    Error "keeper sandbox docker image is not configured"
  else if command_argv = [] then
    Error "run_command_with_status: command_argv is empty"
  else
    let head_program =
      match command_argv with prog :: _ -> prog | [] -> "?"
    in
    match resolve_result with
    | Runtime runtime ->
      Keeper_turn_sandbox_runtime.run_command_with_status
        ~ok_exit_codes runtime ~timeout_sec ~cwd ~command_argv ~max_bytes ()
    | No_factory | Local_profile ->
      match Keeper_sandbox_runtime.ensure_keeper_sandbox_image_present ~image ~timeout_sec with
      | Error err ->
        let typed = Keeper_sandbox_error.Image_not_found { image } in
        Error
          (Printf.sprintf
             "docker_%s_failed: %s: %s"
             head_program
             (Keeper_sandbox_error.to_string typed)
             err)
      | Ok () ->
      match Keeper_sandbox_runtime.ensure_keeper_sandbox_runtime ~timeout_sec with
      | Error err -> Error err
      | Ok seccomp_args ->
        let host_root = host_playground_root ~config ~meta in
        let croot = container_root ~meta in
        let container_name = container_name_of meta in
        let uid = Unix.getuid () in
        let gid = Unix.getgid () in
        match
          Keeper_secret_projection.docker_args_for_keeper
            ~base_path:config.base_path
            ~keeper_name:meta.name
            ~container_name
            ()
        with
        | Error err -> Error ("docker_read_failed: secret_projection: " ^ err)
        | Ok secret_projection ->
        let argv =
          build_docker_argv
            ~image
            ~container_name
            ~base_path:config.base_path
            ~host_root
            ~croot
            ~uid
            ~gid
            ~seccomp_args
            ~secret_args:secret_projection.docker_args
            ~command_argv
        in
        let st, out =
          Eio_guard.protect
            ~finally:secret_projection.cleanup
            (fun () ->
               Fd_accountant.observe ~kind:Fd_accountant.Docker_spawn (fun () ->
                 Masc_exec.Exec_gate.run_argv_with_status
                   ~actor:(Masc_exec.Agent_id.of_string "system/sandbox")
                   ~raw_source:(String.concat " " argv)
                   ~summary:"keeper docker read sandboxed command"
                   ~env:(Env_keeper_scrub.filter_environment (Unix.environment ()))
                   ~cwd:(Config_dir_resolver.current_working_dir ())
                   ~timeout_sec
                   argv))
        in
        (match st with
         | Unix.WEXITED code
           when List.exists (fun ok_code -> ok_code = code) ok_exit_codes ->
           let body =
             if String.length out > max_bytes then String.sub out 0 max_bytes
             else out
           in
           Ok (st, body)
         | Unix.WEXITED code ->
           Error
             (Printf.sprintf
                "docker_%s_failed: exit=%d output=%s"
                head_program code
                (Exec_policy.truncate_for_log out))
         | Unix.WSIGNALED n ->
           Error
             (Printf.sprintf "docker_%s_signaled: signal=%d" head_program n)
         | Unix.WSTOPPED n ->
           Error
             (Printf.sprintf "docker_%s_stopped: signal=%d" head_program n))

let run_command ?turn_sandbox_factory ?(ok_exit_codes = [ 0 ]) ~config ~meta
    ~command_argv ~max_bytes ~timeout_sec () =
  match
    run_command_with_status ?turn_sandbox_factory
      ~ok_exit_codes ~config ~meta
      ~command_argv ~max_bytes ~timeout_sec ()
  with
  | Error _ as err -> err
  | Ok (_st, out) -> Ok out

let read_file ?turn_sandbox_factory ~config ~(meta : keeper_meta) ~host_path
    ~(max_bytes : int) ~(timeout_sec : float) () : (string, string) result =
  match container_path_of_host ~config ~meta ~host_path with
  | Error _ as e -> e
  | Ok container_path ->
    (* Pre-flight: verify the host path exists before spawning a container.
       This avoids wasteful docker runs that inevitably fail with
       "No such file or directory", and lets us emit a precise error
       that names the host path the keeper actually asked for. *)
    if not (Sys.file_exists host_path) then
      Error
        (Printf.sprintf
           "docker_cat_failed: path_not_found: %s (host path does not exist; verify the \
            relative path under your playground before calling Read)"
           host_path)
    else if Sys.is_directory host_path then
      Error
        (Printf.sprintf
           "docker_cat_failed: path_is_directory: %s (Read requires a file, \
            not a directory; to list a directory use Execute with ls, e.g. \
            executable='ls' argv=['-la','%s'])"
           host_path
           host_path)
    else
      run_command ?turn_sandbox_factory ~config ~meta
        ~command_argv:[ "cat"; container_path ]
        ~max_bytes ~timeout_sec ()
