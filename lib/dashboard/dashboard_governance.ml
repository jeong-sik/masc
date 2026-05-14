(** Dashboard Governance — live judge status surface (case tracking retired). *)

let option_to_yojson = Json_util.option_to_yojson

let string_option_json = option_to_yojson (fun value -> `String value)

let timestamp_option_json value unix_value =
  match value, unix_value with
  | Some iso, _ -> `String iso
  | None, Some ts -> `String (Masc_domain.iso8601_of_unix_seconds ts)
  | None, None -> `Null

let judge_json_of_runtime (runtime : Dashboard_governance_judge.runtime_snapshot) =
  `Assoc
    [
      ("judge_online", `Bool runtime.judge_online);
      ("refreshing", `Bool runtime.refreshing);
      ("status", `String runtime.status);
      ("degraded_reason", string_option_json runtime.degraded_reason);
      ("cached_judgments_visible", `Bool runtime.cached_judgments_visible);
      ("generated_at", timestamp_option_json runtime.generated_at runtime.generated_at_unix);
      ("expires_at", timestamp_option_json runtime.expires_at runtime.expires_at_unix);
      ("model_used", `Null);
      ("keeper_name", `String runtime.keeper_name);
      ("last_error", string_option_json runtime.last_error);
      ("compute_in_flight", `Int runtime.compute_in_flight);
      ( "last_compute_duration_sec",
        option_to_yojson (fun value -> `Float value)
          runtime.last_compute_duration_sec );
      ( "last_compute_timeout_sec",
        option_to_yojson (fun value -> `Float value)
          runtime.last_compute_timeout_sec );
      ( "last_compute_outcome",
        string_option_json runtime.last_compute_outcome );
      ( "last_compute_reason",
        string_option_json runtime.last_compute_reason );
      ( "lenient_json_fallback",
        Judge_diagnostics.lenient_fallback_metrics_json ~judge_label:"Governance" );
    ]

let summary_json_of_runtime ?base_path
    (runtime : Dashboard_governance_judge.runtime_snapshot) =
  let pending_approval_count = Keeper_approval_queue.pending_count () in
  let pending_ruling, oldest_json =
    match base_path with
    | None -> 0, `Null
    | Some base_path ->
      let n =
        Governance_cases_snapshot.pending_ruling_count ~base_path
      in
      let oldest =
        Governance_cases_snapshot.oldest_pending_ruling_age_s ~base_path
          ~now_ts:(Unix.gettimeofday ())
      in
      n, Option.fold ~none:`Null ~some:(fun v -> `Float v) oldest
  in
  `Assoc
    [
      ("cases_open", `Int pending_ruling);
      ("pending_ruling", `Int pending_ruling);
      ("ready_auto_execute", `Int 0);
      ("needs_human_gate", `Int pending_approval_count);
      ("executed", `Int 0);
      ("blocked", `Int 0);
      ("ready_to_execute", `Int 0);
      ("oldest_open_case_age_s", oldest_json);
      ("last_activity_age_s", `Null);
      ("judge_online", `Bool runtime.judge_online);
      ("judge_last_seen_at", timestamp_option_json runtime.generated_at runtime.generated_at_unix);
    ]

let baseline_dir base_path =
  Filename.concat
    (Coord_utils.masc_dir_from_base_path ~base_path)
    "governance"
  |> fun d -> Filename.concat d "baselines"

let anomaly_profiles_json ~base_path =
  let dir = baseline_dir base_path in
  try
    if not (Sys.file_exists dir) then `List []
    else
      let files = Sys.readdir dir in
      Array.to_list files
      |> List.filter (fun f -> Filename.check_suffix f ".json")
      |> List.filter_map (fun f ->
          let agent_id = Filename.chop_suffix f ".json" in
          match Governance_anomaly.load_profile ~base_path ~agent_id with
          | Some p ->
              Some
                (`Assoc
                   [
                     ("agent_id", `String p.agent_id);
                     ("window_days", `Int p.window_days);
                     ("sample_count", `Int p.sample_count);
                     ("activity_volume_mean", `Float p.activity_volume.mean);
                     ("tool_diversity_mean", `Float p.tool_diversity.mean);
                     ( "token_volume_mean",
                       match p.token_volume with
                       | Some s -> `Float s.mean
                       | None -> `Null );
                     ("failure_rate_mean", `Float p.failure_rate.mean);
                     ("updated_at", `Float p.updated_at);
                   ])
          | None -> None)
      |> fun items -> `List items
  with
  | Sys_error _ -> `List []
  | exn ->
      Log.Governance.warn "anomaly_profiles_json: %s" (Printexc.to_string exn);
      `List []

let dashboard_json ~base_path ~limit ~offset:_ ~status_filter:_ =
  let runtime = Dashboard_governance_judge.runtime_status base_path in
  let judgments = Dashboard_governance_judge.fresh_judgments_json ~base_path ~limit in
  let approval_queue = Keeper_approval_queue.list_pending_dashboard_json () in
  let approval_rules =
    Keeper_approval_queue.list_rules_dashboard_json ~base_path ()
  in
  `Assoc
    [
      ("generated_at", `String (Masc_domain.now_iso ()));
      ("summary", summary_json_of_runtime ~base_path runtime);
      ("items", `List []);
      ("activity", `List []);
      ("judge", judge_json_of_runtime runtime);
      ("judgments", `List judgments);
      ("pending_actions", `List []);
      ("approval_queue", approval_queue);
      ("approval_rules", approval_rules);
      ("cases", `List []);
      ("anomaly_profiles", anomaly_profiles_json ~base_path);
    ]
