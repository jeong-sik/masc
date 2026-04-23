(** See .mli for contract.

    The docker invocation mirrors the hardened-keeper bash sandbox in
    [keeper_exec_shell.ml] (read-only rootfs, no caps, no network)
    with the playground mounted read-only and the program reduced to
    a single [cat]. The argv assembly is duplicated rather than
    shared so a future surgical change to either path does not need
    to wade through the other's flags. *)

open Keeper_types

let is_hardened = function
  | Docker -> true
  | Local -> false

let should_route_read ~(meta : keeper_meta) : bool =
  is_hardened meta.sandbox_profile

let strip_trailing_slashes path =
  let rec loop i =
    if i > 0 && path.[i - 1] = '/' then loop (i - 1) else i
  in
  let len = loop (String.length path) in
  if len = String.length path then path else String.sub path 0 len

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

(* Argv prefix kept private — distinct from keeper_exec_shell's bash
   argv to avoid coupling the two surfaces. The trailing
   [program ; arg1 ; ... ] is appended by the caller via
   [build_docker_argv ~command_argv]. *)
let build_docker_argv ~image ~container_name ~host_root ~croot
    ~uid ~gid ~seccomp_args ~command_argv =
  [
    Keeper_sandbox_runtime.docker_command ();
    "run";
    "--rm";
    "--name"; container_name;
    "-i";
    "--user"; Printf.sprintf "%d:%d" uid gid;
  ]
  @ Env_config_keeper.KeeperSandbox.read_only_rootfs_args ()
  @ [
    "--tmpfs";
    Env_config_keeper.KeeperSandbox.tmpfs_mount ();
    "--cap-drop=ALL";
    "--security-opt"; "no-new-privileges";
  ]
  @ seccomp_args
  @ [
    "--pids-limit";
    string_of_int (Env_config_keeper.KeeperSandbox.pids_limit ());
    "--memory"; Env_config_keeper.KeeperSandbox.memory ();
    "-v"; host_root ^ ":" ^ croot ^ ":ro";
    "--workdir"; croot;
    "--network"; "none";
    image;
  ]
  @ command_argv

let container_name_of meta =
  Printf.sprintf "masc-keeper-read-%s-%d-%d"
    (Coord_utils.safe_filename meta.name)
    (Unix.getpid ())
    (int_of_float (Unix.gettimeofday () *. 1000.0))

let run_command_in_container_with_status ?turn_sandbox_runtime
    ?(ok_exit_codes = [ 0 ])
    ~config ~(meta : keeper_meta)
    ~(command_argv : string list) ~(max_bytes : int)
    ~(timeout_sec : float) () : (Unix.process_status * string, string) result =
  let image = Env_config_keeper.KeeperSandbox.docker_image () in
  if Option.is_none turn_sandbox_runtime && String.trim image = "" then
    Error "keeper sandbox docker image is not configured"
  else if command_argv = [] then
    Error "run_command_in_container_with_status: command_argv is empty"
  else
    match turn_sandbox_runtime with
    | Some runtime ->
      let cwd = host_playground_root ~config ~meta in
      Keeper_turn_sandbox_runtime.run_command_with_status
        ~ok_exit_codes runtime ~cwd ~command_argv ~max_bytes ~timeout_sec ()
    | None ->
      match Keeper_sandbox_runtime.ensure_keeper_sandbox_runtime ~timeout_sec with
      | Error err -> Error err
      | Ok seccomp_args ->
        let host_root = host_playground_root ~config ~meta in
        let croot = container_root ~meta in
        let container_name = container_name_of meta in
        let uid = Unix.getuid () in
        let gid = Unix.getgid () in
        let argv =
          build_docker_argv ~image ~container_name ~host_root ~croot
            ~uid ~gid ~seccomp_args ~command_argv
        in
        let st, out =
          Process_eio.run_argv_with_status
            ~env:(Unix.environment ())
            ~cwd:(Sys.getcwd ()) ~timeout_sec argv
        in
        let head_program =
          match command_argv with prog :: _ -> prog | [] -> "?"
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
                (Worker_dev_tools.truncate_for_log out))
         | Unix.WSIGNALED n ->
           Error
             (Printf.sprintf "docker_%s_signaled: signal=%d" head_program n)
         | Unix.WSTOPPED n ->
           Error
             (Printf.sprintf "docker_%s_stopped: signal=%d" head_program n))

let run_command_in_container ?turn_sandbox_runtime ?(ok_exit_codes = [ 0 ]) ~config ~meta
    ~command_argv ~max_bytes ~timeout_sec () =
  match
    run_command_in_container_with_status ?turn_sandbox_runtime
      ~ok_exit_codes ~config ~meta
      ~command_argv ~max_bytes ~timeout_sec ()
  with
  | Error _ as err -> err
  | Ok (_st, out) -> Ok out

let read_file_in_container ?turn_sandbox_runtime ~config ~(meta : keeper_meta) ~host_path
    ~(max_bytes : int) ~(timeout_sec : float) () : (string, string) result =
  match container_path_of_host ~config ~meta ~host_path with
  | Error _ as e -> e
  | Ok container_path ->
    run_command_in_container ?turn_sandbox_runtime ~config ~meta
      ~command_argv:[ "cat"; container_path ]
      ~max_bytes ~timeout_sec ()
