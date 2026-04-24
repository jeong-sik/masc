(** Operator-facing keeper sandbox control.

    This module keeps Docker lifecycle operations scoped to MASC keeper labels
    and the active base path.  It deliberately manages only containers with
    [container_kind=managed]; turn/oneshot containers remain owned by their
    existing execution paths and stale cleanup. *)

open Keeper_types

let managed_kind = "managed"

let now_ms () =
  int_of_float (Unix.gettimeofday () *. 1000.0)

let normalize_path path =
  Keeper_alerting_path.normalize_path_for_check path
  |> Keeper_alerting_path.strip_trailing_slashes

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" then
    ()
  else if Sys.file_exists path then
    ()
  else (
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    Unix.mkdir path 0o755)

let managed_container_name ~(meta : keeper_meta) ~(network_label : string) =
  Printf.sprintf "masc-keeper-managed-%s-%s-%d-%d"
    (Coord_utils.safe_filename meta.name)
    (Coord_utils.safe_filename network_label)
    (Unix.getpid ())
    (now_ms ())

let configured_effective_network network_mode =
  if Env_config_keeper.KeeperSandbox.hard_mode () then
    Network_none
  else
    network_mode

let live_containers ~config ~meta ~timeout_sec =
  Keeper_sandbox_runtime.list_containers
    ~keeper_name:meta.name
    ~base_path:config.Coord.base_path
    ~timeout_sec
    ()

let running_managed_container ~network_label containers =
  List.find_opt
    (fun (c : Keeper_sandbox_runtime.live_container) ->
      c.container_kind = Some managed_kind
      && c.running = Some true
      && c.network_label = Some network_label)
    containers

let start_managed_container
    ~(config : Coord.config)
    ~(meta : keeper_meta)
    ~(network_mode : network_mode)
    ~(ttl_sec : float)
    ~(timeout_sec : float)
    () =
  if meta.sandbox_profile <> Docker then
    Error "keeper sandbox start requires sandbox_profile=docker"
  else
    let network_mode = configured_effective_network network_mode in
    let network_args, network_label =
      Keeper_sandbox_runtime.docker_network_args network_mode
    in
    match live_containers ~config ~meta ~timeout_sec:2.0 with
    | Ok containers -> (
        match running_managed_container ~network_label containers with
        | Some container ->
            Ok
              (`Assoc
                 [
                   ("started", `Bool false);
                   ("already_running", `Bool true);
                   ("container",
                    Keeper_sandbox_runtime.live_container_to_yojson container);
                 ])
        | None ->
            let image = Env_config_keeper.KeeperSandbox.docker_image () in
            if String.trim image = "" then
              Error "keeper sandbox docker image is not configured"
            else
              let _cleanup =
                Keeper_sandbox_runtime.maybe_cleanup_stale_containers
                  ~base_path:config.base_path ~timeout_sec:2.0 ()
              in
              match
                Keeper_sandbox_runtime.ensure_keeper_sandbox_runtime
                  ~timeout_sec
              with
              | Error _ as err -> err
              | Ok seccomp_args ->
                  let host_root =
                    Keeper_sandbox.host_root_abs_of_meta ~config meta
                    |> normalize_path
                  in
                  ensure_dir host_root;
                  let container_root =
                    Keeper_sandbox.container_root meta.name
                    |> Keeper_alerting_path.strip_trailing_slashes
                  in
                  let uid = Unix.getuid () in
                  let gid = Unix.getgid () in
                  let container_name =
                    managed_container_name ~meta ~network_label
                  in
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
                        ~ttl_sec
                        ~base_path:config.base_path
                        ~keeper_name:meta.name
                        ~container_kind:managed_kind
                        ~network_label ()
                    @ [
                      "--user";
                      Printf.sprintf "%d:%d" uid gid;
                    ]
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
                      string_of_int
                        (Env_config_keeper.KeeperSandbox.pids_limit ());
                      "--memory";
                      Env_config_keeper.KeeperSandbox.memory ();
                      "-v";
                      host_root ^ ":" ^ container_root ^ ":rw";
                      "--workdir";
                      container_root;
                    ]
                    @ network_args
                    @ [
                      image;
                      "sh";
                      "-lc";
                      "trap : TERM INT; while :; do sleep 3600; done";
                    ]
                  in
                  let st, out =
                    Process_eio.run_argv_with_status
                      ~env:(Unix.environment ())
                      ~cwd:(Sys.getcwd ())
                      ~timeout_sec
                      argv
                  in
                  if st = Unix.WEXITED 0 then (
                    Keeper_registry.clear_error
                      ~base_path:config.base_path meta.name;
                    Ok
                      (`Assoc
                         [
                           ("started", `Bool true);
                           ("already_running", `Bool false);
                           ("container_id", `String (String.trim out));
                           ("container_name", `String container_name);
                           ("container_kind", `String managed_kind);
                           ("network_label", `String network_label);
                           ("ttl_sec", `Float ttl_sec);
                           ("image", `String image);
                         ]))
                  else (
                    let message =
                      Printf.sprintf "docker_managed_container_start_failed: %s"
                        (Worker_dev_tools.truncate_for_log out)
                    in
                    Keeper_registry.record_error
                      ~base_path:config.base_path meta.name message;
                    Error message))
    | Error err -> Error err

let stop_managed_containers ?keeper_name ~(config : Coord.config)
    ~(timeout_sec : float) () =
  Keeper_sandbox_runtime.stop_containers
    ?keeper_name
    ~container_kind:managed_kind
    ~base_path:config.base_path
    ~timeout_sec
    ()

let cleanup_stale ~(config : Coord.config) ~(timeout_sec : float) () =
  Keeper_sandbox_runtime.cleanup_stale_containers
    ~base_path:config.base_path
    ~timeout_sec
    ()

let json_string_list values =
  `List (List.map (fun value -> `String value) values)

let preflight_status_json ~timeout_sec =
  Keeper_sandbox_runtime.docker_preflight ~timeout_sec ()
  |> Option.map Keeper_sandbox_runtime.docker_preflight_to_yojson

let preflight_ok = function
  | Some (`Assoc fields) -> (
      match List.assoc_opt "ok" fields with
      | Some (`Bool value) -> Some value
      | _ -> None)
  | _ -> None

let container_mode (meta : keeper_meta) containers =
  if meta.sandbox_profile = Local then
    "local"
  else if
    List.exists
      (fun (c : Keeper_sandbox_runtime.live_container) ->
        c.container_kind = Some managed_kind && c.running = Some true)
      containers
  then
    "managed_running"
  else
    match meta.network_mode with
    | Network_none -> "turn_scoped_or_managed_none"
    | Network_inherit -> "oneshot_or_managed_inherit"

let why_no_container (meta : keeper_meta) ~preflight containers =
  if meta.sandbox_profile = Local then
    Some "sandbox_profile=local"
  else if containers <> [] then
    None
  else
    match preflight_ok preflight with
    | Some false -> Some "docker_preflight_failed"
    | _ -> (
        match meta.network_mode with
        | Network_inherit ->
            Some
              "network_mode=inherit uses one-shot Docker containers unless a managed sandbox is explicitly started"
        | Network_none ->
            Some
              "no active turn or managed sandbox container; Docker containers start on sandboxed tool calls or via masc_keeper_sandbox_start")

let recommendation (meta : keeper_meta) ~preflight containers =
  if meta.sandbox_profile = Local then
    Some "No Docker container is expected for sandbox_profile=local."
  else if containers <> [] then
    None
  else
    match preflight_ok preflight with
    | Some false ->
        Some
          "Fix Docker preflight first, then rerun masc_keeper_sandbox_status."
    | _ ->
        Some
          (Printf.sprintf
             "Run masc_keeper_sandbox_start with name=%S to prewarm a visible managed container."
             meta.name)

let identity_json (meta : keeper_meta) =
  let expected_agent_name = Keeper_types.keeper_agent_name meta.name in
  let agent_name_matches = String.equal expected_agent_name meta.agent_name in
  `Assoc
    [
      ("agent_name", `String meta.agent_name);
      ("expected_agent_name", `String expected_agent_name);
      ("agent_name_matches", `Bool agent_name_matches);
      ("trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
      ( "warnings",
        if agent_name_matches then
          `List []
        else
          `List
            [
              `String
                "keeper agent_name does not match the canonical keeper name; repair or recreate this keeper trace before relying on scheduling evidence";
            ] );
    ]

let live_status_json ?(include_preflight = true)
    ~(config : Coord.config)
    ~(meta : keeper_meta)
    ~(timeout_sec : float)
    ~(verbose : bool)
    () =
  let preflight =
    if include_preflight && meta.sandbox_profile = Docker then
      preflight_status_json ~timeout_sec
    else
      None
  in
  let containers, container_error =
    if meta.sandbox_profile = Docker then
      match live_containers ~config ~meta ~timeout_sec with
      | Ok containers -> (containers, None)
      | Error err -> ([], Some err)
    else
      ([], None)
  in
  let why_no_container =
    match container_error with
    | Some _ -> Some "docker_container_listing_failed"
    | None -> why_no_container meta ~preflight containers
  in
  let recommendation =
    match container_error with
    | Some _ ->
        Some "Check Docker daemon availability and retry sandbox status."
    | None -> recommendation meta ~preflight containers
  in
  `Assoc
    [
      ("keeper", `String meta.name);
      ("sandbox_profile", `String (sandbox_profile_to_string meta.sandbox_profile));
      ("configured_network_mode", `String (network_mode_to_string meta.network_mode));
      ("effective_mode", `String (container_mode meta containers));
      ("managed_container_kind", `String managed_kind);
      ("container_count", `Int (List.length containers));
      ("containers",
       `List (List.map Keeper_sandbox_runtime.live_container_to_yojson containers));
      ( "preflight",
        if verbose then Json_util.option_to_yojson Fun.id preflight else `Null );
      ("container_error", Json_util.string_opt_to_json container_error);
      ("why_no_container", Json_util.string_opt_to_json why_no_container);
      ("recommendation", Json_util.string_opt_to_json recommendation);
      ("identity", identity_json meta);
    ]
