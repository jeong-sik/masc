(** Runtime-resolution and dashboard tools projections extracted from the
    dashboard HTTP facade. *)

open Dashboard_http_helpers

let opt_string_json = Server_dashboard_http_runtime_info_json.opt_string_json
let opt_bool_json = Server_dashboard_http_runtime_info_json.opt_bool_json
let opt_commit_equal = Server_dashboard_http_runtime_info_json.opt_commit_equal
let opt_int_json = Server_dashboard_http_runtime_info_json.opt_int_json

let deployment_state_json
      ~(build : Build_identity.t)
      ~server_repo_commit
      ~workspace_commit
      ~resolved_base_commit
      ~upstream_status
  ~source_mismatch
  =
  let binary_commit_known = Option.is_some build.binary_commit in
  let deployed_commit = build.binary_commit in
  let deployed_commit_source = build.binary_commit_source in
  let deployed_matches_server_repo =
    opt_commit_equal deployed_commit server_repo_commit
  in
  let deployed_matches_upstream =
    opt_commit_equal deployed_commit upstream_status.Server_git_probe.upstream_head_commit
  in
  let deployed_matches_runtime_repo =
    opt_commit_equal deployed_commit build.repo_head_commit
  in
  let runtime_repo_matches_server_repo =
    opt_commit_equal build.repo_head_commit server_repo_commit
  in
  let runtime_repo_matches_upstream =
    opt_commit_equal build.repo_head_commit upstream_status.Server_git_probe.upstream_head_commit
  in
  let built_matches_upstream =
    opt_commit_equal build.binary_commit upstream_status.Server_git_probe.upstream_head_commit
  in
  let built_matches_runtime_repo =
    opt_commit_equal build.binary_commit build.repo_head_commit
  in
  let server_repo_behind_upstream =
    match upstream_status.behind_count with
      | Some count -> count > 0
      | None -> false
  in
  let binary_diverged =
    match built_matches_upstream, built_matches_runtime_repo with
    | Some false, _ | _, Some false -> true
    | _ -> false
  in
  let runtime_repo_snapshot_diverged =
    match runtime_repo_matches_server_repo, runtime_repo_matches_upstream with
    | Some false, _ | _, Some false -> true
    | _ -> false
  in
  let deployment_diverged =
    server_repo_behind_upstream
    || binary_diverged
    || runtime_repo_snapshot_diverged
  in
  let status =
    if source_mismatch || deployment_diverged
    then "diverged"
    else if not binary_commit_known
    then "unproven"
    else (
      match built_matches_runtime_repo with
      | Some true -> "current"
      | Some false -> "diverged"
      | None -> "unknown")
  in
  `Assoc
    [ "schema", `String "masc.runtime_deployment_state.v1"
    ; "status", `String status
    ; "operator_action_required", `Bool (String.equal status "diverged")
    ; "binary_commit_known", `Bool binary_commit_known
    ; ( "upstream"
      , `Assoc
          [ "branch", opt_string_json upstream_status.branch
          ; "ref", opt_string_json upstream_status.upstream_ref
          ; "head_commit", opt_string_json upstream_status.Server_git_probe.upstream_head_commit
          ; "ahead_count", opt_int_json upstream_status.ahead_count
          ; "behind_count", opt_int_json upstream_status.behind_count
          ; "source", `String "local_tracking_ref"
          ] )
    ; ( "merged"
      , `Assoc
          [ "commit", opt_string_json server_repo_commit
          ; "source", `String "server_repo_head"
          ] )
    ; ( "built"
      , `Assoc
          [ "commit", opt_string_json build.binary_commit
          ; "source", opt_string_json build.binary_commit_source
          ; ( "proof"
            , `String
                (if binary_commit_known
                 then "build_env_commit"
                 else "missing_build_env_commit") )
          ] )
    ; ( "deployed"
      , `Assoc
          [ "commit", opt_string_json deployed_commit
          ; "source", opt_string_json deployed_commit_source
          ; ( "proof"
            , `String
                (if binary_commit_known
                 then "build_env_commit"
                 else "missing_binary_commit") )
          ; "started_at", `String build.started_at
          ; "executable_path", `String build.executable_path
          ] )
    ; ( "runtime_repo"
      , `Assoc
          [ "head_commit", opt_string_json build.repo_head_commit
          ; "head_commit_source", opt_string_json build.repo_head_commit_source
          ] )
    ; ( "workspace"
      , `Assoc
          [ "head_commit", opt_string_json workspace_commit
          ; "resolved_base_head_commit", opt_string_json resolved_base_commit
          ] )
    ; ( "checks"
      , `Assoc
          [ "deployed_matches_merged", opt_bool_json deployed_matches_server_repo
          ; "deployed_matches_upstream", opt_bool_json deployed_matches_upstream
          ; "deployed_matches_runtime_repo", opt_bool_json deployed_matches_runtime_repo
          ; "runtime_repo_matches_merged", opt_bool_json runtime_repo_matches_server_repo
          ; "runtime_repo_matches_upstream", opt_bool_json runtime_repo_matches_upstream
          ; "built_matches_upstream", opt_bool_json built_matches_upstream
          ; "built_matches_runtime_repo", opt_bool_json built_matches_runtime_repo
          ; "server_repo_behind_upstream", `Bool server_repo_behind_upstream
          ; "source_mismatch", `Bool source_mismatch
          ] )
    ]
;;

let path_item_json ~source path =
  `Assoc
    [ "path", `String path
    ; "exists", `Bool (String.trim path <> "" && Sys.file_exists path)
    ; "source", `String source
    ]
;;

let normalized_path_opt path =
  match String_util.trim_to_option path with
  | None -> None
  | Some path ->
    let normalized =
      if Sys.file_exists path
      then (
        try Unix.realpath path with
        | Unix.Unix_error _ -> path)
      else path
    in
    Some normalized
;;

let normalized_path_segments path =
  let normalized = Env_config_core.normalize_path_lexically path in
  if String.equal normalized "/" || String.equal normalized "."
  then []
  else normalized |> String.split_on_char '/' |> List.filter (fun segment -> segment <> "")
;;

let rec segment_prefix ~prefix path =
  match prefix, path with
  | [], _ -> true
  | _ :: _, [] -> false
  | p :: ps, x :: xs -> String.equal p x && segment_prefix ~prefix:ps xs
;;

let same_or_descendant_normalized_path path expected =
  match normalized_path_opt path, normalized_path_opt expected with
  | Some path, Some expected ->
    segment_prefix
      ~prefix:(normalized_path_segments expected)
      (normalized_path_segments path)
  | _ -> false
;;

let server_workspace_mismatch ~server_repo_path (config : Workspace.config) =
  not
    (same_or_descendant_normalized_path server_repo_path config.workspace_path
     || same_or_descendant_normalized_path server_repo_path config.base_path)
;;

let server_workspace_mismatch_for_tests ~server_repo_path (config : Workspace.config) =
  match normalized_path_opt server_repo_path with
  | Some server_repo_path -> server_workspace_mismatch ~server_repo_path config
  | None -> false
;;

let shutdown_signal_of_message message =
  if String_util.contains_substring message "Received SIGTERM"
  then Some "SIGTERM"
  else if String_util.contains_substring message "Received SIGINT"
  then Some "SIGINT"
  else None
;;

let runtime_diagnostics_json () =
  let entries = Log.Ring.recent ~limit:200 ~order:`Newest_first () in
  let diagnostics =
    entries
    |> List.filter_map (fun (entry : Log.Ring.entry) ->
      let message = entry.message in
      match shutdown_signal_of_message message with
      | Some signal ->
        Some
          (`Assoc
              [ "ts", `String entry.ts
              ; "kind", `String "external_signal"
              ; "signal", `String signal
              ; "message", `String message
              ])
      | None
        when String_util.contains_substring
               message "repairing state and rewriting canonical JSON" ->
        Some
          (`Assoc
              [ "ts", `String entry.ts
              ; "kind", `String "state_repair"
              ; "message", `String message
              ])
      | None
        when String_util.contains_substring message "invalid agent JSON"
             || String_util.contains_substring message "repaired agent JSON"
             || String_util.contains_substring
                  message "parse error: Types_core.agent.last_seen" ->
        Some
          (`Assoc
              [ "ts", `String entry.ts
              ; "kind", `String "agent_state"
              ; "message", `String message
              ])
      | None -> None)
    |> Server_dashboard_http_runtime_info_json.take 8
  in
  let count kind =
    List.fold_left
      (fun acc json ->
         match Json_util.assoc_member_opt "kind" json with
         | Some (`String value) when String.equal value kind -> acc + 1
         | _ -> acc)
      0
      diagnostics
  in
  `List diagnostics, count "external_signal", count "state_repair", count "agent_state"
;;



let runtime_endpoint_url_of_transport = function
  | Runtime_schema.Http url -> Some url
  | Runtime_schema.Cli _ -> None
;;

let runtime_transport_string = function
  | Runtime_schema.Http _ -> "http"
  | Runtime_schema.Cli _ -> "cli"
;;

let runtime_http_transport_is_loopback url =
  Uri.of_string url |> Uri.host |> Masc_network_defaults.is_loopback_host_opt
;;

let runtime_kind_of_transport = function
  | Runtime_schema.Cli _ -> "cli"
  | Runtime_schema.Http url when runtime_http_transport_is_loopback url -> "local"
  | Runtime_schema.Http _ -> "http"
;;

let runtime_dashboard_kind_of_runtime_kind = function
  | "local" -> "local"
  | "cli" -> "cli"
  | _ -> "cloud"
;;

let runtime_auth_kind_of_credential = function
  | None -> "none"
  | Some (Runtime_schema.Env key) -> "env:" ^ key
  | Some (Runtime_schema.File path) -> "file:" ^ path
  | Some (Runtime_schema.Inline _) -> "inline"
;;

let runtime_default_runtime_id () =
  Runtime.get_default_runtime () |> Option.map (fun (rt : Runtime.t) -> rt.id)
;;

let runtime_inventory_entry_json ~default_id (rt : Runtime.t) =
  let runtime_kind = runtime_kind_of_transport rt.provider.transport in
  let models = [ rt.model.api_name ] in
  `Assoc
    [ "provider", `String rt.id
    ; "runtime_id", `String rt.id
    ; "provider_id", `String rt.provider.id
    ; "provider_display_name", `String rt.provider.display_name
    ; "model_id", `String rt.model.id
    ; "model_api_name", `String rt.model.api_name
    ; "protocol", `String rt.provider.protocol
    ; "transport", `String (runtime_transport_string rt.provider.transport)
    ; "kind", `String (runtime_dashboard_kind_of_runtime_kind runtime_kind)
    ; "runtime_kind", `String runtime_kind
    ; "auth_kind", `String (runtime_auth_kind_of_credential rt.provider.credentials)
    ; "status", `String "configured"
    ; "available", `Bool true
    ; "is_default_runtime", `Bool (Option.equal String.equal default_id (Some rt.id))
    ; "max_context", `Int rt.model.max_context
    ; "tools_support", `Bool rt.model.tools_support
    ; "thinking_support", `Bool rt.model.thinking_support
    ; "streaming", `Bool rt.model.streaming
    ; "model_count", `Int (List.length models)
    ; "models", Json_util.json_string_list models
    ; "source", `String Server_runtime_probe.runtime_inventory_source
    ; "endpoint_url", Json_util.string_opt_to_json (runtime_endpoint_url_of_transport rt.provider.transport)
    ; "note", `Null
    ]
;;

let runtime_unique_count values =
  values |> List.sort_uniq String.compare |> List.length
;;

let runtime_assignment_governance_json ~default_id =
  let assignments =
    Runtime.keeper_assignments ()
    |> List.sort (fun (left, _) (right, _) -> String.compare left right)
  in
  let assignment_count = List.length assignments in
  let assigned_runtime_ids = List.map snd assignments in
  let assigned_runtimes = List.sort_uniq String.compare assigned_runtime_ids in
  let assigned_runtime_count = List.length assigned_runtimes in
  let default_assignment_count =
    match default_id with
    | None -> 0
    | Some default_id ->
      assignments
      |> List.filter (fun (_, runtime_id) -> String.equal runtime_id default_id)
      |> List.length
  in
  let librarian_runtime_id = Runtime.librarian_runtime_id () in
  let single_runtime_pin = assignment_count > 1 && assigned_runtime_count = 1 in
  let assignments_match_default =
    assignment_count > 0 && default_assignment_count = assignment_count
  in
  let add_if condition warning warnings =
    if condition then warning :: warnings else warnings
  in
  let warnings =
    []
    |> add_if (assignment_count > 0) "explicit_assignments_present"
    |> add_if single_runtime_pin "single_runtime_assignment_pin"
    |> add_if assignments_match_default "assignments_match_default_runtime"
    |> add_if (Option.is_some librarian_runtime_id) "librarian_runtime_override"
    |> List.rev
  in
  let status =
    if warnings = []
    then "ok"
    else if single_runtime_pin || assignments_match_default || Option.is_some librarian_runtime_id
    then "degraded"
    else "watch"
  in
  `Assoc
    [ "schema", `String "masc.runtime_assignment_governance.v1"
    ; "source", `String Server_runtime_probe.runtime_inventory_source
    ; "status", `String status
    ; "degraded", `Bool (String.equal status "degraded")
    ; "operator_action_required", `Bool (warnings <> [])
    ; "blast_radius",
      `String
        (if assignment_count = 0
         then "default_runtime_only"
         else if single_runtime_pin
         then "single_runtime_assignment_pin"
         else "mixed_runtime_assignments")
    ; "assignment_count", `Int assignment_count
    ; "assigned_runtime_count", `Int assigned_runtime_count
    ; "default_assignment_count", `Int default_assignment_count
    ; "default_runtime_id", Json_util.string_opt_to_json default_id
    ; "librarian_runtime_id", Json_util.string_opt_to_json librarian_runtime_id
    ; "warnings", Json_util.json_string_list warnings
    ; "assigned_runtimes", Json_util.json_string_list assigned_runtimes
    ; ( "assignments"
      , `List
          (List.map
             (fun (keeper_name, runtime_id) ->
                `Assoc
                  [ "keeper", `String keeper_name
                  ; "runtime_id", `String runtime_id
                  ; ( "matches_default"
                    , `Bool (Option.equal String.equal default_id (Some runtime_id)) )
                  ])
             assignments) )
    ]
;;

let governance_hitl_json () =
  (* doc-03 P0#1 acceptance: surface whether human-in-the-loop approval is active
     and why, so an operator can confirm the fail-closed default at runtime instead
     of inferring it from the environment. [Env_config_core.disable_hitl] reads
     MASC_DISABLE_HITL with a fail-closed [~default:false] — HITL stays enabled
     unless an operator explicitly disables it; the thresholds mirror
     [Governance_pipeline] so the "why" travels with the "whether". *)
  let enabled = not (Env_config_core.disable_hitl ()) in
  let threshold_json resolver =
    match resolver "production" with
    | Some level -> `String (Governance_pipeline.risk_level_to_string level)
    | None -> `Null
  in
  `Assoc
    [ "schema", `String "masc.governance_hitl.v1"
    ; "enabled", `Bool enabled
    ; "disable_env_key", `String Env_config_core.disable_hitl_env_key
    ; "default_when_unset", `String "enabled"
    ; ( "production_confirm_threshold"
      , threshold_json Governance_pipeline.confirm_threshold )
    ; ( "keeper_production_confirm_threshold"
      , threshold_json Governance_pipeline.keeper_confirm_threshold )
    ; ( "reason"
      , `String
          (if enabled
           then "human approval required for high/critical actions (fail-closed default)"
           else
             "human approval gates disabled via " ^ Env_config_core.disable_hitl_env_key) )
    ]
;;

let runtime_inventory_json () =
  let runtimes = Runtime.get_runtimes () in
  let default_id = runtime_default_runtime_id () in
  let kind_of_runtime (rt : Runtime.t) =
    runtime_kind_of_transport rt.provider.transport
    |> runtime_dashboard_kind_of_runtime_kind
  in
  let count_models kind =
    runtimes
    |> List.filter (fun rt -> String.equal (kind_of_runtime rt) kind)
    |> List.length
  in
  let provider_ids = List.map (fun (rt : Runtime.t) -> rt.provider.id) runtimes in
  `Assoc
    [ "updated_at", `String (Masc_domain.now_iso ())
    ; "source", `String Server_runtime_probe.runtime_inventory_source
    ; "config_path", Json_util.string_opt_to_json (Runtime.config_path ())
    ; ( "summary"
      , `Assoc
          [ "providers", `Int (runtime_unique_count provider_ids)
          ; "runtimes", `Int (List.length runtimes)
          ; "local_models", `Int (count_models "local")
          ; "cloud_models", `Int (count_models "cloud")
          ; "cli_models", `Int (count_models "cli")
          ; "default_runtime_id", Json_util.string_opt_to_json default_id
          ] )
    ; "assignment_governance", runtime_assignment_governance_json ~default_id
    ; "providers", `List (List.map (runtime_inventory_entry_json ~default_id) runtimes)
    ]
;;

let runtime_resolution_json (config : Workspace.config) =
  let build = Build_identity.current () in
  let runtime_commit = build.binary_commit in
  let runtime_commit_known = Option.is_some runtime_commit in
  let server_repo_path = Build_identity.repo_root () in
  let server_repo_commit = Option.bind server_repo_path Server_git_probe.git_rev_parse_short in
  let upstream_status =
    Option.bind server_repo_path Server_git_probe.git_upstream_status
    |> Option.value ~default:Server_git_probe.empty_git_upstream_status
    (* NDT-OK: dashboard rendering fallback *)
  in
  let workspace_commit = Server_git_probe.git_rev_parse_short config.workspace_path in
  let resolved_base_commit = Server_git_probe.git_rev_parse_short config.base_path in
  let base_path_input =
    (* SSOT: Env_config_core.base_path_source_opt prefers
       MASC_BASE_PATH_INPUT over MASC_BASE_PATH, preserving an
       operator's raw "<base>/.masc" input.
       Host_config.base_path_raw only reads MASC_BASE_PATH and strips
       a preserved ".masc" suffix when both env vars are set.
       RFC-0085 PR-9 keeps the raw helper private, so use
       base_path_source_opt's value component.
       Test: "runtime base_path preserves raw input"
       (test/test_dashboard_http_core.ml:260). *)
    Env_config_core.base_path_source_opt ()
    |> Option.map snd
    |> Option.value ~default:config.workspace_path
  in
  let prompt_markdown_dir =
    Prompt_registry.get_markdown_dir ()
    |> Option.value ~default:(Config_dir_resolver.prompts_dir ())
  in
  let expected_prompt_dir = Config_dir_resolver.prompts_dir () in
  let prompt_dir_mismatch =
    prompt_markdown_dir <> ""
    && not (String.equal prompt_markdown_dir expected_prompt_dir)
  in
  let source_mismatch =
    match runtime_commit, server_repo_commit, workspace_commit with
    | Some runtime, Some server_repo, _ -> not (String.equal runtime server_repo)
    | Some runtime, None, Some workspace -> not (String.equal runtime workspace)
    | _ -> false
  in
  let server_workspace_mismatch =
    match Option.bind server_repo_path normalized_path_opt with
    | None -> false
    | Some server_repo_path -> server_workspace_mismatch ~server_repo_path config
  in
  let diagnostics, signal_count, repair_count, agent_issue_count =
    runtime_diagnostics_json ()
  in
  let add_source_mismatch_warning acc =
    if source_mismatch
    then (
      (* When [runtime_commit] is [None] the warning previously
         rendered as "Runtime build commit (unknown) differs from ...".
         The *reason* the binary commit is unknown was emitted as a
         separate [add_binary_commit_unknown_warning] further down,
         forcing the dashboard reader to cross-reference two warnings
         to understand a single mismatch.  Inline the reason in the
         marker itself so the warning is self-contained. *)
      let runtime =
        match runtime_commit with
        | Some commit -> commit
        | None ->
            "<unknown — Build_identity.binary_commit not populated by build \
             pipeline>"
      in
      let source_label, source_commit =
        match server_repo_commit with
        | Some commit -> "server repo HEAD", commit
        | None ->
            (* [workspace_commit] is [git_rev_parse_short config.workspace_path].
               [None] means [git rev-parse] failed at that path; naming the
               path gives the operator the worktree to check. *)
            let commit =
              match workspace_commit with
              | Some c -> c
              | None ->
                  Printf.sprintf
                    "<unknown — git rev-parse failed at workspace_path=%s>"
                    config.workspace_path
            in
            "workspace HEAD", commit
      in
      Printf.sprintf
        "Runtime build commit (%s) differs from %s (%s). Rebuild/restart from \
         the intended server worktree."
        runtime
        source_label
        source_commit
      :: acc)
    else acc
  in
  let add_binary_commit_unknown_warning acc =
    if (not runtime_commit_known) && Option.is_some build.repo_head_commit
    then
      "Runtime binary commit is unknown; runtime_repo_head_commit is only the \
       checkout HEAD snapshot captured by the running process and must not be \
       treated as binary/deploy proof."
      :: acc
    else acc
  in
  let add_runtime_repo_snapshot_drift_warning acc =
    if runtime_commit_known
    then acc
    else
      match build.repo_head_commit, server_repo_commit with
      | Some runtime_head, Some server_head when not (String.equal runtime_head server_head)
        ->
        Printf.sprintf
          "Runtime source snapshot (%s) differs from server repo HEAD (%s), \
           but the binary commit is unknown. Rebuild/restart before trusting \
           runtime identity."
          runtime_head
          server_head
        :: acc
      | _ -> acc
  in
  let add_upstream_drift_warning acc =
    match upstream_status.behind_count, upstream_status.Server_git_probe.upstream_head_commit with
    | Some behind, Some upstream when behind > 0 ->
      let deployed =
        match build.binary_commit, build.repo_head_commit with
        | Some commit, _ -> "binary " ^ commit
        | None, Some commit -> "runtime source snapshot " ^ commit
        | None, None -> "unknown binary commit"
      in
      let branch =
        Option.value ~default:"detached" upstream_status.branch
      in
      let upstream_ref =
        Option.value ~default:"upstream" upstream_status.upstream_ref
      in
      Printf.sprintf
        "Server source branch %s is behind %s by %d commit(s); running runtime \
         identity (%s) differs from upstream %s. Fetch/build/restart from \
         current main before trusting runtime identity."
        branch
        upstream_ref
        behind
        deployed
        upstream
      :: acc
    | _ -> acc
  in
  let add_server_workspace_mismatch_warning acc =
    if server_workspace_mismatch
    then (
      (* [server_workspace_mismatch] is only true when [server_repo_path] is
         [Some _] (see the [Option.bind] guard above), so the [None] branch is
         dead at runtime — but [Option.value ~default:"unknown server repo"]
         silently buried that invariant.  Use the structured form instead:
         the dead branch documents *why* it cannot fire. *)
      let server_repo =
        match server_repo_path with
        | Some repo -> repo
        | None ->
            (* Unreachable: [server_workspace_mismatch] requires
               [Option.bind server_repo_path normalized_path_opt = Some _],
               which in turn requires [server_repo_path = Some _]. *)
            "<unreachable — server_workspace_mismatch implies server_repo_path \
             = Some _>"
      in
      Printf.sprintf
        "Server binary checkout (%s) differs from dashboard workspace/base \
         path (%s / %s). This can be intentional; verify the running worktree \
         when dashboard data looks stale."
        server_repo
        config.workspace_path
        config.base_path
      :: acc)
    else acc
  in
  let add_prompt_dir_mismatch_warning acc =
    if prompt_dir_mismatch
    then
      Printf.sprintf
        "Prompt markdown dir (%s) differs from resolved config root (%s)."
        prompt_markdown_dir
        expected_prompt_dir
      :: acc
    else acc
  in
  let add_signal_warning acc =
    if signal_count > 0
    then
      Printf.sprintf
        "Recent external shutdown signals detected in server logs (%d). Ephemeral \
         agents will not auto-rejoin after these restarts."
        signal_count
      :: acc
    else acc
  in
  let add_repair_warning acc =
    if repair_count > 0
    then Printf.sprintf "Recent workspace-state repair events detected (%d)." repair_count :: acc
    else acc
  in
  let add_agent_issue_warning acc =
    if agent_issue_count > 0
    then
      Printf.sprintf "Recent agent-state compatibility warnings detected (%d)."
        agent_issue_count
      :: acc
    else acc
  in
  let warnings =
    []
    |> add_source_mismatch_warning
    |> add_binary_commit_unknown_warning
    |> add_runtime_repo_snapshot_drift_warning
    |> add_upstream_drift_warning
    |> add_server_workspace_mismatch_warning
    |> add_prompt_dir_mismatch_warning
    |> add_signal_warning
    |> add_repair_warning
    |> add_agent_issue_warning
    |> List.rev
  in
  let status = if warnings = [] then "ready" else "warn" in
  `Assoc
    ( [ "status", `String status
      ; "warnings", `List (List.map (fun warning -> `String warning) warnings)
      ; "base_path", path_item_json ~source:"input" base_path_input
      ; "workspace_path", path_item_json ~source:"workspace" config.workspace_path
      ; "resolved_base_path", path_item_json ~source:"resolved_base" config.base_path
      ; "data_root", path_item_json ~source:"runtime_data" (Workspace.masc_root_dir config)
      ; "prompt_markdown_dir", path_item_json ~source:"prompt_registry" prompt_markdown_dir
      ; ( "server_repo_path"
        , match server_repo_path with
          | Some path -> path_item_json ~source:"server_binary" path
          | None ->
            `Assoc
              [ "path", `Null; "exists", `Bool false; "source", `String "server_binary" ] )
      ; ( "server_repo_git_commit"
        , Option.fold ~none:`Null ~some:(fun value -> `String value) server_repo_commit )
      ; ( "runtime_binary_git_commit"
        , Option.fold ~none:`Null ~some:(fun value -> `String value) runtime_commit )
      ; ( "runtime_repo_head_git_commit"
        , Option.fold ~none:`Null ~some:(fun value -> `String value) build.repo_head_commit )
      ; ( "workspace_git_commit"
        , Option.fold ~none:`Null ~some:(fun value -> `String value) workspace_commit )
      ; ( "resolved_base_git_commit"
        , Option.fold ~none:`Null ~some:(fun value -> `String value) resolved_base_commit )
      ; "source_mismatch", `Bool source_mismatch
      ; "server_workspace_mismatch", `Bool server_workspace_mismatch
      ; "diagnostics", diagnostics
      ; ("keeper_runtime", Keeper_runtime_resolved.(current () |> to_yojson))
      ; "build", Build_identity.to_yojson build
      ; ( "deployment_state"
        , deployment_state_json ~build ~server_repo_commit ~workspace_commit
            ~resolved_base_commit ~upstream_status ~source_mismatch )
      ; "governance_hitl", governance_hitl_json ()
      ]
      @ Server_routes_http_runtime.keeper_fleet_runtime_resolution_fields () )
;;

let light_runtime_resolution_json (config : Workspace.config) =
  let build = Build_identity.current () in
  let base_path_input =
    Env_config_core.base_path_source_opt ()
    |> Option.map snd
    |> Option.value ~default:config.workspace_path
  in
  let prompt_markdown_dir =
    Prompt_registry.get_markdown_dir ()
    |> Option.value ~default:(Config_dir_resolver.prompts_dir ())
  in
  let server_repo_path = Build_identity.repo_root () in
  let server_workspace_mismatch =
    match Option.bind server_repo_path normalized_path_opt with
    | Some server_repo_path -> server_workspace_mismatch ~server_repo_path config
    | None -> false
  in
  let fleet_fields =
    Server_routes_http_runtime.keeper_fleet_runtime_resolution_light_fields ()
  in
  let fleet_safety =
    match List.assoc_opt "keeper_fleet_safety" fleet_fields with
    | Some ((`Assoc _) as json) -> Some json
    | _ -> None
  in
  let fleet_warning =
    match fleet_safety with
    | Some (`Assoc fields) ->
      let status =
        match List.assoc_opt "status" fields with
        | Some (`String status) -> status
        | _ -> "unknown"
      in
      let operator_action_required =
        match List.assoc_opt "operator_action_required" fields with
        | Some (`Bool value) -> value
        | _ -> false
      in
      (not (String.equal status "ok")) || operator_action_required
    | _ -> false
  in
  let warnings =
    []
    |> (fun acc ->
         if server_workspace_mismatch
         then
           "Server binary checkout differs from dashboard workspace/base path."
           :: acc
         else acc)
    |> (fun acc ->
         if fleet_warning
         then "Keeper fleet safety is degraded; inspect keeper_fleet_safety." :: acc
         else acc)
    |> List.rev
  in
  let status = if warnings = [] then "ready" else "warn" in
  `Assoc
    ( [ "status", `String status
      ; "warnings", `List (List.map (fun warning -> `String warning) warnings)
      ; "base_path", path_item_json ~source:"input" base_path_input
      ; "workspace_path", path_item_json ~source:"workspace" config.workspace_path
      ; "resolved_base_path", path_item_json ~source:"resolved_base" config.base_path
      ; "data_root", path_item_json ~source:"runtime_data" (Workspace.masc_root_dir config)
      ; "prompt_markdown_dir", path_item_json ~source:"prompt_registry" prompt_markdown_dir
      ; ( "server_repo_path"
        , match server_repo_path with
          | Some path -> path_item_json ~source:"server_binary" path
          | None ->
            `Assoc
              [ "path", `Null; "exists", `Bool false; "source", `String "server_binary" ] )
      ; "source_mismatch", `Bool false
      ; "server_workspace_mismatch", `Bool server_workspace_mismatch
      ; "diagnostics", `List []
      ; ("keeper_runtime", Keeper_runtime_resolved.(current () |> to_yojson))
      ; "build", Build_identity.to_yojson build
      ]
      @ fleet_fields )
;;

(* 30-second TTL chosen to match the dashboard frontend's natural refresh
   cadence (~3s polling × 10 = a fresh value at least every minute under
   sustained load).  Tool inventory + usage stats rarely change inside a
   30s window — the per-actor cache key isolates permission changes from
   leaking across actors.  Schedule FSM projection is attached outside this
   cache because due/pending state is operationally time-sensitive. *)
let dashboard_tools_cache_ttl_sec = 30.0

let dashboard_tools_cache_key ~base_path ~actor =
  Printf.sprintf "tools:%s:%s" base_path actor

let dashboard_actor_name = function
  | Some actor when String.trim actor <> "" -> actor
  | Some _ | None -> "dashboard"
;;

let dashboard_tools_warming_json ~actor =
  `Assoc
    [ "generated_at", `String (Masc_domain.now_iso ())
    ; "status", `String "warming"
    ; "is_warming", `Bool true
    ; "stale_reason", `String "warming"
    ; "config_resolution", `Assoc [ "status", `String "warming" ]
    ; "runtime_resolution", `Assoc [ "status", `String "warming" ]
    ; ( "tool_inventory"
      , `Assoc
          [ "count", `Int 0
          ; "tools", `List []
          ; "surface_summary", `Assoc []
          ] )
    ; ( "tool_usage"
      , `Assoc
          [ "total_calls", `Int 0
          ; "distinct_tools_called", `Int 0
          ; "top_20", `List []
          ; "never_called_count", `Int 0
          ; "dispatch_v2_enabled", `Bool false
          ; "registered_count", `Int 0
          ; "source", `String "dashboard_cache_warming"
          ; "health", `String "warming"
          ; "latest_age_s", `Null
          ; "entry_count", `Int 0
          ; "stale_reason", `String "warming"
          ; "actor", `String actor
          ] )
    ]
;;

let schedule_projection_request_limit = 20

let unix_iso_json ts = `String (Masc_domain.iso8601_of_unix_seconds ts)

let unix_iso_option_json = function
  | None -> `Null
  | Some ts -> unix_iso_json ts
;;

let schedule_status_count schedules status =
  List.fold_left
    (fun count (request : Schedule_domain.schedule_request) ->
      if request.status = status then count + 1 else count)
    0 schedules
;;

let schedule_counts_json schedules =
  `Assoc
    (List.map
       (fun status ->
         ( Schedule_domain.schedule_status_to_string status
         , `Int (schedule_status_count schedules status) ))
       Schedule_domain.all_schedule_statuses)
;;

let schedule_supported_payload_kinds =
  List.sort_uniq String.compare Server_schedule_consumers.supported_payload_kinds
;;

let schedule_payload_kind_supported kind =
  List.exists (String.equal kind) schedule_supported_payload_kinds
;;

let schedule_payload_support_status (request : Schedule_domain.schedule_request) =
  match Schedule_payload_projection.kind request with
  | Some kind when schedule_payload_kind_supported kind -> "supported"
  | Some _ -> "unsupported"
  | None -> "unknown"
;;

let schedule_payload_support_json schedules =
  let bump kind counts =
    let rec loop acc = function
      | [] -> List.rev ((kind, 1) :: acc)
      | (existing, count) :: rest when String.equal existing kind ->
        List.rev_append acc ((existing, count + 1) :: rest)
      | item :: rest -> loop (item :: acc) rest
    in
    loop [] counts
  in
  let unsupported_request_count, unknown_request_count, unsupported_kinds =
    List.fold_left
      (fun (unsupported_count, unknown_count, kind_counts)
        (request : Schedule_domain.schedule_request) ->
         match Schedule_payload_projection.kind request with
         | Some kind when schedule_payload_kind_supported kind ->
           unsupported_count, unknown_count, kind_counts
         | Some kind -> unsupported_count + 1, unknown_count, bump kind kind_counts
         | None -> unsupported_count, unknown_count + 1, kind_counts)
      (0, 0, []) schedules
  in
  let unsupported_kinds =
    unsupported_kinds
    |> List.sort (fun (left_kind, left_count) (right_kind, right_count) ->
      match compare right_count left_count with
      | 0 -> String.compare left_kind right_kind
      | order -> order)
    |> List.map (fun (kind, count) ->
      `Assoc [ "kind", `String kind; "count", `Int count ])
  in
  `Assoc
    [ ( "supported_kinds"
      , `List (List.map (fun kind -> `String kind) schedule_supported_payload_kinds) )
    ; "unsupported_request_count", `Int unsupported_request_count
    ; "unsupported_kinds", `List unsupported_kinds
    ; "unknown_request_count", `Int unknown_request_count
    ]
;;

let schedule_request_active (request : Schedule_domain.schedule_request) =
  not (Schedule_domain.is_terminal request.status)
;;

let schedule_effectively_expired ~now (request : Schedule_domain.schedule_request) =
  match request.status, request.expires_at with
  | (Schedule_domain.Pending_approval | Schedule_domain.Scheduled | Schedule_domain.Due), Some expires_at
    when expires_at <= now -> true
  | _ -> false
;;

let schedule_request_effectively_active ~now request =
  schedule_request_active request && not (schedule_effectively_expired ~now request)
;;

let schedule_effectively_due ~now (request : Schedule_domain.schedule_request) =
  (not (schedule_effectively_expired ~now request))
  &&
  match request.status with
  | Schedule_domain.Due -> true
  | Schedule_domain.Scheduled -> request.due_at <= now
  | Schedule_domain.Pending_approval
  | Schedule_domain.Running
  | Schedule_domain.Succeeded
  | Schedule_domain.Failed
  | Schedule_domain.Rejected
  | Schedule_domain.Cancelled
  | Schedule_domain.Expired ->
    false
;;

let schedule_due_candidate (request : Schedule_domain.schedule_request) =
  match request.status with
  | Schedule_domain.Pending_approval | Schedule_domain.Scheduled | Schedule_domain.Due ->
    true
  | Schedule_domain.Running
  | Schedule_domain.Succeeded
  | Schedule_domain.Failed
  | Schedule_domain.Rejected
  | Schedule_domain.Cancelled
  | Schedule_domain.Expired ->
    false
;;

let schedule_next_due_at ~now schedules =
  schedules
  |> List.filter (fun request ->
    schedule_due_candidate request && not (schedule_effectively_expired ~now request))
  |> List.fold_left
       (fun acc (request : Schedule_domain.schedule_request) ->
         match acc with
         | None -> Some request.due_at
         | Some ts -> Some (min ts request.due_at))
       None
;;

let schedule_blocked_approval ~now state (request : Schedule_domain.schedule_request) =
  (not (schedule_effectively_expired ~now request))
  && request.due_at <= now
  && Schedule_domain.requires_separate_human_grant request
  &&
  match request.status with
  | Schedule_domain.Pending_approval -> true
  | Schedule_domain.Due -> not (Schedule_store.has_current_approved_grant state request)
  | Schedule_domain.Scheduled
  | Schedule_domain.Running
  | Schedule_domain.Succeeded
  | Schedule_domain.Failed
  | Schedule_domain.Rejected
  | Schedule_domain.Cancelled
  | Schedule_domain.Expired ->
    false
;;

let schedule_effective_status ~now state (request : Schedule_domain.schedule_request) =
  if schedule_effectively_expired ~now request
  then "expired"
  else
    match request.status with
    | Schedule_domain.Pending_approval when request.due_at <= now -> "blocked_approval"
    | Pending_approval -> "pending_approval"
    | Scheduled when request.due_at <= now -> "due"
    | Scheduled -> "scheduled"
    | Due when schedule_blocked_approval ~now state request -> "blocked_approval"
    | Due -> "ready"
    | Running -> "running"
    | Succeeded -> "succeeded"
    | Failed -> "failed"
    | Rejected -> "rejected"
    | Cancelled -> "cancelled"
    | Expired -> "expired"
;;

let schedule_execution_readiness ~now state (request : Schedule_domain.schedule_request) =
  if schedule_effectively_expired ~now request
  then Schedule_projection.Expired
  else if Schedule_domain.is_terminal request.status
  then Schedule_projection.Terminal
  else if request.status = Schedule_domain.Running
  then Schedule_projection.Running
  else if schedule_blocked_approval ~now state request
  then Schedule_projection.Blocked_approval
  else if Schedule_store.has_current_approved_grant state request
  then Schedule_projection.Approved
  else
    match request.status with
    | Schedule_domain.Pending_approval -> Schedule_projection.Awaiting_approval
    | Schedule_domain.Scheduled when request.due_at <= now ->
      Schedule_projection.Due_pending_refresh
    | Schedule_domain.Scheduled -> Schedule_projection.Scheduled
    | Schedule_domain.Due -> Schedule_projection.Ready
    | Schedule_domain.Running -> Schedule_projection.Running
    | Schedule_domain.Succeeded
    | Schedule_domain.Failed
    | Schedule_domain.Rejected
    | Schedule_domain.Cancelled
    | Schedule_domain.Expired ->
      Schedule_projection.Terminal
;;

let schedule_operator_action readiness =
  match Schedule_projection.operator_action_for_execution_readiness readiness with
  | Some action -> `String action
  | None -> `Null
;;

let tool_projection_surfaces_for tool_name =
  let surfaces = ref [] in
  let add_surface surface =
    if not (List.exists (String.equal surface) !surfaces)
    then surfaces := surface :: !surfaces
  in
  if Tool_catalog.is_public_mcp tool_name then add_surface "public_mcp";
  Capability_registry.all_projection_seeds_from Config.raw_all_tool_schemas
  |> List.iter (fun (seed : Capability_registry.capability_seed) ->
    let surface = Capability_registry.surface_to_string seed.projection.surface in
    if
      (not (String.equal surface "public_mcp"))
      && (String.equal seed.projection.tool_name tool_name
          || String.equal seed.projection.backend_tool_name tool_name)
    then add_surface surface);
  List.sort String.compare !surfaces
;;

let schedule_keeper_next_tool_status_json = function
  | None -> `Null
  | Some tool_name ->
    let registered_schema =
      List.exists
        (fun (schema : Masc_domain.tool_schema) -> String.equal schema.name tool_name)
        Config.raw_all_tool_schemas
    in
    let dispatch_registered = Option.is_some (Tool_dispatch.lookup_tag tool_name) in
    let metadata = Tool_catalog.metadata tool_name in
    let surfaces = tool_projection_surfaces_for tool_name in
    let effect_domain =
      match metadata.effect_domain with
      | None -> `Null
      | Some domain -> `String (Tool_catalog.effect_domain_to_string domain)
    in
    `Assoc
      [ "name", `String tool_name
      ; "registered_schema", `Bool registered_schema
      ; "dispatch_registered", `Bool dispatch_registered
      ; "direct_call_allowed", `Bool (Tool_catalog.allow_direct_call tool_name)
      ; "visibility", `String (Tool_catalog.visibility_to_string metadata.visibility)
      ; ( "surfaces"
        , `List (List.map (fun surface -> `String surface) surfaces) )
      ; "surface_count", `Int (List.length surfaces)
      ; "effect_domain", effect_domain
      ; ( "read_only"
        , match metadata.readonly with
          | None -> `Null
          | Some read_only -> `Bool read_only )
      ; ( "requires_actor_binding"
        , match metadata.requires_actor_binding with
          | None -> `Null
          | Some requires_actor_binding -> `Bool requires_actor_binding )
      ]
;;

let schedule_keeper_next_action readiness =
  match Schedule_projection.keeper_next_action_for_execution_readiness readiness with
  | Some action -> `String action
  | None -> `Null
;;

let schedule_fsm_state ~now state schedules =
  let count status = schedule_status_count schedules status in
  let count_non_expired status =
    List.fold_left
      (fun count (request : Schedule_domain.schedule_request) ->
         if request.status = status && not (schedule_effectively_expired ~now request)
         then count + 1
         else count)
      0 schedules
  in
  let due_effective_count =
    List.fold_left
      (fun count request -> if schedule_effectively_due ~now request then count + 1 else count)
      0 schedules
  in
  let blocked_approval_count =
    List.fold_left
      (fun count request ->
         if schedule_blocked_approval ~now state request then count + 1 else count)
      0 schedules
  in
  if count Schedule_domain.Running > 0
  then "running"
  else if blocked_approval_count > 0
  then "blocked_approval"
  else if due_effective_count > 0
  then "due"
  else if count_non_expired Schedule_domain.Pending_approval > 0
  then "pending_approval"
  else if count_non_expired Schedule_domain.Scheduled > 0
  then "scheduled"
  else if
    List.exists (fun request -> schedule_effectively_expired ~now request) schedules
  then "expired"
  else "idle"
;;

let execution_record_dashboard_json (execution : Schedule_domain.execution_record) =
  match Schedule_domain.execution_record_to_yojson execution with
  | `Assoc fields ->
    `Assoc
      (fields
       @ [ "started_at_iso", unix_iso_json execution.started_at
         ; "finished_at_iso", unix_iso_option_json execution.finished_at
         ])
  | other -> other
;;

let schedule_signal_projection_limit = 20

let schedule_signal_payload_kind_json (signal : Schedule_runner.wake_signal) =
  match signal.payload with
  | `Assoc fields ->
    (match List.assoc_opt "kind" fields with
     | Some (`String kind) -> `String kind
     | _ -> `Null)
  | _ -> `Null
;;

let schedule_signal_dashboard_json (signal : Schedule_runner.wake_signal) =
  let kind = Schedule_runner.signal_kind_to_string signal.kind in
  `Assoc
    [ "signal_id", `String signal.signal_id
    ; "kind", `String kind
    ; "event_type", `String kind
    ; "schedule_id", `String signal.schedule_id
    ; "emitted_at", `Float signal.emitted_at
    ; "emitted_at_iso", unix_iso_json signal.emitted_at
    ; "due_at", `Float signal.due_at
    ; "due_at_iso", unix_iso_json signal.due_at
    ; "risk_class", `String (Schedule_domain.risk_class_to_string signal.risk_class)
    ; "payload_digest", `String signal.payload_digest
    ; "payload_kind", schedule_signal_payload_kind_json signal
    ]
;;

let schedule_request_dashboard_json
  ~now
  ~state
  ?last_execution
  (request : Schedule_domain.schedule_request)
  =
  let next_due_at =
    if Schedule_domain.is_terminal request.status then None else Some request.due_at
  in
  let requires_grant = Schedule_domain.requires_separate_human_grant request in
  let payload_target, payload_summary =
    Schedule_payload_projection.target_summary request
  in
  let execution_readiness = schedule_execution_readiness ~now state request in
  let keeper_next_tool =
    Schedule_projection.keeper_next_tool_for_execution_readiness execution_readiness
  in
  `Assoc
    [ "schedule_id", `String request.schedule_id
    ; "status", `String (Schedule_domain.schedule_status_to_string request.status)
    ; "effective_status", `String (schedule_effective_status ~now state request)
    ; ( "execution_readiness"
      , `String (Schedule_projection.execution_readiness_to_string execution_readiness) )
    ; "operator_action", schedule_operator_action execution_readiness
    ; ( "keeper_next_tool"
      , match keeper_next_tool with
        | None -> `Null
        | Some tool -> `String tool )
    ; "keeper_next_tool_status", schedule_keeper_next_tool_status_json keeper_next_tool
    ; "keeper_next_action", schedule_keeper_next_action execution_readiness
    ; "risk_class", `String (Schedule_domain.risk_class_to_string request.risk_class)
    ; "approval_required", `Bool request.approval_required
    ; "source", `String (Schedule_domain.schedule_source_to_string request.source)
    ; "requested_by", Schedule_domain.actor_to_yojson request.requested_by
    ; "scheduled_by", Schedule_domain.actor_to_yojson request.scheduled_by
    ; "requested_at", `Float request.requested_at
    ; "requested_at_iso", unix_iso_json request.requested_at
    ; "due_at", `Float request.due_at
    ; "due_at_iso", unix_iso_json request.due_at
    ; ( "next_due_at"
      , match next_due_at with
        | None -> `Null
        | Some ts -> `Float ts )
    ; "next_due_at_iso", unix_iso_option_json next_due_at
    ; "expires_at", (match request.expires_at with None -> `Null | Some ts -> `Float ts)
    ; "expires_at_iso", unix_iso_option_json request.expires_at
    ; "recurrence", Schedule_domain.recurrence_to_yojson request.recurrence
    ; "recurrence_kind", `String (Schedule_domain.recurrence_kind_to_string request.recurrence)
    ; "recurrence_summary", `String (Schedule_domain.recurrence_summary request.recurrence)
    ; ( "requires_separate_human_grant", `Bool requires_grant )
    ; ( "approval_policy"
      , `String
          (if requires_grant
           then "separate_human_grant_required"
           else "no_separate_grant_required") )
    ; "payload_digest", `String (Schedule_domain.payload_digest request.payload)
    ; ( "payload_kind"
      , match Schedule_payload_projection.kind request with
        | None -> `Null
        | Some kind -> `String kind )
    ; "payload_support", `String (schedule_payload_support_status request)
    ; ( "payload_target"
      , match payload_target with
        | None -> `Null
        | Some target -> `String target )
    ; ( "payload_summary"
      , match payload_summary with
        | None -> `Null
        | Some summary -> `String summary )
    ; ( "last_execution"
      , match last_execution with
        | None -> `Null
        | Some execution -> execution_record_dashboard_json execution )
    ]
;;

let scheduled_automation_dashboard_json (config : Workspace.config) : Yojson.Safe.t =
  (* NDT-OK: dashboard read-model freshness clock; it derives display-only
     effective-due state and never mutates the schedule store or runs work. *)
  let now = Unix.gettimeofday () in
  let state = Schedule_store.read_state config in
  let schedules = state.schedules in
  let active_count =
    List.fold_left
      (fun count request ->
         if schedule_request_effectively_active ~now request then count + 1 else count)
      0 schedules
  in
  let terminal_count = List.length schedules - active_count in
  let expired_effective_count =
    List.fold_left
      (fun count request ->
         if schedule_effectively_expired ~now request then count + 1 else count)
      0 schedules
  in
  let due_effective_count =
    List.fold_left
      (fun count request -> if schedule_effectively_due ~now request then count + 1 else count)
      0 schedules
  in
  let blocked_approval_count =
    List.fold_left
      (fun count request ->
         if schedule_blocked_approval ~now state request then count + 1 else count)
      0 schedules
  in
  let due_execution_ready_count =
    state
    |> Schedule_store.due_execution_candidates
    |> List.filter (fun request -> not (schedule_effectively_expired ~now request))
    |> List.length
  in
  let payload_support = schedule_payload_support_json schedules in
  let unsupported_payload_kind_count, unknown_payload_kind_count =
    match payload_support with
    | `Assoc fields ->
      ( (match List.assoc_opt "unsupported_request_count" fields with
         | Some (`Int count) -> count
         | _ -> 0)
      , (match List.assoc_opt "unknown_request_count" fields with
         | Some (`Int count) -> count
         | _ -> 0) )
    | _ -> 0, 0
  in
  let sorted =
    schedules
    |> List.sort (fun left right ->
      match
        ( schedule_request_active left
        , schedule_request_active right
        , schedule_request_effectively_active ~now left
        , schedule_request_effectively_active ~now right
        , compare left.due_at right.due_at )
      with
      | _, _, true, false, _ -> -1
      | _, _, false, true, _ -> 1
      | true, false, _, _, _ -> -1
      | false, true, _, _, _ -> 1
      | _, _, _, _, due_cmp when due_cmp <> 0 -> due_cmp
      | _ -> String.compare left.schedule_id right.schedule_id)
  in
  let request_rows = Server_dashboard_http_runtime_info_json.take schedule_projection_request_limit sorted in
  let signal_rows =
    Schedule_runner.read_recent_signals config schedule_signal_projection_limit
  in
  `Assoc
    [ "schema", `String "masc.dashboard.scheduled_automation.v1"
    ; "source", `String "schedule_store"
    ; "generated_at", `String (Masc_domain.now_iso ())
    ; "request_count", `Int (List.length schedules)
    ; "request_limit", `Int schedule_projection_request_limit
    ; "truncated", `Bool (List.length schedules > schedule_projection_request_limit)
    ; "signal_source", `String "schedule_runner_signals"
    ; "signal_count", `Int (List.length signal_rows)
    ; "signal_limit", `Int schedule_signal_projection_limit
    ; "signals", `List (List.map schedule_signal_dashboard_json signal_rows)
    ; "counts", schedule_counts_json schedules
    ; ( "derived_counts"
      , `Assoc
          [ "due_effective", `Int due_effective_count
          ; "blocked_approval", `Int blocked_approval_count
          ; "due_execution_ready", `Int due_execution_ready_count
          ; "expired_effective", `Int expired_effective_count
          ; "unsupported_payload_kind", `Int unsupported_payload_kind_count
          ; "unknown_payload_kind", `Int unknown_payload_kind_count
          ] )
    ; "payload_support", payload_support
    ; ( "fsm"
      , `Assoc
          [ "state", `String (schedule_fsm_state ~now state schedules)
          ; "active_count", `Int active_count
          ; "terminal_count", `Int terminal_count
          ; "next_due_at", unix_iso_option_json (schedule_next_due_at ~now schedules)
          ] )
    ; ( "requests"
      , `List
          (List.map
             (fun (request : Schedule_domain.schedule_request) ->
                let last_execution =
                  Schedule_store.last_execution_for_schedule state
                    ~schedule_id:request.Schedule_domain.schedule_id
                in
                schedule_request_dashboard_json ~now ~state ?last_execution request)
             request_rows) )
    ]
;;

let dashboard_tools_http_json ?actor ?timing (config : Workspace.config) : Yojson.Safe.t =
  let actor_name = dashboard_actor_name actor in
  let ctx : Tool_misc.context =
    { config; agent_name = actor_name }
  in
  let run phase f =
    match timing with
    | None -> f ()
    | Some t -> Server_timing.measure t phase f
  in
  let cache_key =
    dashboard_tools_cache_key ~base_path:config.base_path ~actor:actor_name
  in
  Dashboard_cache.seed_stale_if_missing cache_key
    ~stale_for:dashboard_tools_cache_ttl_sec
    (dashboard_tools_warming_json ~actor:actor_name);
  let compute () =
    let config_resolution =
      run Projection_config_resolution (fun () ->
        Config_dir_resolver.(resolve () |> to_json))
    in
    let runtime_resolution =
      run Projection_runtime_resolution (fun () -> runtime_resolution_json config)
    in
    let inventory =
      run Tools_compute (fun () ->
        Tool_misc.tool_inventory_json ctx ~include_hidden:true)
    in
    let usage =
      run Tools_compute (fun () ->
        Tool_unified.summary_report
          ~runtime_metrics:Runtime_observation.runtime_metrics_json
          ()
        |> Tool_usage_log.attach_source_metadata
             ~masc_root:(Workspace.masc_root_dir config))
    in
    `Assoc
      [ "generated_at", `String (Masc_domain.now_iso ())
      ; "config_resolution", config_resolution
      ; "runtime_resolution", runtime_resolution
      ; "tool_inventory", inventory
      ; "tool_usage", usage
      ]
  in
  let attach_scheduled_automation json =
    let scheduled_automation =
      run Tools_compute (fun () -> scheduled_automation_dashboard_json config)
    in
    match json with
    | `Assoc fields -> `Assoc (fields @ [ "scheduled_automation", scheduled_automation ])
    | other -> other
  in
  let cached =
    match timing with
    | None ->
      Dashboard_cache.get_or_compute cache_key ~ttl:dashboard_tools_cache_ttl_sec
        compute
    | Some t ->
      Server_timing.measure t Cache_lookup (fun () ->
        Dashboard_cache.get_or_compute cache_key
          ~ttl:dashboard_tools_cache_ttl_sec compute)
  in
  attach_scheduled_automation cached
;;

let dashboard_perf_http_json = Server_dashboard_http_perf.dashboard_perf_http_json
let dashboard_runtime_probe_json = Server_runtime_probe.dashboard_runtime_probe_http_json ()
