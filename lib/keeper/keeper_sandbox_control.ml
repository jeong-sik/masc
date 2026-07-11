(** Operator-facing keeper sandbox inspection and stop control.

    Docker containers are created on demand by the real turn and one-shot
    runtimes. This module never creates a parallel "managed" container that no
    execution path consumes. Stop operations are scoped by the active base path,
    an optional validated keeper name, and an explicit typed container scope. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

type stop_scope = Keeper_types_profile_sandbox.sandbox_stop_scope =
  | Stop_kind of Keeper_types_profile_sandbox.sandbox_container_kind
  | Stop_all

let stop_scope_to_string =
  Keeper_types_profile_sandbox.sandbox_stop_scope_to_string

let parse_stop_scope raw =
  match Keeper_types_profile_sandbox.sandbox_stop_scope_of_string raw with
  | Some scope -> Ok scope
  | None ->
      Error
        (Printf.sprintf
           "invalid container_kind %S; expected one of: %s"
           raw
           (String.concat
              ", "
              Keeper_types_profile_sandbox.valid_sandbox_stop_scope_strings))

let normalize_path path =
  Keeper_alerting_path.normalize_path_for_check path
  |> Keeper_alerting_path.strip_trailing_slashes

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

let stop_containers ?keeper_name ~scope ~(config : Workspace.config)
    ~(timeout_sec : float) () =
  let container_kind =
    match scope with
    | Stop_kind kind ->
        Some (Keeper_types_profile_sandbox.sandbox_container_kind_to_string kind)
    | Stop_all -> None
  in
  Keeper_sandbox_runtime.stop_containers
    ?keeper_name
    ?container_kind
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

let nullable_string = function
  | Some value -> `String value
  | None -> `Null

let combine_errors errors =
  match List.filter_map Fun.id errors with
  | [] -> None
  | messages -> Some (String.concat "; " messages)

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

(* Which config file actually decided this status. The binding allow/deny gate
   is the repository catalog (repositories.toml): a repo is usable iff it is
   registered there, and [access_decision] never denies on the mapping — per
   RFC-0312 the keeper_repo_mappings.toml scope is advisory. So every
   catalog-sourced verdict (allowed / unregistered / identity mismatch / store
   load error) is labelled with the catalog basename; only the
   mapping-file-load failure is sourced from the advisory mapping. Exhaustive
   so a new status cannot silently inherit the wrong source. *)
let policy_source_basename_of_status : playground_policy_status -> string
  = function
  | Policy_allowed
  | Policy_unregistered_repository
  | Policy_repository_identity_mismatch
  | Policy_repository_store_error ->
      Config_dir_resolver.repositories_toml_basename
  | Policy_mapping_load_error -> Keeper_repo_mapping.mappings_toml_basename

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
  | Keeper_repo_mapping.Repository { repository_id; _ } -> Ok repository_id
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
    let policy_reason = playground_policy_reason status in
    let repository_id_fields =
      match repository_id with
      | None -> []
      | Some repository_id -> [ ("policy_repository_id", `String repository_id) ]
    in
    let error = combine_errors [ error; mapping_error ] in
    let default_scope_fields =
      if default_scope then [ ("policy_default_scope", `Bool true) ] else []
    in
    ( "policy_source"
    , `String (policy_source_basename_of_status status) )
    :: ("policy_status", `String status_text)
    :: ("policy_allowed", `Bool allowed)
    :: ("policy_reason", nullable_string policy_reason)
    :: ("error", nullable_string error)
    :: (default_scope_fields @ repository_id_fields)
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
      let existing_error =
        match List.assoc_opt "error" fields with
        | Some (`String msg) -> Some msg
        | _ -> None
      in
      let policy_fields =
        playground_repo_policy_fields ~base_path ~repo_catalog ~keeper_id policy
          ~repo_name ~repo_path
      in
      let policy_error =
        match List.assoc_opt "error" policy_fields with
        | Some (`String msg) -> Some msg
        | _ -> None
      in
      let merged_error = combine_errors [ existing_error; policy_error ] in
      policy_fields
      |> List.remove_assoc "error"
      |> List.fold_left
           (fun fields (key, value) -> upsert_assoc key value fields)
           fields
      |> upsert_assoc "error" (nullable_string merged_error)
      |> fun fields -> `Assoc fields
  | json ->
      Log.Misc.warn
        "[KeeperSandboxControl] playground repo entry for %s is not a JSON object; \
         preserving original value (%s)"
        repo_name (Yojson.Safe.to_string json);
      `Assoc
        [ "name", `String repo_name
        ; "source", `String "cache"
        ; "path", `String (Filename.concat "repos" repo_name)
        ; "policy_status", `String "repository_store_error"
        ; "policy_allowed", `Bool false
        ; "policy_source", `String Config_dir_resolver.repositories_toml_basename
        ; "policy_reason", `String "invalid playground repository observation"
        ; "error", `String "playground repository observation is not an object"
        ]

let git_string_result ~timeout_sec repo_path args =
  Cancel_safe.protect
    ~on_exn:(fun exn -> Error (Printexc.to_string exn))
    (fun () ->
      match
        Repo_git.run_git ~cwd:repo_path
          ~timeout_sec args
      with
      | Ok (line :: _) ->
          let trimmed = String.trim line in
          if String.equal trimmed ""
          then Error "git returned an empty first line"
          else Ok trimmed
      | Ok [] -> Error "git returned no output"
      | Error msg -> Error msg)

let observed_value ~operation = function
  | Ok value -> Some value, None
  | Error msg -> None, Some (Printf.sprintf "%s: %s" operation msg)

let enrich_playground_repo_from_git
      ~timeout_sec ~(repo_name : string) ~(repo_path : string)
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
    |> upsert_assoc "source" (`String "git")
    |> upsert_assoc "observed_at"
         (`String (Masc_domain.iso8601_of_unix_seconds observed_at_unix))
    |> upsert_assoc "observed_at_unix" (`Float observed_at_unix)
  in
  let branch, branch_error =
    git_string_result ~timeout_sec repo_path [ "rev-parse"; "--abbrev-ref"; "HEAD" ]
    |> observed_value ~operation:"branch"
  in
  let fields =
    match branch with
    | Some branch -> upsert_assoc "branch" (`String branch) fields
    | None -> fields
  in
  let latest_commit, latest_commit_error =
    git_string_result ~timeout_sec repo_path [ "log"; "--oneline"; "-1" ]
    |> observed_value ~operation:"latest_commit"
  in
  let fields =
    match latest_commit with
    | Some commit -> upsert_assoc "latest_commit" (`String commit) fields
    | None -> fields
  in
  let shallow_raw, shallow_error =
    git_string_result
      ~timeout_sec
      repo_path
      [ "rev-parse"; "--is-shallow-repository" ]
    |> observed_value ~operation:"shallow"
  in
  let shallow, shallow_decode_error =
    match shallow_raw with
    | None -> None, None
    | Some raw ->
      (match bool_of_string_opt (String.lowercase_ascii raw) with
       | Some value -> Some value, None
       | None ->
         None,
         Some (Printf.sprintf "shallow: invalid boolean output %S" raw))
  in
  let fields =
    match shallow with
    | Some value -> upsert_assoc "shallow" (`Bool value) fields
    | None -> fields
  in
  let error =
    combine_errors
      [ branch_error; latest_commit_error; shallow_error; shallow_decode_error ]
  in
  `Assoc (upsert_assoc "error" (nullable_string error) fields)

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
  |> upsert_assoc "error" `Null
  |> upsert_assoc "observed_at"
       (`String (Masc_domain.iso8601_of_unix_seconds observed_at_unix))
  |> upsert_assoc "observed_at_unix" (`Float observed_at_unix)
  |> fun fields -> `Assoc fields

let cached_playground_repo_entries_result playground_abs =
  let cache_path = Filename.concat playground_abs ".playground_state.json" in
  if not (safe_file_exists cache_path)
  then Ok []
  else
    try
      match Yojson.Safe.from_file cache_path with
      | `Assoc _ as json ->
        (match Json_util.assoc_member_opt "repos" json with
         | Some (`List repos) -> Ok repos
         | _ -> Error "playground state must contain a repos array")
      | _ -> Error "playground state must be a JSON object"
    with
    | Sys_error msg -> Error msg
    | Yojson.Json_error msg -> Error msg

let filesystem_playground_repo_names_result playground_abs =
  let repos_dir = Filename.concat playground_abs "repos" in
  if not (safe_file_exists repos_dir)
  then Ok []
  else if not (safe_is_dir repos_dir)
  then Error (Printf.sprintf "playground repos path is not a directory: %s" repos_dir)
  else
    try
      Sys.readdir repos_dir
      |> Array.to_list
      |> List.filter (fun name ->
        let repo_path = Filename.concat repos_dir name in
        safe_is_dir repo_path
        && safe_file_exists (Filename.concat repo_path ".git"))
      |> List.sort String.compare
      |> fun names -> Ok names
    with
    | Sys_error msg -> Error msg

type playground_repos_observation =
  { repos : Yojson.Safe.t list
  ; error : string option
  }

let playground_repos_observation
      ~timeout_sec
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
  =
  let playground_abs =
    Keeper_sandbox.host_root_abs_of_meta ~config meta
    |> normalize_path
  in
  let repos_dir = Filename.concat playground_abs "repos" in
  let policy =
    playground_repo_policy ~base_path:config.base_path ~keeper_name:meta.name
  in
  let repo_catalog = Repo_store.load_all ~base_path:config.base_path in
  let cached_entries, cache_error =
    match cached_playground_repo_entries_result playground_abs with
    | Ok entries -> entries, None
    | Error msg -> [], Some ("playground cache: " ^ msg)
  in
  let cached, invalid_cache_errors =
    cached_entries
    |> List.fold_left
         (fun (repos, errors) repo ->
            match repo_name_of_json repo with
            | Some name -> (name, repo) :: repos, errors
            | None -> repos, "playground cache contains an invalid repo entry" :: errors)
         ([], [])
    |> fun (repos, errors) -> List.rev repos, List.rev errors
  in
  let cached =
    cached
    |> List.map (fun (name, repo) ->
          let repo_path = Filename.concat repos_dir name in
          if safe_is_dir repo_path
             && safe_file_exists (Filename.concat repo_path ".git")
          then
            (enrich_playground_repo_from_git ~timeout_sec ~repo_name:name
              ~repo_path repo
            |> with_playground_repo_policy_fields ~base_path:config.base_path
                 ~repo_catalog ~keeper_id:meta.name policy ~repo_name:name
                 ~repo_path)
          else
            playground_repo_entry_json ~source:"cache" ~repo_name:name repo
            |> with_playground_repo_policy_fields ~base_path:config.base_path
                 ~repo_catalog ~keeper_id:meta.name policy ~repo_name:name
                 ~repo_path)
  in
  let cached_names = List.filter_map repo_name_of_json cached in
  let filesystem_names, filesystem_error =
    match filesystem_playground_repo_names_result playground_abs with
    | Ok names -> names, None
    | Error msg -> [], Some ("playground filesystem: " ^ msg)
  in
  let fs_entries =
    filesystem_names
    |> List.filter (fun name -> not (List.mem name cached_names))
    |> List.map (fun name ->
      playground_repo_entry_json ~source:"filesystem" ~repo_name:name
        (`Assoc [])
      |> with_playground_repo_policy_fields ~base_path:config.base_path
           ~repo_catalog ~keeper_id:meta.name policy ~repo_name:name
           ~repo_path:(Filename.concat repos_dir name))
  in
  { repos = cached @ fs_entries
  ; error =
      combine_errors
        [ cache_error
        ; (match invalid_cache_errors with
           | [] -> None
           | errors -> Some (String.concat "; " errors))
        ; filesystem_error
        ]
  }

let playground_repos_json ~timeout_sec ~config ~meta =
  let observation = playground_repos_observation ~timeout_sec ~config ~meta in
  (match observation.error with
   | None -> ()
   | Some msg -> Log.Misc.warn "[KeeperSandboxControl] %s" msg);
  `List observation.repos

let preflight_status ~timeout_sec =
  Keeper_sandbox_runtime.docker_preflight ~timeout_sec ()

let preflight_ok = Option.map (fun (status : Keeper_sandbox_runtime.docker_preflight) -> status.ok)

type container_mode =
  | Local_host
  | Docker_idle
  | Docker_active
  | Docker_listing_failed

let container_mode_to_string = function
  | Local_host -> "local"
  | Docker_idle -> "docker_idle"
  | Docker_active -> "docker_active"
  | Docker_listing_failed -> "docker_listing_failed"
;;

let container_mode (meta : keeper_meta) ~container_error containers =
  match meta.sandbox_profile, container_error, containers with
  | Local, _, _ -> Local_host
  | Docker, Some _, _ -> Docker_listing_failed
  | Docker, None, [] -> Docker_idle
  | Docker, None, _ :: _ -> Docker_active
;;

type execution_boundary =
  | Host_process
  | Docker_container

type filesystem_boundary =
  | Host_filesystem_tool_policy
  | Explicit_container_mounts

type network_boundary =
  | Host_network_namespace
  | Isolated_network_namespace

type credential_boundary =
  | Managed_home_projection
  | Ephemeral_container_projection

let execution_boundary_to_string = function
  | Host_process -> "host_process"
  | Docker_container -> "docker_container"
;;

let filesystem_boundary_to_string = function
  | Host_filesystem_tool_policy -> "host_filesystem_tool_policy"
  | Explicit_container_mounts -> "explicit_container_mounts"
;;

let network_boundary_to_string = function
  | Host_network_namespace -> "host_network_namespace"
  | Isolated_network_namespace -> "isolated_network_namespace"
;;

let credential_boundary_to_string = function
  | Managed_home_projection -> "managed_home_projection"
  | Ephemeral_container_projection -> "ephemeral_container_projection"
;;

let nullable_bool = function
  | Some value -> `Bool value
  | None -> `Null
;;

let security_boundary_json (meta : keeper_meta) =
  let
    execution_boundary,
    filesystem_boundary,
    network_boundary,
    credential_boundary,
    rootfs_read_only,
    cap_drop_all,
    no_new_privileges
    =
    match meta.sandbox_profile, meta.network_mode with
    | Local, Network_host ->
      ( Host_process
      , Host_filesystem_tool_policy
      , Host_network_namespace
      , Managed_home_projection
      , None
      , None
      , None )
    | Local, Network_none ->
      invalid_arg
        "invalid keeper sandbox policy: local execution cannot enforce network_mode=none"
    | Docker, network_mode ->
      let network_boundary =
        match network_mode with
        | Network_none -> Isolated_network_namespace
        | Network_host -> Host_network_namespace
      in
      ( Docker_container
      , Explicit_container_mounts
      , network_boundary
      , Ephemeral_container_projection
      , Some (not (Env_config_sandbox.Hardening.relax_fs ()))
      , Some true
      , Some true )
  in
  `Assoc
    [ "execution_boundary", `String (execution_boundary_to_string execution_boundary)
    ; "filesystem_boundary", `String (filesystem_boundary_to_string filesystem_boundary)
    ; "network_boundary", `String (network_boundary_to_string network_boundary)
    ; "credential_boundary", `String (credential_boundary_to_string credential_boundary)
    ; "rootfs_read_only", nullable_bool rootfs_read_only
    ; "cap_drop_all", nullable_bool cap_drop_all
    ; "no_new_privileges", nullable_bool no_new_privileges
    ]
;;

let why_no_container (meta : keeper_meta) ~preflight containers =
  if meta.sandbox_profile = Local then
    Some "sandbox_profile=local"
  else if containers <> [] then
    None
  else
    match preflight_ok preflight with
    | Some false -> Some "docker_preflight_failed"
    | _ ->
        Some
          "docker_idle; turn and one-shot containers are created on demand and removed after execution"

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
          "No lifecycle action is required. Run a sandboxed Keeper turn or tool call to create an on-demand container."

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
        preflight_status ~timeout_sec
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
  let playground_repos, playground_repos_error =
    if include_playground_repos
    then
      let observation =
        playground_repos_observation ~timeout_sec ~config ~meta
      in
      `List observation.repos, observation.error
    else `List [], None
  in
  `Assoc
    [
      ("keeper", `String meta.name);
      ("sandbox_profile", `String (sandbox_profile_to_string meta.sandbox_profile));
      ("configured_network_mode", `String (network_mode_to_string meta.network_mode));
      ( "effective_mode",
        `String
          (container_mode meta ~container_error containers
           |> container_mode_to_string) );
      ("security_boundary", security_boundary_json meta);
      ("container_count", `Int (List.length containers));
      ("containers",
       `List (List.map Keeper_sandbox_runtime.live_container_to_yojson containers));
      ( "preflight",
        if verbose
        then
          Json_util.option_to_yojson
            Keeper_sandbox_runtime.docker_preflight_to_yojson
            preflight
        else `Null );
      ("container_error", Json_util.string_opt_to_json container_error);
      ("why_no_container", Json_util.string_opt_to_json why_no_container);
      ("recommendation", Json_util.string_opt_to_json recommendation);
      ( "playground_repos",
        playground_repos );
      ( "playground_repos_source",
        `String
          (if include_playground_repos then "live"
           else "skipped_dashboard_hot_path") );
      ("playground_repos_error", nullable_string playground_repos_error);
      ("identity", identity_json meta);
    ]
