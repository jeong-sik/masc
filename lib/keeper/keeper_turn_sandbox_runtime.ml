open Keeper_types

type state =
  | Not_started
  | Running of { container_name : string }

type t =
  {
    config : Coord.config;
    meta : keeper_meta;
    host_root : string;
    container_root : string;
    uid : int;
    gid : int;
    network_mode : network_mode;
    mutable state : state;
  }

let strip_trailing_slashes path =
  let rec loop i =
    if i > 0 && path.[i - 1] = '/' then loop (i - 1) else i
  in
  let len = loop (String.length path) in
  if len = String.length path then path else String.sub path 0 len

let normalize_path path =
  Keeper_alerting_path.normalize_path_for_check path
  |> strip_trailing_slashes

let create ~(config : Coord.config) ~(meta : keeper_meta)
    ?(network_mode = Network_none) () =
  let network_mode =
    if Env_config_keeper.KeeperSandbox.hard_mode () then
      Network_none
    else
      network_mode
  in
  {
    config;
    meta;
    host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta |> normalize_path;
    container_root = Keeper_sandbox.container_root meta.name |> strip_trailing_slashes;
    uid = Unix.getuid ();
    gid = Unix.getgid ();
    network_mode;
    state = Not_started;
  }

let container_name_of (t : t) =
  let net_suffix =
    match t.network_mode with
    | Network_none -> "none"
    | Network_inherit -> "inherit"
  in
  Printf.sprintf "masc-keeper-turn-%s-%s-%d-%d"
    (Coord_utils.safe_filename t.meta.name)
    net_suffix
    (Unix.getpid ())
    (int_of_float (Unix.gettimeofday () *. 1000.0))

let container_path_of_host (t : t) ~host_path =
  let host_norm = normalize_path host_path in
  if host_norm = t.host_root then Ok t.container_root
  else if String.starts_with ~prefix:(t.host_root ^ "/") host_norm then
    let suffix =
      String.sub host_norm
        (String.length t.host_root + 1)
        (String.length host_norm - String.length t.host_root - 1)
    in
    Ok (Filename.concat t.container_root suffix)
  else
    Error
      (Printf.sprintf
         "container_path_of_host: %s is not inside playground %s"
         host_norm t.host_root)

let container_cwd_of_host (t : t) ~host_cwd =
  match container_path_of_host t ~host_path:host_cwd with
  | Ok container_cwd -> container_cwd
  | Error _ -> t.container_root

let format_docker_exec_error ~head_program ~st ~out =
  match st with
  | Unix.WEXITED code ->
      Printf.sprintf "docker_%s_failed: exit=%d output=%s"
        head_program code
        (Worker_dev_tools.truncate_for_log out)
  | Unix.WSIGNALED n ->
      Printf.sprintf "docker_%s_signaled: signal=%d" head_program n
  | Unix.WSTOPPED n ->
      Printf.sprintf "docker_%s_stopped: signal=%d" head_program n

let container_missing_error out =
  String_util.contains_substring_ci out "no such container"
  || String_util.contains_substring_ci out "is not running"

let run_argv_with_status_retry_eintr ~timeout_sec argv =
  let max_eintr_retries = 8 in
  let rec loop attempts_left =
    let st, out =
      Process_eio.run_argv_with_status
        ~env:(Unix.environment ())
        ~cwd:(Sys.getcwd ()) ~timeout_sec argv
    in
    match st with
    | Unix.WEXITED 127
      when attempts_left > 0
           && String_util.contains_substring_ci out "interrupted system call" ->
        loop (attempts_left - 1)
    | _ -> st, out
  in
  loop max_eintr_retries

let run_argv_with_stdin_and_status_retry_eintr ~timeout_sec ~stdin_content argv =
  let max_eintr_retries = 8 in
  let rec loop attempts_left =
    let st, out =
      Process_eio.run_argv_with_stdin_and_status
        ~env:(Unix.environment ())
        ~cwd:(Sys.getcwd ()) ~timeout_sec ~stdin_content argv
    in
    match st with
    | Unix.WEXITED 127
      when attempts_left > 0
           && String_util.contains_substring_ci out "interrupted system call" ->
        loop (attempts_left - 1)
    | _ -> st, out
  in
  loop max_eintr_retries

let start_container (t : t) ~(timeout_sec : float) =
  let image =
    match t.meta.sandbox_image with
    | Some img when String.trim img <> "" -> img
    | _ -> Env_config_keeper.KeeperSandbox.docker_image ()
  in
  if String.trim image = "" then
    Error "keeper sandbox docker image is not configured"
  else
    let _cleanup =
      Keeper_sandbox_runtime.maybe_cleanup_stale_containers
        ~base_path:t.config.base_path
        ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Turn_sandbox ())
        ()
    in
    match Keeper_sandbox_runtime.ensure_keeper_sandbox_runtime ~timeout_sec with
    | Error _ as err -> err
    | Ok seccomp_args ->
        let container_name = container_name_of t in
        let network_args, network_label =
          Keeper_sandbox_runtime.docker_network_args t.network_mode
        in
        match
          Keeper_sandbox_runtime.docker_user_identity_mount_args
            ~host_root:t.host_root ~uid:t.uid ~gid:t.gid
        with
        | Error _ as err -> err
        | Ok identity_mounts ->
        let argv =
          Keeper_sandbox_runtime.docker_command_argv ()
          @ [
              "run";
              "-d";
              "--rm";
              "--name";
              container_name;
            ]
          @ Keeper_sandbox_runtime.docker_label_args
              ~base_path:t.config.base_path
              ~keeper_name:t.meta.name
              ~container_kind:"turn"
              ~network_label ()
          @ [
            "--user";
            Printf.sprintf "%d:%d" t.uid t.gid;
          ]
          @ Keeper_sandbox_runtime.docker_user_env_args ()
          @ Keeper_sandbox_runtime.docker_nofile_args ()
          @ Env_config_keeper.KeeperSandbox.read_only_rootfs_args ()
          @ [
            "--tmpfs";
            Env_config_keeper.KeeperSandbox.tmpfs_mount ();
            "--cap-drop=ALL";
            "--security-opt";
            "no-new-privileges";
          ]
          @ seccomp_args
          @ [
              "--pids-limit";
              string_of_int (Env_config_keeper.KeeperSandbox.pids_limit ());
              "--memory";
              Env_config_keeper.KeeperSandbox.memory ();
              "-v";
              t.host_root ^ ":" ^ t.container_root ^ ":rw";
              "--workdir";
              t.container_root;
            ]
          @ identity_mounts
          @ network_args
          @ [
              image;
              "sh";
              "-lc";
              "trap : TERM INT; while :; do sleep 3600; done";
            ]
        in
        let st, out = run_argv_with_status_retry_eintr ~timeout_sec argv in
        match st with
        | Unix.WEXITED 0 ->
            t.state <- Running { container_name };
            Ok container_name
        | _ ->
            Error
              (Printf.sprintf "docker_container_start_failed: %s"
                 (Worker_dev_tools.truncate_for_log out))

let ensure_started (t : t) ~(timeout_sec : float) =
  match t.state with
  | Running { container_name } -> Ok container_name
  | Not_started -> start_container t ~timeout_sec

let run_exec_with_status_once
    ?(stdin_content : string option)
    (t : t)
    ~(timeout_sec : float)
    ~(cwd : string)
    ~(command_argv : string list) =
  match ensure_started t ~timeout_sec with
  | Error _ as err -> err
  | Ok container_name ->
      let container_cwd = container_cwd_of_host t ~host_cwd:cwd in
      let argv =
        Keeper_sandbox_runtime.docker_command_argv ()
        @ [
            "exec";
            "--user";
            Printf.sprintf "%d:%d" t.uid t.gid;
            "-w";
            container_cwd;
          ]
        @ Keeper_sandbox_runtime.docker_user_env_args ()
        @ (match stdin_content with Some _ -> [ "-i" ] | None -> [])
        @ (container_name :: command_argv)
      in
      let st, out =
        match stdin_content with
        | Some content ->
            run_argv_with_stdin_and_status_retry_eintr
              ~timeout_sec ~stdin_content:content argv
        | None -> run_argv_with_status_retry_eintr ~timeout_sec argv
      in
      Ok (st, out)

let run_exec_with_status
    ?stdin_content
    (t : t)
    ~(timeout_sec : float)
    ~(cwd : string)
    ~(command_argv : string list) =
  match run_exec_with_status_once ?stdin_content t ~timeout_sec ~cwd ~command_argv with
  | Error _ as err -> err
  | Ok ((Unix.WEXITED 126 | Unix.WEXITED 127), out)
    when container_missing_error out ->
      t.state <- Not_started;
      (match run_exec_with_status_once ?stdin_content t ~timeout_sec ~cwd ~command_argv with
       | Ok _ as ok -> ok
       | Error _ as err -> err)
  | Ok other -> Ok other

let run_command_with_status ?(ok_exit_codes = [ 0 ]) (t : t)
    ~(cwd : string) ~(command_argv : string list)
    ~(max_bytes : int) ~(timeout_sec : float) () =
  match command_argv with
  | [] -> Error "run_command_with_status: command_argv is empty"
  | head_program :: _ ->
      (match run_exec_with_status t ~timeout_sec ~cwd ~command_argv with
       | Error _ as err -> err
       | Ok (st, out) ->
           (match st with
            | Unix.WEXITED code
              when List.exists (fun ok_code -> ok_code = code) ok_exit_codes ->
                let body =
                  if String.length out > max_bytes then String.sub out 0 max_bytes
                  else out
                in
                Ok (st, body)
            | _ -> Error (format_docker_exec_error ~head_program ~st ~out)))

let run_command ?(ok_exit_codes = [ 0 ]) t ~cwd ~command_argv
    ~max_bytes ~timeout_sec () =
  match
    run_command_with_status ~ok_exit_codes t ~cwd ~command_argv
      ~max_bytes ~timeout_sec ()
  with
  | Ok (_st, out) -> Ok out
  | Error _ as err -> err

let run_bash_with_status (t : t) ~(cwd : string) ~(cmd : string)
    ~(timeout_sec : float) () =
  let cmd =
    Keeper_sandbox_runtime.rewrite_host_root_to_container_root
      ~host_root:t.host_root ~container_root:t.container_root cmd
  in
  run_exec_with_status t ~timeout_sec ~cwd
    ~command_argv:[ "bash"; "-lc"; cmd ^ " 2>&1" ]

let write_file_common (t : t) ~(host_path : string) ~(content : string)
    ~(timeout_sec : float) ~(append : bool) () =
  match container_path_of_host t ~host_path with
  | Error _ as err -> err
  | Ok container_path ->
      let parent = Filename.dirname container_path in
      let redirect = if append then ">>" else ">" in
      let shell_cmd =
        Printf.sprintf "mkdir -p -- %s && cat %s %s"
          (Filename.quote parent)
          redirect
          (Filename.quote container_path)
      in
      match
        run_exec_with_status ~stdin_content:content t ~timeout_sec
          ~cwd:t.host_root
          ~command_argv:[ "sh"; "-lc"; shell_cmd ]
      with
      | Error _ as err -> err
      | Ok (Unix.WEXITED 0, _out) -> Ok ()
      | Ok (st, out) ->
          Error (format_docker_exec_error ~head_program:"write_file" ~st ~out)

let overwrite_file t ~host_path ~content ~timeout_sec () =
  write_file_common t ~host_path ~content ~timeout_sec ~append:false ()

let append_file t ~host_path ~content ~timeout_sec () =
  write_file_common t ~host_path ~content ~timeout_sec ~append:true ()

let cleanup (t : t) =
  match t.state with
  | Not_started -> ()
  | Running { container_name } ->
      t.state <- Not_started;
      let argv =
        Keeper_sandbox_runtime.docker_command_argv ()
        @ [ "rm"; "-f"; container_name ]
      in
      let _st, _out =
        run_argv_with_status_retry_eintr
          ~timeout_sec:(Env_config_sandbox.Shell_timeout.timeout_sec
                          ~bucket:Cleanup_rm ())
          argv
      in
      ()
