(** See .mli for contract.

    The docker invocation mirrors the hardened-keeper bash sandbox in
    [keeper_exec_shell.ml] (read-only rootfs, no caps, no network)
    with the playground mounted read-only and the program reduced to
    a single [cat]. The argv assembly is duplicated rather than
    shared so a future surgical change to either path does not need
    to wade through the other's flags. *)

open Keeper_types

let is_hardened = function
  | Docker_hardened | Docker_with_git -> true
  | Legacy_local -> false

let should_route_read ~(meta : keeper_meta) : bool =
  is_hardened meta.sandbox_profile
  && Env_config_keeper.KeeperSandbox.symmetric_read_containment ()
  && Env_config_keeper.KeeperSandbox.docker_read_routing ()

let strip_trailing_slashes path =
  let rec loop i =
    if i > 0 && path.[i - 1] = '/' then loop (i - 1) else i
  in
  let len = loop (String.length path) in
  if len = String.length path then path else String.sub path 0 len

let host_playground_root ~config ~(meta : keeper_meta) =
  Filename.concat
    (Keeper_alerting_path.project_root_of_config config)
    (Keeper_alerting_path.playground_path_of_keeper meta.name)
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

(* Argv builder kept private — distinct from keeper_exec_shell's
   bash argv to avoid coupling the two surfaces. *)
let build_docker_argv ~image ~container_name ~host_root ~croot
    ~container_path ~uid ~gid ~seccomp_args =
  [
    "docker";
    "run";
    "--rm";
    "--name"; container_name;
    "-i";
    "--user"; Printf.sprintf "%d:%d" uid gid;
    "--read-only";
    "--tmpfs";
    Printf.sprintf "/tmp:rw,nosuid,nodev,noexec,size=%s"
      (Env_config_keeper.KeeperSandbox.tmpfs_size ());
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
    "cat"; container_path;
  ]

let container_name_of meta =
  Printf.sprintf "masc-keeper-read-%s-%d-%d"
    (Coord_utils.safe_filename meta.name)
    (Unix.getpid ())
    (int_of_float (Unix.gettimeofday () *. 1000.0))

let read_file_in_container ~config ~(meta : keeper_meta) ~host_path
    ~(max_bytes : int) ~(timeout_sec : float) () : (string, string) result =
  let image = Env_config_keeper.KeeperSandbox.docker_image () in
  if String.trim image = "" then
    Error "keeper sandbox docker image is not configured"
  else
    match container_path_of_host ~config ~meta ~host_path with
    | Error _ as e -> e
    | Ok container_path ->
      match
        Keeper_exec_shell.ensure_keeper_sandbox_runtime ~timeout_sec
      with
      | Error err -> Error err
      | Ok seccomp_args ->
        let host_root = host_playground_root ~config ~meta in
        let croot = container_root ~meta in
        let container_name = container_name_of meta in
        let uid = Unix.getuid () in
        let gid = Unix.getgid () in
        let argv =
          build_docker_argv ~image ~container_name ~host_root ~croot
            ~container_path ~uid ~gid ~seccomp_args
        in
        let st, out =
          Process_eio.run_argv_with_status
            ~cwd:(Sys.getcwd ()) ~timeout_sec argv
        in
        match st with
        | Unix.WEXITED 0 ->
          let body =
            if String.length out > max_bytes then String.sub out 0 max_bytes
            else out
          in
          Ok body
        | Unix.WEXITED code ->
          Error
            (Printf.sprintf
               "docker_read_failed: exit=%d output=%s"
               code
               (Worker_dev_tools.truncate_for_log out))
        | Unix.WSIGNALED n ->
          Error (Printf.sprintf "docker_read_signaled: signal=%d" n)
        | Unix.WSTOPPED n ->
          Error (Printf.sprintf "docker_read_stopped: signal=%d" n)
