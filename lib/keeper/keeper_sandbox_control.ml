(** Operator-facing keeper sandbox control.

    This module keeps Docker lifecycle operations scoped to MASC keeper labels
    and the active base path.  Start operations deliberately manage only
    [container_kind=managed]; stop operations default to that same safe scope,
    but can target [turn] or [all] when an operator needs to clear abandoned
    turn containers before TTL cleanup. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

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

let image_preflight_start_error (failure : Keeper_sandbox_runtime.classified_error) =
  Keeper_sandbox_runtime.docker_image_preflight_failure_message
    ~prefix:"docker_container_start_failed"
    failure
;;

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
              | Error failure -> Error (image_preflight_start_error failure)
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
                  (* Throttle the managed-container [docker run -d] just like
                     the per-call sandbox spawns (PR #15727). RFC-0097 calls
                     out the "24+ keepers starting simultaneously after a
                     server restart" scenario explicitly — without this wrap
                     it was the only first-class start path bypassing the
                     fleet-wide spawn semaphore. *)
                  let st, out =
                    Docker_spawn_throttle.with_slot (fun () ->
                      Masc_exec.Exec_gate.run_argv_with_status
                        ~actor:`System_sandbox
                        ~raw_source:(String.concat " " argv)
                        ~summary:"keeper sandbox control exec"
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

let safe_file_exists path =
  try Fs_compat.file_exists path with
  | Sys_error _ -> false

let safe_is_dir path =
  try Fs_compat.file_exists path && Sys.is_directory path with
  | Sys_error _ -> false

let repo_name_of_json = function
  | `Assoc fields -> (
      match List.assoc_opt "name" fields with
      | Some (`String raw_name) ->
          let name = String.trim raw_name in
          if
            name <> ""
            && name <> "."
            && name <> ".."
            && not (String.contains name '/')
            && not (String.contains name '\\')
            && String.equal (Filename.basename name) name
          then Some name
          else None
      | _ -> None)
  | _ -> None

let upsert_assoc key value fields =
  (key, value) :: List.remove_assoc key fields

type playground_policy_status =
  | Policy_allowed
  | Policy_unregistered_repository
  | Policy_mapping_load_error
  | Policy_repository_identity_mismatch
  | Policy_repository_store_error

let playground_policy_status_to_string = function
  | Policy_allowed -> "allowed"
  | Policy_unregistered_repository -> "unregistered_repository"
  | Policy_mapping_load_error -> "mapping_load_error"
  | Policy_repository_identity_mismatch -> "repository_identity_mismatch"
  | Policy_repository_store_error -> "repository_store_error"

let playground_policy_reason = function
  | Policy_allowed -> None
  | Policy_unregistered_repository ->
      Some
        "repository is not registered in the repository catalog; access is \
         denied fail-closed"
  | Policy_mapping_load_error ->
      Some
        "keeper repository mapping could not be loaded; advisory mapping is \
         ignored"
  | Policy_repository_identity_mismatch ->
      Some
        "repository identity does not match the playground clone; access is \
         denied fail-closed"
  | Policy_repository_store_error ->
      Some
        "repository catalog could not be loaded; access is denied fail-closed"

let playground_repo_policy ~(base_path : string) ~(keeper_name : string) =
  match Keeper_repo_mapping.lookup_mapping ~base_path ~keeper_id:keeper_name with
  | Keeper_repo_mapping.Mapping_load_error msg as r ->
    Keeper_repo_mapping.log_mapping_load_error_if_new ~keeper_id:keeper_name msg;
    r
  | r -> r

let playground_repo_policy_repository_id ~base_path ~repo_catalog ~repo_name
    ~repo_path =
  match repo_catalog with
  | Error msg -> Error (`Store_error msg)
  | Ok repos -> (
  match
    Keeper_repo_mapping.repository_resolution_of_path_from_catalog ~base_path
      ~path:repo_path repos
  with
  | Keeper_repo_mapping.Repository repository_id -> Ok repository_id
  | Keeper_repo_mapping.No_repository -> Ok repo_name
  | Keeper_repo_mapping.Repository_identity_mismatch _ ->
    Error
      (`Identity_mismatch
        "repository identity mismatch; access is denied fail-closed")
  | Keeper_repo_mapping.Repository_store_error msg -> Error (`Store_error msg))

let playground_repo_policy_fields ~base_path ~repo_catalog ~keeper_id:_ policy
      ~repo_name ~repo_path =
  let field status allowed ?repository_id ?error ?mapping_error
        ?(default_scope = false) () =
    let status_text = playground_policy_status_to_string status in
    let reason_fields =
      match playground_policy_reason status with
      | None -> []
      | Some reason -> [ ("policy_reason", `String reason) ]
    in
    let repository_id_fields =
      match repository_id with
      | None -> []
      | Some repository_id -> [ ("policy_repository_id", `String repository_id) ]
    in
    let error_fields =
      match error with
      | None -> []
      | Some msg -> [ ("policy_error", `String msg) ]
    in
    let mapping_error_fields =
      match mapping_error with
      | None -> []
      | Some msg -> [ ("policy_mapping_error", `String msg) ]
    in
    let default_scope_fields =
      if default_scope then [ ("policy_default_scope", `Bool true) ] else []
    in
    ( "policy_source"
    , `String Keeper_repo_mapping.mappings_toml_basename )
    :: ("policy_status", `String status_text)
    :: ("policy_allowed", `Bool allowed)
    :: (default_scope_fields @ repository_id_fields @ reason_fields
        @ error_fields @ mapping_error_fields)
  in
  let repository_id_in_catalog repository_id =
    match repo_catalog with
    | Error msg -> Error (`Store_error msg)
    | Ok repos ->
      Ok
        (List.exists
           (fun (repo : Repo_manager_types.repository) ->
             String.equal repo.id repository_id)
           repos)
  in
  let field_resolved_registered ?mapping_error ~default_scope () =
    match
      playground_repo_policy_repository_id ~base_path ~repo_catalog ~repo_name
        ~repo_path
    with
    | Error (`Identity_mismatch msg) ->
      field Policy_repository_identity_mismatch false
        ~repository_id:repo_name ~error:msg ()
    | Error (`Store_error msg) ->
      field Policy_repository_store_error false ~repository_id:repo_name
        ~error:msg ()
    | Ok repository_id ->
      (match repository_id_in_catalog repository_id with
       | Error (`Store_error msg) ->
         field Policy_repository_store_error false ~repository_id ~error:msg ()
       | Ok true ->
         field Policy_allowed true ~repository_id ?mapping_error ~default_scope ()
       | Ok false -> field Policy_unregistered_repository false ~repository_id ())
  in
  match policy with
  | Keeper_repo_mapping.Mapping_load_error msg ->
      field_resolved_registered ~mapping_error:msg ~default_scope:true ()
  | Keeper_repo_mapping.Mapping_missing _ ->
      field_resolved_registered ~default_scope:true ()
  | Keeper_repo_mapping.Mapping_found mapping ->
      (match
       playground_repo_policy_repository_id ~base_path ~repo_catalog ~repo_name
         ~repo_path
       with
       | Error (`Identity_mismatch msg) ->
         field Policy_repository_identity_mismatch false
           ~repository_id:repo_name ~error:msg ()
       | Error (`Store_error msg) ->
         field Policy_repository_store_error false ~repository_id:repo_name
           ~error:msg ()
       | Ok repository_id ->
         (match repository_id_in_catalog repository_id with
          | Error (`Store_error msg) ->
            field Policy_repository_store_error false ~repository_id ~error:msg ()
          | Ok false -> field Policy_unregistered_repository false ~repository_id ()
          | Ok true ->
            let default_scope =
              Keeper_repo_mapping.mapping_allows_repository mapping ~repository_id
            in
            field Policy_allowed true ~repository_id ~default_scope ()))

let with_playground_repo_policy_fields ~base_path ~repo_catalog ~keeper_id policy
      ~repo_name ~repo_path = function
  | `Assoc fields ->
      playground_repo_policy_fields ~base_path ~repo_catalog ~keeper_id policy
        ~repo_name ~repo_path
      |> List.fold_left
           (fun fields (key, value) -> upsert_assoc key value fields)
           fields
      |> fun fields -> `Assoc fields
  | json ->
      Log.Misc.warn
        "[KeeperSandboxControl] playground repo entry for %s is not a JSON object; \
         preserving original value (%s)"
        repo_name (Yojson.Safe.to_string json);
      json

let git_metadata_timeout_sec = 2.0
let max_live_git_enrichment_repos = 20

let git_string_opt repo_path args =
  (* RFC-0106 P1: Cancelled re-raise centralised via Cancel_safe.protect.
     The [_ -> None] silent default is pre-existing behaviour (git
     metadata is treated as optional by callers) and is preserved
     verbatim. Promoting it to a logged/counted failure is a separate
     visibility concern outside this PR's migration scope. *)
  Cancel_safe.protect
    ~on_exn:(fun _ -> None)
    (fun () ->
      match
        Repo_git.run_git ~cwd:repo_path
          ~timeout_sec:git_metadata_timeout_sec args
      with
      | Ok (line :: _) ->
          let trimmed = String.trim line in
          if String.equal trimmed "" then None else Some trimmed
      | Ok [] | Error _ -> None)

let enrich_playground_repo_from_git
      ~(source : string) ~(repo_name : string) ~(repo_path : string)
      (repo_json : Yojson.Safe.t) =
  let observed_at_unix = Time_compat.now () in
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
         (`String (Masc_domain.iso8601_of_unix_seconds observed_at_unix))
    |> upsert_assoc "observed_at_unix" (`Float observed_at_unix)
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

let playground_repo_entry_json ~(source : string) ~(repo_name : string)
    (repo_json : Yojson.Safe.t) =
  let observed_at_unix = Time_compat.now () in
  let fields =
    match repo_json with
    | `Assoc fields -> fields
    | _ -> [ ("name", `String repo_name) ]
  in
  fields
  |> upsert_assoc "name" (`String repo_name)
  |> upsert_assoc "path" (`String (Filename.concat "repos" repo_name))
  |> upsert_assoc "source" (`String source)
  |> upsert_assoc "observed_at"
       (`String (Masc_domain.iso8601_of_unix_seconds observed_at_unix))
  |> upsert_assoc "observed_at_unix" (`Float observed_at_unix)
  |> fun fields -> `Assoc fields

let cached_playground_repo_entries playground_abs =
  let cache_path = Filename.concat playground_abs ".playground_state.json" in
  try
    match Yojson.Safe.from_file cache_path with
    | `Assoc _ as json -> (
        match Json_util.assoc_member_opt "repos" json with
        | Some (`List repos) -> repos
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

let playground_repos_json ~(config : Workspace.config) ~(meta : keeper_meta) =
  let playground_abs =
    Keeper_sandbox.host_root_abs_of_meta ~config meta
    |> normalize_path
  in
  let repos_dir = Filename.concat playground_abs "repos" in
  let policy =
    playground_repo_policy ~base_path:config.base_path ~keeper_name:meta.name
  in
  let repo_catalog = Repo_store.load_all ~base_path:config.base_path in
  let live_enriched_count = ref 0 in
  let cached =
    cached_playground_repo_entries playground_abs
    |> List.map (fun repo ->
      match repo_name_of_json repo with
      | Some name ->
          let repo_path = Filename.concat repos_dir name in
          if safe_is_dir repo_path
             && safe_file_exists (Filename.concat repo_path ".git")
             && !live_enriched_count < max_live_git_enrichment_repos
          then
            (incr live_enriched_count;
            enrich_playground_repo_from_git ~source:"git" ~repo_name:name
              ~repo_path repo
            |> with_playground_repo_policy_fields ~base_path:config.base_path
                 ~repo_catalog ~keeper_id:meta.name policy ~repo_name:name
                 ~repo_path)
          else
            playground_repo_entry_json ~source:"cache" ~repo_name:name repo
            |> with_playground_repo_policy_fields ~base_path:config.base_path
                 ~repo_catalog ~keeper_id:meta.name policy ~repo_name:name
                 ~repo_path
      | None -> repo)
  in
  let cached_names = List.filter_map repo_name_of_json cached in
  let fs_entries =
    filesystem_playground_repo_names playground_abs
    |> List.filter (fun name -> not (List.mem name cached_names))
    |> List.map (fun name ->
      playground_repo_entry_json ~source:"filesystem" ~repo_name:name
        (`Assoc [])
      |> with_playground_repo_policy_fields ~base_path:config.base_path
           ~repo_catalog ~keeper_id:meta.name policy ~repo_name:name
           ~repo_path:(Filename.concat repos_dir name))
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
    ?(include_playground_repos = true)
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
      ( "playground_repos",
        if include_playground_repos then
          playground_repos_json ~config ~meta
        else
          `List [] );
      ( "playground_repos_source",
        `String
          (if include_playground_repos then "live"
           else "skipped_dashboard_hot_path") );
      ("identity", identity_json meta);
    ]
