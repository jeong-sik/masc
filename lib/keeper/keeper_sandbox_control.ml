(** Operator-facing keeper sandbox control.

    This module keeps Docker lifecycle operations scoped to MASC keeper labels
    and the active base path.  Start operations deliberately manage only
    [container_kind=managed]; stop operations default to that same safe scope,
    but can target [turn] or [all] when an operator needs to clear abandoned
    turn containers before TTL cleanup. *)

open Keeper_types

let managed_kind = "managed"
let turn_kind = "turn"
let all_kind = "all"

type stop_scope =
  | Stop_managed
  | Stop_turn
  | Stop_all

let stop_scope_to_string = function
  | Stop_managed -> managed_kind
  | Stop_turn -> turn_kind
  | Stop_all -> all_kind

let parse_stop_scope raw =
  match String.lowercase_ascii (String.trim raw) with
  | "" -> Ok Stop_managed
  | kind when String.equal kind managed_kind -> Ok Stop_managed
  | kind when String.equal kind turn_kind -> Ok Stop_turn
  | kind when String.equal kind all_kind -> Ok Stop_all
  | other ->
      Error
        (Printf.sprintf
           "invalid container_kind %S; expected managed, turn, or all"
           other)

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
    let probe_timeout =
      Env_config_exec_timeout.timeout_sec ~caller:Sandbox ()
    in
    match live_containers ~config ~meta ~timeout_sec:probe_timeout with
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
            let image =
              match meta.sandbox_image with
              | Some img when String.trim img <> "" -> img
              | _ -> Env_config_keeper.KeeperSandbox.docker_image ()
            in
            if String.trim image = "" then
              Error "keeper sandbox docker image is not configured"
            else
              let _cleanup =
                Keeper_sandbox_runtime.maybe_cleanup_stale_containers
                  ~base_path:config.base_path
                  ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Sandbox ())
                  ()
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
                      "--env";
                      "HOME=/tmp";
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
                      Printf.sprintf
                        "trap : TERM INT; while :; do sleep %d; done"
                        (Env_config_sandbox.Cleanup.managed_sleep_sec ());
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

let stop_containers ?keeper_name ~scope ~(config : Coord.config)
    ~(timeout_sec : float) () =
  let container_kind =
    match scope with
    | Stop_managed -> Some managed_kind
    | Stop_turn -> Some turn_kind
    | Stop_all -> None
  in
  Keeper_sandbox_runtime.stop_containers
    ?keeper_name
    ?container_kind
    ~base_path:config.base_path
    ~timeout_sec
    ()

let stop_managed_containers ?keeper_name ~(config : Coord.config)
    ~(timeout_sec : float) () =
  stop_containers ?keeper_name ~scope:Stop_managed ~config ~timeout_sec ()

let cleanup_stale ~(config : Coord.config) ~(timeout_sec : float) () =
  Keeper_sandbox_runtime.cleanup_stale_containers
    ~base_path:config.base_path
    ~timeout_sec
    ()

let json_string_list values =
  `List (List.map (fun value -> `String value) values)

let safe_file_exists path =
  try Fs_compat.file_exists path with
  | Sys_error _ -> false

let safe_is_dir path =
  try Fs_compat.file_exists path && Sys.is_directory path with
  | Sys_error _ -> false

let repo_name_of_json = function
  | `Assoc fields -> (
      match List.assoc_opt "name" fields with
      | Some (`String name) when String.trim name <> "" -> Some name
      | _ -> None)
  | _ -> None

let upsert_assoc key value fields =
  (key, value) :: List.remove_assoc key fields

let git_metadata_timeout_sec = 2.0

let git_string_opt repo_path args =
  try
    let status, out =
      Process_eio.run_argv_with_status ~timeout_sec:git_metadata_timeout_sec
        ("git" :: "-C" :: repo_path :: args)
    in
    match status with
    | Unix.WEXITED 0 ->
        let trimmed = String.trim out in
        if String.equal trimmed "" then None else Some trimmed
    | _ -> None
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ -> None

let enrich_playground_repo_from_git
      ~(source : string) ~(repo_name : string) ~(repo_path : string)
      (repo_json : Yojson.Safe.t) =
  let fields =
    match repo_json with
    | `Assoc fields -> fields
    | _ -> [ ("name", `String repo_name) ]
  in
  let fields =
    fields
    |> upsert_assoc "name" (`String repo_name)
    |> upsert_assoc "path" (`String (Filename.concat "repos" repo_name))
    |> upsert_assoc "source" (`String source)
    |> upsert_assoc "observed_at"
         (`String (Printf.sprintf "%.0f" (Unix.gettimeofday ())))
  in
  let fields =
    match git_string_opt repo_path [ "rev-parse"; "--abbrev-ref"; "HEAD" ] with
    | Some branch -> upsert_assoc "branch" (`String branch) fields
    | None -> fields
  in
  let fields =
    match git_string_opt repo_path [ "log"; "--oneline"; "-1" ] with
    | Some commit -> upsert_assoc "latest_commit" (`String commit) fields
    | None -> fields
  in
  let fields =
    match git_string_opt repo_path [ "rev-parse"; "--is-shallow-repository" ] with
    | Some raw ->
        upsert_assoc "shallow"
          (`Bool (String.equal (String.lowercase_ascii raw) "true"))
          fields
    | None -> fields
  in
  `Assoc fields

let cached_playground_repo_entries playground_abs =
  let cache_path = Filename.concat playground_abs ".playground_state.json" in
  try
    match Yojson.Safe.from_file cache_path with
    | `Assoc _ as json -> (
        match Yojson.Safe.Util.member "repos" json with
        | `List repos -> repos
        | _ -> [])
    | _ -> []
  with
  | Sys_error _ | Yojson.Json_error _ -> []

let filesystem_playground_repo_names playground_abs =
  let repos_dir = Filename.concat playground_abs "repos" in
  if not (safe_is_dir repos_dir) then []
  else
    try
      Sys.readdir repos_dir
      |> Array.to_list
      |> List.filter (fun name ->
        let repo_path = Filename.concat repos_dir name in
        safe_is_dir repo_path
        && safe_file_exists (Filename.concat repo_path ".git"))
      |> List.sort String.compare
    with
    | Sys_error _ -> []

let playground_repos_json ~(config : Coord.config) ~(meta : keeper_meta) =
  let playground_abs =
    Keeper_sandbox.host_root_abs_of_meta ~config meta
    |> normalize_path
  in
  let repos_dir = Filename.concat playground_abs "repos" in
  let cached =
    cached_playground_repo_entries playground_abs
    |> List.map (fun repo ->
      match repo_name_of_json repo with
      | Some name ->
          let repo_path = Filename.concat repos_dir name in
          if safe_is_dir repo_path
             && safe_file_exists (Filename.concat repo_path ".git")
          then
            enrich_playground_repo_from_git ~source:"git" ~repo_name:name
              ~repo_path repo
          else repo
      | None -> repo)
  in
  let cached_names = List.filter_map repo_name_of_json cached in
  let fs_entries =
    filesystem_playground_repo_names playground_abs
    |> List.filter (fun name -> not (List.mem name cached_names))
    |> List.map (fun name ->
      let repo_path = Filename.concat repos_dir name in
      enrich_playground_repo_from_git ~source:"filesystem" ~repo_name:name
        ~repo_path (`Assoc []))
  in
  `List (cached @ fs_entries)

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
              "no visible managed sandbox container; network_mode=inherit uses one-shot Docker containers on sandboxed tool calls, and those containers still mount the keeper playground"
        | Network_none ->
            Some
              "no active turn or visible managed sandbox container; Docker containers start on sandboxed tool calls or via masc_keeper_sandbox_start, with the keeper playground mounted")

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
             "Run masc_keeper_sandbox_start with name=%S only when you need a visible prewarmed container; repo access also requires playground_repos to include the target repo."
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
    ?preflight_override
    ~(config : Coord.config)
    ~(meta : keeper_meta)
    ~(timeout_sec : float)
    ~(verbose : bool)
    () =
  let preflight =
    match preflight_override with
    | Some cached -> cached
    | None ->
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
      ("playground_repos", playground_repos_json ~config ~meta);
      ("identity", identity_json meta);
    ]
