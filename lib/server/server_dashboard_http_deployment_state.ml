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
