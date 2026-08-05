(** Operator-facing keeper sandbox control.

    This module keeps Docker lifecycle operations scoped to MASC keeper labels
    and the active base path.  Start operations deliberately manage only
    [container_kind=managed]; stop operations default to that same safe scope,
    but can target [turn] or [all] when an operator needs to clear abandoned
    turn containers before TTL cleanup. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

module Contract = Keeper_sandbox_control_contract

type stop_scope = Contract.stop_scope =
  | Stop_managed
  | Stop_turn
  | Stop_all

let stop_scope_to_string = Contract.stop_scope_to_string
let parse_stop_scope = Contract.parse_stop_scope
let managed_kind = stop_scope_to_string Stop_managed
let turn_kind = stop_scope_to_string Stop_turn
let all_kind = stop_scope_to_string Stop_all

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

(* Monotonically increasing counter to disambiguate managed containers
   created within the same millisecond by the same process.  Mirrors
   {!Keeper_turn_sandbox_runtime.container_counter}. *)
let managed_container_counter : int Atomic.t = Atomic.make 0

let managed_container_name ~(meta : keeper_meta) ~(network_label : string) =
  let seq = Atomic.fetch_and_add managed_container_counter 1 in
  Printf.sprintf "masc-keeper-managed-%s-%s-%d-%d-%d"
    (Workspace_utils.safe_filename meta.name)
    (Workspace_utils.safe_filename network_label)
    (Unix.getpid ())
    (now_ms ())
    seq

let configured_effective_network network_mode = network_mode

let live_containers ~config ~meta ~timeout_sec =
  Keeper_sandbox_runtime.list_containers
    ~keeper_name:meta.name
    ~base_path:config.Workspace.base_path
    ~timeout_sec
    ()

let live_containers_for_keeper ~(meta : keeper_meta) containers =
  let keeper_label = Keeper_sandbox_runtime.sanitize_label_value meta.name in
  List.filter
    (fun (c : Keeper_sandbox_runtime.live_container) ->
      match c.keeper_name with
      | Some name -> String.equal name meta.name || String.equal name keeper_label
      | None -> false)
    containers

let running_managed_container ~network_label containers =
  List.find_opt
    (fun (c : Keeper_sandbox_runtime.live_container) ->
      c.container_kind = Some managed_kind
      && c.running = Some true
      && c.network_label = Some network_label)
    containers

let start_managed_container
    ~(config : Workspace.config)
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
    let probe_timeout = timeout_sec in
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
              | _ -> Env_config_sandbox.Runtime.docker_image ()
            in
            if String.trim image = "" then
              Error "keeper sandbox docker image is not configured"
            else
              match
                Keeper_sandbox_runtime.ensure_keeper_sandbox_image_present_with_class
                  ~image
                  ~timeout_sec
              with
              | Error failure ->
                Error (Keeper_sandbox_runtime.image_preflight_start_error failure)
              | Ok () ->
              let _cleanup =
                Keeper_sandbox_runtime.maybe_cleanup_stale_containers
                  ~base_path:config.base_path

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
                    @ Keeper_sandbox_runtime.docker_run_pull_never_args ()
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
                    @ Env_config_sandbox.Hardening.read_only_rootfs_args ()
                    @ [
                      "--tmpfs";
                      Env_config_sandbox.Hardening.tmpfs_mount ();
                      "--cap-drop=ALL";
                      "--security-opt";
                      "no-new-privileges";
                    ]
                    @ seccomp_args
                    @ [
                      "--pids-limit";
                      string_of_int
                        (Env_config_sandbox.Hardening.pids_limit ());
                      "--memory";
                      Env_config_sandbox.Hardening.memory ();
                      "-v";
                      host_root ^ ":" ^ container_root ^ ":rw";
                      "--workdir";
                      container_root;
                    ]
                    @ network_args
                    @ [ image; "tail"; "-f"; "/dev/null" ]
                  in
                  (* Record the exact Docker spawn dynamic extent without
                     delaying or rejecting the keeper lane. *)
                  let st, out =
                    Fd_accountant.observe ~kind:Fd_accountant.Docker_spawn (fun () ->
                      Process_eio.run_argv_with_status
                        ~env:(Env_keeper_scrub.filter_environment (Unix.environment ()))
                        ~cwd:(Config_dir_resolver.current_working_dir ())
                        ~timeout_sec
                        argv)
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
                        (Exec_policy.truncate_for_log out)
                    in
                    Keeper_registry_error_recording.record
                      ~base_path:config.base_path meta.name message;
                    Error message))
    | Error err -> Error err

let stop_containers ?keeper_name ~scope ~(config : Workspace.config)
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

let stop_managed_containers ?keeper_name ~(config : Workspace.config)
    ~(timeout_sec : float) () =
  stop_containers ?keeper_name ~scope:Stop_managed ~config ~timeout_sec ()

let cleanup_stale ~(config : Workspace.config) ~(timeout_sec : float) () =
  Keeper_sandbox_runtime.cleanup_stale_containers
    ~base_path:config.base_path
    ~timeout_sec
    ()

let observed_is_dir path =
  try
    match Fs_compat.exact_path_kind ~follow:false path with
    | Fs_compat.Exact_kind Unix.S_DIR -> true
    | Fs_compat.Exact_missing
    | Fs_compat.Exact_kind _
    | Fs_compat.Exact_unknown -> false
  with
  | Sys_error error ->
    Log.Keeper.warn
      "playground filesystem observation failed path=%s error=%s"
      path
      error;
    false
  | Unix.Unix_error (error, operation, argument) ->
    Log.Keeper.warn
      "playground filesystem observation failed path=%s error=%s(%s): %s"
      path
      operation
      argument
      (Unix.error_message error);
    false

let valid_checkout_name name =
  name <> ""
  && name <> "."
  && name <> ".."
  && not (String.contains name '/')
  && not (String.contains name '\\')
  && String.equal (Filename.basename name) name

let filesystem_checkout_names sandbox_abs =
  let repos_dir = Filename.concat sandbox_abs "repos" in
  if not (observed_is_dir repos_dir) then []
  else
    try
      Sys.readdir repos_dir
      |> Array.to_list
      |> List.filter (fun name ->
        let repo_path = Filename.concat repos_dir name in
        valid_checkout_name name && observed_is_dir repo_path)
      |> List.sort String.compare
    with
    | Sys_error error ->
      Log.Keeper.warn
        "repository checkout observation failed path=%s error=%s"
        repos_dir
        error;
      []

type catalog_resolution =
  | Registered of Repo_manager_types.repository
  | Unregistered
  | Ambiguous of string list
  | Catalog_unavailable of string
  | Origin_unavailable of string

type checkout_freshness =
  | Current of { target_ref : string; upstream_head : string }
  | Ahead of { target_ref : string; upstream_head : string; ahead : int }
  | Behind of { target_ref : string; upstream_head : string; behind : int }
  | Diverged of
      { target_ref : string
      ; upstream_head : string
      ; ahead : int
      ; behind : int
      }
  | Freshness_unavailable of string

let canonical_url raw = Agent_observation.canonical_url_of_remote raw

let resolve_catalog ~catalog ~origin =
  match catalog with
  | Error error -> Catalog_unavailable error
  | Ok repositories ->
    (match canonical_url origin with
     | None -> Origin_unavailable "origin URL is not canonicalizable"
     | Some origin_id ->
       let matches =
         List.filter
           (fun (repo : Repo_manager_types.repository) ->
             match canonical_url repo.url with
             | Some catalog_id -> String.equal catalog_id origin_id
             | None -> false)
           repositories
       in
       match matches with
       | [ repo ] -> Registered repo
       | [] -> Unregistered
       | repos -> Ambiguous (List.map (fun repo -> repo.Repo_manager_types.id) repos))

let first_git_line ~cwd args =
  match Repo_git.run_git ~cwd args with
  | Ok (line :: _) -> Ok line
  | Ok [] -> Error (Printf.sprintf "git %s returned no output" (String.concat " " args))
  | Error _ as error -> error

let dirty_state ~repository =
  match Repo_git.status_summary ~repository with
  | Ok summary -> Ok (summary.Repo_git.changed_files > 0, summary.changed_files)
  | Error _ as error -> error

let freshness_of_catalog ~repository = function
  | Registered catalog_repo ->
    let target_ref = "origin/" ^ catalog_repo.default_branch in
    (match first_git_line ~cwd:repository.Repo_manager_types.local_path [ "rev-parse"; target_ref ] with
     | Error error -> Freshness_unavailable error
     | Ok upstream_head ->
       (match Repo_git.ahead_behind ~repository ~target_ref with
        | Error error -> Freshness_unavailable error
        | Ok (0, 0) -> Current { target_ref; upstream_head }
        | Ok (0, ahead) -> Ahead { target_ref; upstream_head; ahead }
        | Ok (behind, 0) -> Behind { target_ref; upstream_head; behind }
        | Ok (behind, ahead) -> Diverged { target_ref; upstream_head; ahead; behind }))
  | Unregistered -> Freshness_unavailable "checkout is not registered in the repository catalog"
  | Ambiguous ids ->
    Freshness_unavailable
      (Printf.sprintf "checkout origin matches multiple repository ids: %s"
         (String.concat ", " ids))
  | Catalog_unavailable error -> Freshness_unavailable ("repository catalog unavailable: " ^ error)
  | Origin_unavailable error -> Freshness_unavailable error

let catalog_json = function
  | Registered repo ->
    `Assoc [ "state", `String "registered"; "repository_id", `String repo.id ]
  | Unregistered -> `Assoc [ "state", `String "unregistered" ]
  | Ambiguous ids ->
    `Assoc
      [ "state", `String "ambiguous"
      ; "repository_ids", `List (List.map (fun id -> `String id) ids)
      ]
  | Catalog_unavailable error ->
    `Assoc [ "state", `String "unavailable"; "error", `String error ]
  | Origin_unavailable error ->
    `Assoc [ "state", `String "origin_unavailable"; "error", `String error ]

let freshness_json = function
  | Current { target_ref; upstream_head } ->
    `Assoc
      [ "state", `String "current"; "target_ref", `String target_ref
      ; "upstream_head", `String upstream_head; "ahead", `Int 0; "behind", `Int 0 ]
  | Ahead { target_ref; upstream_head; ahead } ->
    `Assoc
      [ "state", `String "ahead"; "target_ref", `String target_ref
      ; "upstream_head", `String upstream_head; "ahead", `Int ahead; "behind", `Int 0 ]
  | Behind { target_ref; upstream_head; behind } ->
    `Assoc
      [ "state", `String "behind"; "target_ref", `String target_ref
      ; "upstream_head", `String upstream_head; "ahead", `Int 0; "behind", `Int behind ]
  | Diverged { target_ref; upstream_head; ahead; behind } ->
    `Assoc
      [ "state", `String "diverged"; "target_ref", `String target_ref
      ; "upstream_head", `String upstream_head; "ahead", `Int ahead; "behind", `Int behind ]
  | Freshness_unavailable error ->
    `Assoc [ "state", `String "unavailable"; "error", `String error ]

let checkout_json ~catalog ~sandbox_abs name =
  let checkout_abs = Filename.concat (Filename.concat sandbox_abs "repos") name in
  let origin = Repo_git.get_origin_url ~local_path:checkout_abs in
  let catalog_resolution =
    match origin with
    | Ok origin -> resolve_catalog ~catalog ~origin
    | Error error -> Origin_unavailable error
  in
  let repository : Repo_manager_types.repository =
    match catalog_resolution with
    | Registered repo -> { repo with local_path = checkout_abs }
    | Unregistered | Ambiguous _ | Catalog_unavailable _ | Origin_unavailable _ ->
      { id = name; name; url = ""; local_path = checkout_abs; aliases = []
      ; default_branch = ""; keepers = []; status = Active; auto_sync = false
      ; sync_interval = 0; created_at = 0L; updated_at = 0L }
  in
  let branch = Repo_git.current_branch ~repository in
  let head = first_git_line ~cwd:checkout_abs [ "rev-parse"; "HEAD" ] in
  let dirty = dirty_state ~repository in
  let inspection_errors =
    [ (match branch with Error error -> Some ("branch: " ^ error) | Ok _ -> None)
    ; (match head with Error error -> Some ("head: " ^ error) | Ok _ -> None)
    ; (match dirty with Error error -> Some ("status: " ^ error) | Ok _ -> None)
    ]
    |> List.filter_map Fun.id
  in
  `Assoc
    [ "checkout_name", `String name
    ; "path", `String (Filename.concat "repos" name)
    ; "catalog", catalog_json catalog_resolution
    ; "branch", (match branch with Ok value -> `String value | Error _ -> `Null)
    ; "head", (match head with Ok value -> `String value | Error _ -> `Null)
    ; "dirty", (match dirty with Ok (value, _) -> `Bool value | Error _ -> `Null)
    ; "changed_files", (match dirty with Ok (_, value) -> `Int value | Error _ -> `Null)
    ; "inspection_state", `String (if inspection_errors = [] then "available" else "unavailable")
    ; "inspection_errors", `List (List.map (fun error -> `String error) inspection_errors)
    ; "freshness", freshness_json (freshness_of_catalog ~repository catalog_resolution)
    ]

let repository_checkouts_json ~(config : Workspace.config) ~(meta : keeper_meta) =
  let sandbox_abs =
    Keeper_sandbox.host_root_abs_of_meta ~config meta
    |> normalize_path
  in
  let observed_at_unix = Time_compat.now () in
  let catalog = Repo_store.load_all ~base_path:config.base_path in
  let entries =
    filesystem_checkout_names sandbox_abs
    |> List.map (checkout_json ~catalog ~sandbox_abs)
  in
  `Assoc
    [ "state", `String (match catalog with Ok _ -> "available" | Error _ -> "catalog_unavailable")
    ; "freshness_basis", `String "local_tracking_ref"
    ; "observed_at", `String (Masc_domain.iso8601_of_unix_seconds observed_at_unix)
    ; "observed_at_unix", `Float observed_at_unix
    ; "entries", `List entries
    ; "error", (match catalog with Ok _ -> `Null | Error error -> `String error)
    ]

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

let identity_json (meta : keeper_meta) =
  let expected_agent_name = Keeper_identity.keeper_agent_name meta.name in
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
    ?containers_override
    ?(include_repository_checkouts = true)
    ~(config : Workspace.config)
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
      match containers_override with
      | Some (Ok containers) ->
          (live_containers_for_keeper ~meta containers, None)
      | Some (Error err) -> ([], Some err)
      | None -> (
        match live_containers ~config ~meta ~timeout_sec with
        | Ok containers -> (containers, None)
        | Error err -> ([], Some err))
    else
      ([], None)
  in
  let why_no_container =
    match container_error with
    | Some _ -> Some "docker_container_listing_failed"
    | None -> why_no_container meta ~preflight containers
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
      ( "repository_checkouts",
        if include_repository_checkouts then
          repository_checkouts_json ~config ~meta
        else
          `Assoc [ "state", `String "not_inspected"; "entries", `List [] ] );
      ("identity", identity_json meta);
    ]
