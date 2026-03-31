(** Dashboard HTTP monitoring — tool-call health, board, and governance monitors.

    Extracted from server_dashboard_http.ml. *)


open Dashboard_http_helpers

let tool_call_health_json (config : Room.config) : Yojson.Safe.t =
  let window_hours =
    float_of_env_default
      "MASC_DASHBOARD_TOOL_CALL_WINDOW_HOURS"
      ~default:1.0
      ~min_v:0.1
      ~max_v:168.0
  in
  let since = Time_compat.now () -. (window_hours *. 3600.0) in
  let events = Tool_audit.read_audit_events config ~since in
  let total = ref 0 in
  let failures = ref 0 in
  let timeouts = ref 0 in
  let durations_rev = ref [] in
  List.iter
    (fun (e : Tool_audit.audit_event) ->
      if e.event_type = "tool_call" then begin
        incr total;
        if not e.success then incr failures;
        let (_tool_name, timeout_now, duration_ms_opt) =
          parse_tool_call_detail e.detail
        in
        if timeout_now then incr timeouts;
        (match duration_ms_opt with
         | Some d -> durations_rev := d :: !durations_rev
         | None -> ())
      end)
    events;
  let total_f = float_of_int !total in
  let failure_rate =
    if !total = 0 then 0.0 else float_of_int !failures /. total_f
  in
  let p95_duration_ms = percentile_int !durations_rev ~pct:0.95 in
  `Assoc [
    ("window_hours", `Float window_hours);
    ("tool_calls", `Int !total);
    ("failures", `Int !failures);
    ("timeouts", `Int !timeouts);
    ("failure_rate", `Float failure_rate);
    ("p95_duration_ms", Json_util.int_opt_to_json p95_duration_ms);
  ]

let board_monitoring_json ~(now_ts : float) : Yojson.Safe.t * bool =
  let warn_age_s =
    int_of_env_default
      "MASC_DASHBOARD_BOARD_AGE_WARN_SEC"
      ~default:3600
      ~min_v:60
      ~max_v:604800
  in
  let bad_age_s =
    int_of_env_default
      "MASC_DASHBOARD_BOARD_AGE_BAD_SEC"
      ~default:21600
      ~min_v:120
      ~max_v:1209600
  in
  let slo_target_age_s =
    int_of_env_default
      "MASC_DASHBOARD_BOARD_SLO_SEC"
      ~default:900
      ~min_v:30
      ~max_v:86400
  in
  try
    let posts = Board_dispatch.list_posts ~sort_by:Board_dispatch.Updated ~limit:200 () in
    let total_posts = List.length posts in
    let new_posts_24h =
      List.fold_left
        (fun acc (p : Board.post) ->
          if p.created_at >= (now_ts -. (24.0 *. 3600.0)) then acc + 1 else acc)
        0 posts
    in
    let unanswered_posts =
      List.fold_left
        (fun acc (p : Board.post) ->
          if p.reply_count = 0 then acc + 1 else acc)
        0 posts
    in
    let latest_activity_ts_opt =
      List.fold_left
        (fun acc (p : Board.post) ->
          match acc with
          | None -> Some p.updated_at
          | Some prev -> Some (max prev p.updated_at))
        None posts
    in
    let last_activity_age_s =
      match latest_activity_ts_opt with
      | None -> None
      | Some ts -> safe_age_seconds_opt ~now_ts ~event_ts:ts
    in
    let alert_level =
      match last_activity_age_s with
      | None -> "warn"
      | Some age when age >= bad_age_s -> "bad"
      | Some age when age >= warn_age_s -> "warn"
      | Some _ -> "ok"
    in
    let slo_breached =
      match last_activity_age_s with
      | Some age -> age >= slo_target_age_s
      | None -> false
    in
    (`Assoc [
      ("alert_level", `String alert_level);
      ("posts_total", `Int total_posts);
      ("new_posts_24h", `Int new_posts_24h);
      ("unanswered_posts", `Int unanswered_posts);
      ("last_activity_age_s", json_int_opt last_activity_age_s);
      ("slo_target_age_s", `Int slo_target_age_s);
      ("slo_breached", `Bool slo_breached);
    ], true)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Dashboard.error "board_monitoring_json failed: %s"
      (Printexc.to_string exn);
    (`Assoc [
      ("alert_level", `String "bad");
      ("posts_total", `Int 0);
      ("new_posts_24h", `Int 0);
      ("unanswered_posts", `Int 0);
      ("last_activity_age_s", `Null);
      ("slo_target_age_s", `Int slo_target_age_s);
      ("slo_breached", `Bool false);
    ], false)

let governance_monitoring_json ~(now_ts : float) ~(base_path : string)
  : Yojson.Safe.t * bool =
  let warn_age_s =
    int_of_env_default
      "MASC_DASHBOARD_COUNCIL_AGE_WARN_SEC"
      ~default:3600
      ~min_v:60
      ~max_v:604800
  in
  let bad_age_s =
    int_of_env_default
      "MASC_DASHBOARD_COUNCIL_AGE_BAD_SEC"
      ~default:21600
      ~min_v:120
      ~max_v:1209600
  in
  let slo_target_quorum_age_s =
    int_of_env_default
      "MASC_DASHBOARD_COUNCIL_SLO_SEC"
      ~default:1800
      ~min_v:30
      ~max_v:86400
  in
  let module GV2 = Council.Governance_v2 in
  try
    let cases : GV2.case_record list = GV2.list_cases base_path in
    let count status =
      List.fold_left
        (fun acc (case_ : GV2.case_record) ->
          if case_.GV2.status = status then acc + 1 else acc)
        0 cases
    in
    let pending_ruling = count GV2.Pending_ruling in
    let ready_auto_execute = count GV2.Ready_auto_execute in
    let needs_human_gate = count GV2.Needs_human_gate in
    let executed = count GV2.Executed in
    let blocked =
      List.fold_left
        (fun acc (case_ : GV2.case_record) ->
          match case_.GV2.status with
          | GV2.Blocked | GV2.Closed -> acc + 1
          | GV2.Pending_ruling | GV2.Ready_auto_execute
          | GV2.Needs_human_gate | GV2.Executed -> acc)
        0 cases
    in
    let cases_open = pending_ruling + ready_auto_execute + needs_human_gate in
    let oldest_open_case_ts_opt =
      List.fold_left
        (fun acc (case_ : GV2.case_record) ->
          match case_.GV2.status with
          | GV2.Pending_ruling | GV2.Ready_auto_execute | GV2.Needs_human_gate ->
              (match acc with
              | None -> Some case_.GV2.updated_at
              | Some prev -> Some (min prev case_.GV2.updated_at))
          | GV2.Executed | GV2.Blocked | GV2.Closed -> acc)
        None cases
    in
    let oldest_open_case_age_s =
      match oldest_open_case_ts_opt with
      | None -> None
      | Some ts -> safe_age_seconds_opt ~now_ts ~event_ts:ts
    in
    let latest_activity_ts_opt =
      List.fold_left
        (fun acc (case_ : GV2.case_record) ->
          match acc with
          | None -> Some case_.GV2.updated_at
          | Some prev -> Some (max prev case_.GV2.updated_at))
        None cases
    in
    let last_activity_age_s =
      match latest_activity_ts_opt with
      | None -> None
      | Some ts -> safe_age_seconds_opt ~now_ts ~event_ts:ts
    in
    let base_alert =
      match last_activity_age_s with
      | None -> if cases_open > 0 then "warn" else "ok"
      | Some age when age >= bad_age_s -> "bad"
      | Some age when age >= warn_age_s -> "warn"
      | Some _ -> "ok"
    in
    let slo_breached =
      match oldest_open_case_age_s with
      | Some age -> cases_open > 0 && age >= slo_target_quorum_age_s
      | None -> false
    in
    let judge_json = Dashboard_governance.judge_runtime_json base_path in
    let judge_online =
      match Yojson.Safe.Util.member "judge_online" judge_json with
      | `Bool value -> value
      | _ -> false
    in
    let alert_level =
      if needs_human_gate > 0 then
        match oldest_open_case_age_s with
        | Some age when age >= bad_age_s -> "bad"
        | _ -> "warn"
      else base_alert
    in
    (`Assoc [
      ("alert_level", `String alert_level);
      ("cases_open", `Int cases_open);
      ("pending_ruling", `Int pending_ruling);
      ("ready_auto_execute", `Int ready_auto_execute);
      ("needs_human_gate", `Int needs_human_gate);
      ("executed", `Int executed);
      ("blocked", `Int blocked);
      ("oldest_open_case_age_s", json_int_opt oldest_open_case_age_s);
      ("last_activity_age_s", json_int_opt last_activity_age_s);
      ("slo_target_case_age_s", `Int slo_target_quorum_age_s);
      ("slo_breached", `Bool slo_breached);
      ("judge_online", `Bool judge_online);
    ], true)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Dashboard.error "governance_monitoring_json failed: %s"
      (Printexc.to_string exn);
    (`Assoc [
      ("alert_level", `String "bad");
      ("cases_open", `Int 0);
      ("pending_ruling", `Int 0);
      ("ready_auto_execute", `Int 0);
      ("needs_human_gate", `Int 0);
      ("executed", `Int 0);
      ("blocked", `Int 0);
      ("oldest_open_case_age_s", `Null);
      ("last_activity_age_s", `Null);
      ("slo_target_case_age_s", `Int slo_target_quorum_age_s);
      ("slo_breached", `Bool false);
      ("judge_online", `Bool false);
    ], false)
