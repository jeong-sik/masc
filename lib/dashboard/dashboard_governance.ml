(** Dashboard Governance — live judge status surface (case tracking retired). *)

type detail_status = [ `OK | `Not_found ]

let option_to_yojson = Json_util.option_to_yojson

let string_option_json = option_to_yojson (fun value -> `String value)

let timestamp_option_json value unix_value =
  match value, unix_value with
  | Some iso, _ -> `String iso
  | None, Some ts -> `String (Types.iso8601_of_unix_seconds ts)
  | None, None -> `Null

let judge_json_of_runtime (runtime : Dashboard_governance_judge.runtime_snapshot) =
  `Assoc
    [
      ("judge_online", `Bool runtime.judge_online);
      ("refreshing", `Bool runtime.refreshing);
      ("generated_at", timestamp_option_json runtime.generated_at runtime.generated_at_unix);
      ("expires_at", timestamp_option_json runtime.expires_at runtime.expires_at_unix);
      ("model_used", string_option_json runtime.model_used);
      ("keeper_name", `String runtime.keeper_name);
      ("last_error", string_option_json runtime.last_error);
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

let factual_snapshot_json ~base_path:_ =
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ("items", `List []);
      ("activity", `List []);
    ]

let dashboard_json ~base_path ~limit ~offset:_ ~status_filter:_ =
  let runtime = Dashboard_governance_judge.runtime_status base_path in
  let judgments = Dashboard_governance_judge.fresh_judgments_json ~base_path ~limit in
  let approval_queue = Keeper_approval_queue.list_pending_dashboard_json () in
  let approval_rules = Keeper_approval_queue.list_rules_dashboard_json () in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ("summary", summary_json_of_runtime ~base_path runtime);
      ("items", `List []);
      ("activity", `List []);
      ("judge", judge_json_of_runtime runtime);
      ("judgments", `List judgments);
      ("pending_actions", `List []);
      ("approval_queue", approval_queue);
      ("approval_rules", approval_rules);
      ("cases", `List []);
    ]

let cases_json ~base_path:_ ~limit ~offset ~status_filter:_ ~include_test:_ =
  `Assoc
    [
      ("cases", `List []);
      ("count", `Int 0);
      ("limit", `Int limit);
      ("offset", `Int offset);
    ]

let case_detail_json ~base_path:_ ~case_id =
  ignore case_id;
  ( `Not_found,
    `Assoc
      [
        ("error", `String "Governance case tracking unavailable");
      ] )
