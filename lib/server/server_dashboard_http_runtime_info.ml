(** Runtime-resolution and dashboard tools projections extracted from the
    dashboard HTTP facade. *)

open Dashboard_http_helpers


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





let governance_hitl_json () =
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
        , Server_dashboard_http_deployment_state.deployment_state_json ~build ~server_repo_commit ~workspace_commit
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
      run Tools_compute (fun () -> Server_dashboard_http_schedule_projection.scheduled_automation_dashboard_json config)
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
