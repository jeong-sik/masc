open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_alerting
module StringMap = Set_util.StringMap
module StringSet = Set_util.StringSet

let count_context_tokens (ctx : working_context) = Keeper_context_runtime.token_count ctx

let has_json_field name fields =
  List.exists (fun (field, _) -> String.equal field name) fields
;;

let error_json ?(fields = []) (message : string) =
  Yojson.Safe.to_string (`Assoc (("error", `String message) :: fields))
;;

let tool_result_error_json (tr : Tool_result.result) =
  let fields =
    match Tool_result.failure_class tr with
    | None -> []
    | Some cls ->
      [ "failure_class", `String (Tool_result.tool_failure_class_to_string cls) ]
  in
  match Tool_result.structured_payload_of_message (Tool_result.message tr) with
  | Some (`Assoc payload_fields) ->
    let payload_fields =
      List.fold_left
        (fun acc (key, value) ->
           if has_json_field key acc then acc else acc @ [ key, value ])
        payload_fields
        fields
    in
    Yojson.Safe.to_string (`Assoc payload_fields)
  | Some _
  | None ->
    error_json ~fields (Tool_result.message tr)
;;

let tool_result_or_error (tr : Tool_result.result) =
  let ok = Tool_result.is_success tr in
  let msg = Tool_result.message tr in
  if ok then msg else tool_result_error_json tr
;;

(** Phase B PR-5 precursor (2026-04-28): the action mapping itself,
    parameterised by the typed [Keeper_failure_circuit_breaker.error_class].
    Callers that already hold a typed class (sandbox / shell typed
    error paths in Phase B PR-5) call this directly and skip the
    string → class round-trip entirely.  String-only callers go through
    [actionable_path_error] below, which classifies once and delegates. *)
let actionable_path_action_for_class
      ~(playground : string)
      ~(raw_path : string)
      (cls : Keeper_failure_circuit_breaker.error_class)
  : string
  =
  if String.length raw_path = 0
  then "Provide a path. Your playground root is " ^ playground
  else (
    match cls with
    | Path_not_found ->
      Printf.sprintf
        "File does not exist under %s. Inspect visible paths with the currently \
         exposed read/listing tools before retrying. Use keeper task/context tools \
         for .masc state."
        playground
    | Path_not_allowed ->
      Printf.sprintf
        "Path is outside your allowed roots. Stay inside %s or use keeper_context_status \
         to see allowed paths."
        playground
    | Cwd_not_directory ->
      "The cwd is not a directory. Omit cwd to use your default playground root, or \
       create/repair the repo checkout first and then retry with cwd=repos/<repo>."
    | Shell_exit_nonzero | Other ->
      Printf.sprintf "Check the path. Your playground: %s" playground)
;;

let safe_is_dir path =
  try Sys.file_exists path && Sys.is_directory path with
  | Sys_error _ -> false
;;

let safe_file_exists path =
  try Sys.file_exists path with
  | Sys_error _ -> false
;;

let visible_sandbox_repositories ~config meta =
  let repos_dir =
    Filename.concat (Keeper_sandbox.host_root_abs_of_meta ~config meta) "repos"
  in
  if not (safe_is_dir repos_dir)
  then []
  else
    try
      Sys.readdir repos_dir
      |> Array.to_list
      |> List.sort String.compare
      |> List.filter (fun entry ->
        let candidate = Filename.concat repos_dir entry in
        safe_is_dir candidate && safe_file_exists (Filename.concat candidate ".git"))
    with
    | Sys_error _ -> []
;;

let visible_repo_hint = function
  | [ repo ] -> Some repo
  | _ -> None
;;

let repos_json repos =
  `List (List.map (fun repo -> `String ("repos/" ^ repo)) repos)
;;

let repo_identity_tokens (repo : Repo_manager_types.repository) =
  repo.id :: repo.name :: repo.aliases
  |> List.map String.trim
  |> List.filter (fun token -> not (String.equal token ""))
  |> List.sort_uniq String.compare
;;

let repo_identity_paths repo =
  repo_identity_tokens repo |> List.map (fun token -> "repos/" ^ token)
;;

let requested_repo_of_raw_path raw_path =
  match String.split_on_char '/' (String.trim raw_path) with
  | "repos" :: repo :: _ when not (String.equal repo "") -> Some repo
  | _ -> None
;;

type registered_repository_projection_snapshot =
  { repositories : Repo_manager_types.repository list
  ; registered_repos : string list
  ; registered_repo_paths : string list
  ; registered_repo_aliases : Yojson.Safe.t list
  }

let registered_repository_projection ~base_path =
  match Repo_store.load_all ~base_path with
  | Ok repos ->
    let registered_repos =
      repos
      |> List.map (fun (repo : Repo_manager_types.repository) -> repo.id)
      |> List.sort_uniq String.compare
    in
    let registered_repo_paths =
      repos
      |> List.concat_map repo_identity_paths
      |> List.sort_uniq String.compare
    in
    let registered_repo_aliases =
      repos
      |> List.concat_map (fun (repo : Repo_manager_types.repository) ->
        repo.aliases
        |> List.map String.trim
        |> List.filter (fun alias -> not (String.equal alias ""))
        |> List.sort_uniq String.compare
        |> List.map (fun alias ->
          `Assoc
            [ "repo_id", `String repo.id
            ; "alias", `String alias
            ; "path", `String ("repos/" ^ alias)
            ; "canonical_path", `String ("repos/" ^ repo.id)
            ]))
    in
    Ok
      { repositories = repos
      ; registered_repos
      ; registered_repo_paths
      ; registered_repo_aliases
      }
  | Error msg -> Error msg
;;

let requested_repo_registration_fields ~repositories ~raw_path =
  match requested_repo_of_raw_path raw_path with
  | None -> []
  | Some requested_repo ->
    let matching_repo =
      List.find_opt
        (fun repo ->
           List.exists (String.equal requested_repo) (repo_identity_tokens repo))
        repositories
    in
    let requested_repo_fields =
      [ "requested_repo", `String requested_repo
      ; "requested_repo_path", `String ("repos/" ^ requested_repo)
      ]
    in
    (match matching_repo with
     | None ->
       requested_repo_fields
       @ [ "requested_repo_registered", `Bool false ]
     | Some repo ->
       requested_repo_fields
       @ [ "requested_repo_registered", `Bool true
         ; "canonical_repo_id", `String repo.id
         ; "canonical_repo_path", `String ("repos/" ^ repo.id)
         ])
;;

(** Actionable error for path resolution failures.
    Follows Samchon harness pattern: field-level diagnostics with
    exact path, expected constraint, and concrete next action.
    Claude Code pattern: validateInput returns actionable guidance.

    Phase A F4 (2026-04-27): the error → action mapping dispatches on
    the typed [Keeper_failure_circuit_breaker.error_class] instead of a
    parallel [contains_substring] ladder.  String-matching collapses
    from two sites (here + circuit_breaker) to one (the SSOT).

    Phase B PR-5 precursor (2026-04-28): the action mapping is now
    parameterised on the typed class via
    [actionable_path_action_for_class].  This keeps the string-input
    entry point (for callers that only have a raw error message) but
    exposes the typed mapping so Phase B PR-5 can route typed callers
    directly without a redundant classify pass. *)
let actionable_path_error
      ~deterministic_reason
      ~(op : string)
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(raw_path : string)
      ~(error : string)
  =
  let playground = Keeper_sandbox.allowed_root_rel_of_meta ~meta in
  let cls = Keeper_failure_circuit_breaker.classify_error error in
  let action = actionable_path_action_for_class ~playground ~raw_path cls in
  let base_path = Keeper_alerting_path.project_root_of_config config in
  let available_repos = visible_sandbox_repositories ~config meta in
  let repo_hint = visible_repo_hint available_repos in
  let registered_repo_fields, requested_repo_registration_fields, registered_repo_next_action =
    match registered_repository_projection ~base_path with
    | Ok
        { repositories
        ; registered_repos
        ; registered_repo_paths
        ; registered_repo_aliases
        } ->
      ( [ "registered_repos", repos_json registered_repos
        ; ( "registered_repo_paths"
          , `List (List.map (fun path -> `String path) registered_repo_paths) )
        ; "registered_repo_aliases", `List registered_repo_aliases
        ]
      , requested_repo_registration_fields ~repositories ~raw_path
      , "Retry with a registered repos/<id> path, or register the visible \
         checkout name as an explicit repository alias before retrying." )
    | Error msg ->
      ( [ "registered_repos_error", `String msg ]
      , []
      , "Repository catalog could not be loaded; repair \
         .masc/config/repositories.toml before retrying repo alias hints." )
  in
  let deterministic_retry_fields =
    match deterministic_reason with
    | None -> []
    | Some reason -> Keeper_tool_deterministic_error.deterministic_retry_fields reason
  in
  Yojson.Safe.to_string
    (`Assoc
       ([ "ok", `Bool false
        ; "op", `String op
        ; "error", `String error
        ; "tried", `String raw_path
        ; "your_playground", `String playground
        ; "available_repos", repos_json available_repos
        ; ( "path_resolution"
          , `Assoc
              [ "same_path_retry_will_fail", `Bool true
              ; ( "repo_cwd_hint"
                , Json_util.string_opt_to_json
                    (Option.map (fun repo -> "repos/" ^ repo) repo_hint) )
              ; ( "basis"
                , `String
                    "Grep resolves path against the keeper sandbox, then validates \
                     repository identity against repositories.toml id/name/aliases." )
              ; ( "requested_repo_registration"
                , `Assoc requested_repo_registration_fields )
              ; ( "next_action"
                , `String registered_repo_next_action )
              ] )
        ; "action", `String action
        ]
        @ registered_repo_fields
        @ deterministic_retry_fields))
;;

let file_not_found_prefix = "File not found:"

let dirname_opt path =
  let trimmed = String.trim path in
  if trimmed = ""
  then None
  else (
    match String.rindex_opt trimmed '/' with
    | None -> Some "."
    | Some 0 -> Some "/"
    | Some idx -> Some (String.sub trimmed 0 idx))
;;

let split_repo_relative raw =
  match String.split_on_char '/' raw with
  | "repos" :: repo :: rest when repo <> "" ->
    let rel = String.concat "/" rest in
    Some (repo, rel)
  | _ -> None
;;

let missing_file_recovery_examples ~(raw_path : string option) ~(repo_hint : string option) =
  match raw_path with
  | None -> `Assoc []
  | Some raw ->
    let parent = dirname_opt raw |> Option.value ~default:"." in
    let parent_path_hint =
      match split_repo_relative raw with
      | Some (repo, rel) ->
        let repo_parent = dirname_opt rel |> Option.value ~default:"." in
        Filename.concat ("repos/" ^ repo) repo_parent
      | None ->
        (match repo_hint with
         | Some repo -> Filename.concat ("repos/" ^ repo) parent
         | None -> parent)
    in
    `Assoc
      [ "basename_hint", `String (Filename.basename raw)
      ; "parent_path_hint", `String parent_path_hint
      ; ( "instruction"
        , `String
            "Use the currently exposed read/listing tools and their visible schema to \
             confirm this parent path before retrying." )
      ]
;;

let missing_file_error_json
      ~(raw_path : string option)
      ~(cwd : string option)
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(target : string)
      ~(fallback_dir : string)
      ~(error : string)
  =
  ignore fallback_dir;
  (* #10349: do NOT echo directory entries back to the LLM.  When keeper
     identity drifts, the resolved parent may belong to a sibling sandbox,
     and listing its contents leaks its directory layout (oracle leak).
     The generic error string already contains the path that was tried,
     which is sufficient for the LLM to self-correct. *)
  let playground = Keeper_sandbox.allowed_root_rel_of_meta ~meta in
  let available_repos = visible_sandbox_repositories ~config meta in
  let repo_hint = visible_repo_hint available_repos in
  let next_action =
    match raw_path, repo_hint with
    | Some path, Some repo when Option.is_none (split_repo_relative path) ->
      Printf.sprintf
        "A single sandbox repo is available. Retry with cwd=\"repos/%s\" and \
         file_path=%S, or use file_path=%S. Inspect visible paths with the \
         currently exposed read/listing tools first when the exact path is unclear."
        repo
        path
        (Filename.concat ("repos/" ^ repo) path)
    | _ ->
      "For repo-relative files, pass cwd=\"repos/<repo>\" with \
       file_path=\"lib/...\", or pass file_path=\"repos/<repo>/lib/...\". \
       Inspect visible paths with the currently exposed read/listing tools first \
       when the exact path is unclear."
  in
  Yojson.Safe.to_string
    (`Assoc
        [ "ok", `Bool false
        ; "error", `String error
        ; "path", `String target
        ; "your_playground", `String playground
        ; "available_repos", repos_json available_repos
        ; "input_file_path", Json_util.string_opt_to_json raw_path
        ; ( "path_resolution"
          , `Assoc
              [ "implicit_cwd", `Bool false
              ; "explicit_cwd_supported", `Bool true
              ; "cwd", Json_util.string_opt_to_json cwd
              ; ( "repo_cwd_hint"
                , Json_util.string_opt_to_json
                    (Option.map (fun repo -> "repos/" ^ repo) repo_hint) )
              ; "same_path_retry_will_fail", `Bool true
              ; ( "basis"
                , `String
                    "Read resolves file_path against explicit cwd when cwd is provided; \
                     otherwise it resolves against the keeper sandbox or explicit \
                     allowed_paths. It does not inherit Execute cwd implicitly." )
              ; "next_action", `String next_action
              ; ( "retry_policy"
                , `String
                    "Do not retry Read with the same file_path until a visible \
                     read/listing tool confirms the file exists." )
              ; "recovery_examples", missing_file_recovery_examples ~raw_path ~repo_hint
              ] )
        ])
;;

let find_registry_meta ~(keeper_name : string) ~(source_layer : string)
  : Keeper_meta_contract.keeper_meta option
  =
  match Keeper_registry_lookup.find_by_name keeper_name with
  | None ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string PathResolverIdentityMismatch)
      ~labels:[ "source_layer", source_layer; "field", "registry_missing" ]
      ();
    None
  | Some entry ->
    if not (String.equal entry.meta.name keeper_name) then
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string PathResolverIdentityMismatch)
        ~labels:[ "source_layer", source_layer; "field", "name_mismatch" ]
        ();
    Some entry.meta
;;

let with_registry_meta ~(keeper_name : string) ~(source_layer : string) f =
  match find_registry_meta ~keeper_name ~source_layer with
  | None ->
    error_json (Printf.sprintf "keeper not found in registry: %s" keeper_name)
  | Some meta -> f meta
;;

let assoc_override_string (key : string) (value : string) = function
  | `Assoc fields ->
    let kept_fields = List.filter (fun (k, _) -> k <> key) fields in
    `Assoc ((key, `String value) :: kept_fields)
  | other -> other
;;

let keeper_effective_allowed_paths ~(meta : keeper_meta) =
  Keeper_alerting_path.effective_allowed_paths ~meta
;;

let keeper_effective_write_allowed_paths ~(meta : keeper_meta) =
  Keeper_alerting_path.effective_write_allowed_paths ~meta
;;

let keeper_playground_root ~(config : Workspace.config) ~(meta : keeper_meta) =
  ignore (Keeper_alerting_path.ensure_sandbox_bundle ~config ~meta);
  Keeper_sandbox.host_root_abs_of_meta ~config meta
;;

let keeper_default_write_root ~(config : Workspace.config) ~(meta : keeper_meta) =
  keeper_playground_root ~config ~meta
;;

let keeper_default_read_root ~(config : Workspace.config) ~(meta : keeper_meta) =
  keeper_playground_root ~config ~meta
;;

(* #23469 (task-1733): observation partitions must interpret keeper-relative
   tool paths against the same root the file tools resolve against — the
   keeper's playground sandbox — never the server base path. Unlike
   [keeper_playground_root] this is a pure path computation: the observation
   write path is fire-and-forget and must not run the
   [ensure_sandbox_bundle] directory side effect. Anchored at the normalised
   project root so a [.masc]-suffixed [config.base_path] cannot double up,
   and stripped of the bundle-root trailing slash so downstream structural
   parsers never see an empty path segment. *)
let keeper_observation_sandbox_root
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
  =
  Filename.concat
    (Keeper_alerting_path.project_root_of_config config)
    (Keeper_alerting_path.strip_trailing_slashes
       (Keeper_sandbox.host_root_rel_of_meta ~meta))
;;

let keeper_observation_host_path_of_visible_path
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      raw_path
  =
  if Filename.is_relative raw_path
     || meta.sandbox_profile <> Keeper_types_profile_sandbox.Docker
  then raw_path
  else (
    let strip = Keeper_alerting_path.strip_trailing_slashes in
    let normalize path = Keeper_alerting_path.normalize_path_for_check_stripped path in
    let container_root = Keeper_sandbox.container_root meta.name |> normalize in
    let raw_norm = normalize raw_path in
    let host_root = keeper_observation_sandbox_root ~config ~meta |> strip in
    if String.equal raw_norm container_root
    then host_root
    else if String.starts_with ~prefix:(container_root ^ "/") raw_norm
    then (
      let suffix =
        String.sub
          raw_norm
          (String.length container_root + 1)
          (String.length raw_norm - String.length container_root - 1)
      in
      Filename.concat host_root suffix)
    else raw_path)
;;

let safe_file_exists path =
  try Fs_compat.file_exists path with
  | Sys_error _ -> false
;;

let safe_is_dir path =
  try Fs_compat.file_exists path && Sys.is_directory path with
  | Sys_error _ -> false
;;

let keeper_sandbox_repo_names ~(config : Workspace.config) ~(meta : keeper_meta) =
  let repos_dir = Filename.concat (keeper_playground_root ~config ~meta) "repos" in
  if not (safe_is_dir repos_dir)
  then []
  else
    Sys.readdir repos_dir
    |> Array.to_list
    |> List.sort String.compare
    |> List.filter (fun entry ->
      let candidate = Filename.concat repos_dir entry in
      safe_is_dir candidate && safe_file_exists (Filename.concat candidate ".git"))
;;

let keeper_playground_relative_root ~(meta : keeper_meta) =
  Keeper_sandbox.allowed_root_rel_of_meta ~meta
  |> Keeper_alerting_path.strip_trailing_slashes
;;

let keeper_playground_relative_path ~(meta : keeper_meta) rel =
  Filename.concat (keeper_playground_relative_root ~meta) rel
;;

let relative_path_targets_allowed_root ~(meta : keeper_meta) (raw : string) =
  let boundary prefix =
    let prefix = Keeper_alerting_path.strip_trailing_slashes prefix in
    prefix <> ""
    && (String.equal raw prefix || String.starts_with ~prefix:(prefix ^ "/") raw)
  in
  keeper_effective_allowed_paths ~meta
  |> List.filter Filename.is_relative
  |> List.exists boundary
;;

let is_playground_lane_relative_path (raw : string) =
  List.exists
    (fun prefix ->
       String.equal raw prefix || String.starts_with ~prefix:(prefix ^ "/") raw)
    [ "mind"; "repos" ]
;;

let repo_relative_path_candidate ~(meta : keeper_meta) (raw : string) =
  let first_segment =
    match String.split_on_char '/' raw with
    | segment :: _ -> segment
    | [] -> raw
  in
  Filename.is_relative raw
  && raw <> ""
  && String.contains raw '/'
  && (not (is_playground_lane_relative_path raw))
  && (not (relative_path_targets_allowed_root ~meta raw))
  && not
       (List.mem
          first_segment
          [ Common.masc_dirname; "playground"; "workspace"; ".worktrees" ])
;;

let rewrite_single_repo_relative_path
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      (raw : string)
  =
  if not (repo_relative_path_candidate ~meta raw)
  then Ok None
  else (
    let first_segment =
      match String.split_on_char '/' raw with
      | segment :: _ -> segment
      | [] -> raw
    in
    match keeper_sandbox_repo_names ~config ~meta with
    | repo_names when List.mem first_segment repo_names ->
      let sandbox_relative = Filename.concat "repos" raw in
      let rewritten = keeper_playground_relative_path ~meta sandbox_relative in
      Log.Keeper.debug "playground_relative: explicit repo rewrite %S → %S" raw rewritten;
      Ok (Some rewritten)
    | [ repo_name ] ->
      let sandbox_relative = Filename.concat ("repos/" ^ repo_name) raw in
      let rewritten = keeper_playground_relative_path ~meta sandbox_relative in
      Log.Keeper.debug "playground_relative: single-repo rewrite %S → %S" raw rewritten;
      Ok (Some rewritten)
    | [] -> Ok None
    | repo_names ->
      Error
        (Printf.sprintf
           "ambiguous_repo_relative_path: %s (sandbox repos: [%s]). Use repos/<repo>/%s \
            or <repo>/%s explicitly."
           raw
           (String.concat ", " repo_names)
           raw
           raw))
;;

let host_path_of_own_container_path
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      (raw : string)
  =
  if Filename.is_relative raw || meta.sandbox_profile <> Keeper_types_profile_sandbox.Docker
  then None
  else (
    let strip = Keeper_alerting_path.strip_trailing_slashes in
    let normalize path = Keeper_alerting_path.normalize_path_for_check_stripped path in
    let container_root = Keeper_sandbox.container_root meta.name |> normalize in
    let raw_norm = normalize raw in
    let host_root = keeper_playground_root ~config ~meta |> strip in
    if String.equal raw_norm container_root
    then Some host_root
    else if String.starts_with ~prefix:(container_root ^ "/") raw_norm
    then (
      let suffix =
        String.sub
          raw_norm
          (String.length container_root + 1)
          (String.length raw_norm - String.length container_root - 1)
      in
      Some (Filename.concat host_root suffix))
    else None)
;;

let project_relative_host_path ~(config : Workspace.config) (path : string) =
  let root =
    Keeper_alerting_path.project_root_of_config config
    |> Keeper_alerting_path.normalize_path_for_check_stripped
  in
  let path_norm = Keeper_alerting_path.normalize_path_for_check_stripped path in
  if String.equal path_norm root then Some "."
  else if String.starts_with ~prefix:(root ^ "/") path_norm then
    Some
      (String.sub path_norm (String.length root + 1)
         (String.length path_norm - String.length root - 1))
  else None
;;

type playground_projection =
  { projected_path : string
  ; projected_from_visible : bool
  }

let raw_projection projected_path = { projected_path; projected_from_visible = false }
let visible_projection projected_path = { projected_path; projected_from_visible = true }

(* Bare filenames and canonical sandbox lanes default to the keeper sandbox,
   but rooted-looking relative paths (for example
   "workspace/..." or "lib/...") keep project-root/boundary semantics. *)
let playground_relative_projection_unless_allowed_root
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      (raw : string)
  : (playground_projection, string) result
  =
  let trimmed = String.trim raw in
  let mapped_from_container, trimmed =
    match host_path_of_own_container_path ~config ~meta trimmed with
    | Some host_path ->
      Log.Keeper.debug
        "playground_relative: mapped container path %S → %S"
        trimmed
        host_path;
      true, host_path
    | None -> false, trimmed
  in
  let trimmed =
    if mapped_from_container
    then Option.value ~default:trimmed (project_relative_host_path ~config trimmed)
    else trimmed
  in
  match rewrite_single_repo_relative_path ~config ~meta trimmed with
  | Error _ as err -> err
  | Ok (Some rewritten) -> Ok (visible_projection rewritten)
  | Ok None ->
    if
      trimmed = ""
      || (not (Filename.is_relative trimmed))
      || (String.contains trimmed '/' && not (is_playground_lane_relative_path trimmed))
      || relative_path_targets_allowed_root ~meta trimmed
    then Ok (if mapped_from_container then visible_projection trimmed else raw_projection trimmed)
    else (
      Ok (visible_projection (keeper_playground_relative_path ~meta trimmed)))
;;

let playground_relative_unless_allowed_root ~config ~meta raw =
  match playground_relative_projection_unless_allowed_root ~config ~meta raw with
  | Error _ as err -> err
  | Ok projection -> Ok projection.projected_path
;;

type projected_allowed_path =
  { candidate : string
  ; search_roots : string list
  }

let user_message_error (rej : Keeper_alerting_path.keeper_path_rejection) =
  Keeper_alerting_path.rejection_to_telemetry rej;
  Error (Keeper_alerting_path.rejection_to_user_message rej)
;;

let resolve_projected_allowed_path
      ~(config : Workspace.config)
      ~(allowed_paths : string list)
      ~(raw_for_error : string)
      ~(projected_path : string)
  : (projected_allowed_path, string) result
  =
  let root = Keeper_alerting_path.project_root_of_config config in
  let candidate =
    if Filename.is_relative projected_path
    then Filename.concat root projected_path
    else projected_path
  in
  let root_norm =
    Keeper_alerting_path.normalize_path_for_check root
    |> Keeper_alerting_path.strip_trailing_slashes
  in
  let target_norm =
    Keeper_alerting_path.normalize_path_for_check candidate
    |> Keeper_alerting_path.strip_trailing_slashes
  in
  let within_root =
    target_norm = root_norm || String.starts_with ~prefix:(root_norm ^ "/") target_norm
  in
  if not within_root
  then user_message_error (Keeper_alerting_path.Outside_project_root { raw = raw_for_error })
  else if Keeper_alerting_path.is_masc_internal_state_norm ~root_norm ~target_norm
  then
    user_message_error
      (Keeper_alerting_path.Task_state_file_path_blocked { raw = raw_for_error })
  else (
    let allowed_norms =
      if allowed_paths = []
      then []
      else
        allowed_paths
        |> List.filter_map (Keeper_alerting_path.normalize_allowed_path_for_check ~root:root_norm)
    in
    if allowed_paths <> [] && allowed_norms = []
    then
      user_message_error
        (Keeper_alerting_path.Allowed_paths_normalized_empty
           { count = List.length allowed_paths })
    else (
      let within_allowed =
        allowed_norms = []
        || Keeper_alerting_path.is_within_allowed_norms ~target_norm allowed_norms
      in
      if not within_allowed
      then user_message_error (Keeper_alerting_path.Outside_sandbox { raw = raw_for_error })
      else (
        let search_roots = if allowed_norms = [] then [ root_norm ] else allowed_norms in
        Ok { candidate; search_roots })))
;;

let resolve_projected_read_path
      ~(config : Workspace.config)
      ~(allowed_paths : string list)
      ~(raw_for_error : string)
      ~(projected_path : string)
  : (string, string) result
  =
  match
    resolve_projected_allowed_path
      ~config
      ~allowed_paths
      ~raw_for_error
      ~projected_path
  with
  | Error _ as err -> err
  | Ok { candidate; search_roots } ->
    if
      Keeper_alerting_path.path_exists candidate
      || Keeper_alerting_path.allows_missing_leaf_read
           ~raw:raw_for_error
           ~candidate
    then Ok candidate
    else (
      match
        Keeper_alerting_path.maybe_resolve_missing_relative_read_path
          ~roots:search_roots
          ~raw_path:raw_for_error
      with
      | Ok (Some resolved) -> Ok resolved
      | Ok None ->
        user_message_error
          (Keeper_alerting_path.Not_found_relative { raw = raw_for_error })
      | Error e -> user_message_error e)
;;

let resolve_projected_write_path
      ~(config : Workspace.config)
      ~(allowed_paths : string list)
      ~(raw_for_error : string)
      ~(projected_path : string)
  : (string, string) result
  =
  match
    resolve_projected_allowed_path
      ~config
      ~allowed_paths
      ~raw_for_error
      ~projected_path
  with
  | Error _ as err -> err
  | Ok { candidate; _ } -> Ok candidate
;;

let resolve_projected_keeper_read_path
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(raw_for_error : string)
      ~(projected_path : string)
  =
  resolve_projected_read_path
    ~config
    ~allowed_paths:(keeper_effective_allowed_paths ~meta)
    ~raw_for_error
    ~projected_path
;;

let resolve_keeper_path
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(raw_path : string)
  =
  match playground_relative_projection_unless_allowed_root ~config ~meta raw_path with
  | Error e -> Error e
  | Ok { projected_path; projected_from_visible = true } ->
    resolve_projected_write_path
      ~config
      ~allowed_paths:(keeper_effective_write_allowed_paths ~meta)
      ~raw_for_error:raw_path
      ~projected_path
  | Ok { projected_path; projected_from_visible = false } ->
    match Keeper_alerting_path.resolve_keeper_target_path
      ~config
      ~allowed_paths:(keeper_effective_write_allowed_paths ~meta)
      ~raw_path:projected_path
    with
    | Error rej -> Error (Keeper_alerting_path.rejection_to_user_message rej)
    | Ok p -> Ok p
;;

let resolve_keeper_read_path
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(raw_path : string)
  =
  match playground_relative_projection_unless_allowed_root ~config ~meta raw_path with
  | Error e -> Error e
  | Ok { projected_path; projected_from_visible = true } ->
    resolve_projected_read_path
      ~config
      ~allowed_paths:(keeper_effective_allowed_paths ~meta)
      ~raw_for_error:raw_path
      ~projected_path
  | Ok { projected_path; projected_from_visible = false } ->
    match Keeper_alerting_path.resolve_keeper_read_path
      ~config
      ~allowed_paths:(keeper_effective_allowed_paths ~meta)
      ~raw_path:projected_path
    with
    | Error rej -> Error (Keeper_alerting_path.rejection_to_user_message rej)
    | Ok p -> Ok p
;;

let keeper_agent_sender ~(meta : keeper_meta) = meta.agent_name

let shell_readonly_limit args =
  max 1 (min 200 (Safe_ops.json_int ~default:40 "limit" args))
;;

let shell_readonly_cat_max_bytes args =
  max 256 (min 100000 (Safe_ops.json_int ~default:4000 "max_bytes" args))
;;

let lines_to_json ?(limit = max_int) ?(max_bytes = 32_000) (text : string) : Yojson.Safe.t
  =
  let all_nonempty =
    String.split_on_char '\n' text
    |> List.filter (fun line -> line <> "")
  in
  let total = List.length all_nonempty in
  let truncated_by_limit, limit_overflow =
    if total > limit
    then take limit all_nonempty, total - limit
    else all_nonempty, 0
  in
  (* Byte-budget: accumulate lines until max_bytes is reached.
     This prevents 200 long lines from producing 500KB+ JSON arrays
     that stall the LLM context window. *)
  let rec collect acc bytes_used = function
    | [] -> List.rev acc, 0
    | line :: rest ->
      let line_len =
        String.length line + 4
        (* JSON overhead: quotes, comma *)
      in
      if bytes_used + line_len > max_bytes && acc <> []
      then List.rev acc, List.length rest + 1
      else collect (`String line :: acc) (bytes_used + line_len) rest
  in
  let kept, byte_overflow = collect [] 0 truncated_by_limit in
  let omitted = limit_overflow + byte_overflow in
  if omitted > 0
  then
    `List
      (kept
       @ [ `String
             (Printf.sprintf
                "...[%d more lines omitted — narrow your search pattern or add \
                 --glob/--type filter]"
                omitted)
         ])
  else `List kept
;;

let keeper_text_fallback_json ~(agent_id : string) ~(message : string) =
  let voice = Voice_bridge.get_voice_for_agent agent_id in
  `Assoc
    [ "status", `String "text_fallback"
    ; "agent_id", `String agent_id
    ; "voice", `String voice
    ; "message_preview", `String (short_preview ~max_len:50 message)
    ]
;;

let tag_dispatch_fn
  : (config:Workspace.config
     -> agent_name:string
     -> tag:Tool_dispatch.module_tag
     -> name:string
     -> args:Yojson.Safe.t
     -> Tool_result.result option)
      ref
  =
  ref (fun ~config:_ ~agent_name:_ ~tag:_ ~name:_ ~args:_ -> None)
;;

let descriptor_active_names active_name_set descriptor =
  let descriptor_names =
    Keeper_tool_descriptor.keeper_model_names descriptor
  in
  List.filter (fun name -> StringSet.mem name active_name_set) descriptor_names
;;

let descriptor_discovery_json active_name_set descriptor =
  `Assoc
    (Keeper_tool_descriptor.discovery_fields descriptor
     @ [ ( "active_names"
         , Json_util.json_string_list
             (descriptor_active_names active_name_set descriptor) )
       ])
;;

let descriptor_category (descriptor : Keeper_tool_descriptor.t) =
  match descriptor.runtime_handler with
  | Keeper_tool_descriptor.Tool_execute -> "execute"
  | Keeper_tool_descriptor.Tool_search_files -> "search_files"
  | Keeper_tool_descriptor.Tool_read_file
  | Keeper_tool_descriptor.Tool_edit_file
  | Keeper_tool_descriptor.Tool_write_file -> "fs"
  | Keeper_tool_descriptor.Board_tool_dispatch
  | Keeper_tool_descriptor.Tool_masc_board_dispatch -> "board"
  | Keeper_tool_descriptor.Tool_voice_dispatch -> "voice"
  | Keeper_tool_descriptor.Tool_task_dispatch
  | Keeper_tool_descriptor.Tool_masc_task_dispatch
  | Keeper_tool_descriptor.Tool_masc_plan_dispatch
  | Keeper_tool_descriptor.Tool_masc_run_dispatch
  | Keeper_tool_descriptor.Tool_masc_agent_dispatch
  | Keeper_tool_descriptor.Tool_masc_workspace_dispatch -> "workspace"
  | Keeper_tool_descriptor.Tool_surface_read
  | Keeper_tool_descriptor.Tool_surface_post
  | Keeper_tool_descriptor.Tool_person_note_set -> "surface"
  | Keeper_tool_descriptor.Tool_memory_search
  | Keeper_tool_descriptor.Tool_memory_write
  | Keeper_tool_descriptor.Tool_library_search
  | Keeper_tool_descriptor.Tool_library_read -> "memory"
  | Keeper_tool_descriptor.Tool_time_now
  | Keeper_tool_descriptor.Tool_tools_list
  | Keeper_tool_descriptor.Tool_tool_search
  | Keeper_tool_descriptor.Tool_context_status
  | Keeper_tool_descriptor.Tool_ide_annotate
  | Keeper_tool_descriptor.Tool_masc_misc_dispatch
  | Keeper_tool_descriptor.Tool_masc_control_dispatch
  | Keeper_tool_descriptor.Tool_masc_agent_timeline_dispatch
  | Keeper_tool_descriptor.Tool_masc_schedule_dispatch
  | Keeper_tool_descriptor.Tool_masc_keeper_dispatch
  | Keeper_tool_descriptor.Tool_masc_surface_audit
  | Keeper_tool_descriptor.Tool_masc_fusion_dispatch
  | Keeper_tool_descriptor.Tool_masc_fusion_status
  | Keeper_tool_descriptor.Tool_analyze_image -> "meta"
;;

let keeper_tools_list_json ~(meta : keeper_meta) =
  let names =
    Keeper_tool_policy.keeper_model_tool_schemas meta
    |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
  in
  let active_name_set =
    List.fold_left
      (fun acc name -> StringSet.add name acc)
      StringSet.empty
      names
  in
  let categorize name =
    match Keeper_tool_descriptor_resolution.descriptor_for_tool_name name with
    | Some descriptor -> descriptor_category descriptor
    | None -> "registry"
  in
  let map =
    List.fold_left
      (fun acc n ->
         let cat = categorize n in
         let list = StringMap.find_opt cat acc |> Option.value ~default:[] in
         StringMap.add cat (n :: list) acc)
      StringMap.empty
      names
  in
  let assoc =
    StringMap.fold
      (fun cat list acc -> (cat, `List (List.map (fun s -> `String s) list)) :: acc)
      map
      []
  in
  let descriptor_surface =
    Keeper_tool_descriptor_resolution.descriptors_for_tool_names names
    |> List.map (descriptor_discovery_json active_name_set)
  in
  Yojson.Safe.to_string
    (`Assoc (assoc @ [ "descriptor_surface", `List descriptor_surface ]))
;;
