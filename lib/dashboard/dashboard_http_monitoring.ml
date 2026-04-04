(** Dashboard HTTP monitoring — tool-call health, board, and governance monitors.

    Extracted from server_dashboard_http.ml. *)


open Dashboard_http_helpers

(* Tool_audit module removed — audit-based tool call health is retired.
   Returns zeroed metrics so dashboard consumers degrade gracefully. *)
let tool_call_health_json (_config : Room.config) : Yojson.Safe.t =
  let window_hours =
    float_of_env_default
      "MASC_DASHBOARD_TOOL_CALL_WINDOW_HOURS"
      ~default:1.0
      ~min_v:0.1
      ~max_v:168.0
  in
  `Assoc [
    ("window_hours", `Float window_hours);
    ("tool_calls", `Int 0);
    ("failures", `Int 0);
    ("timeouts", `Int 0);
    ("failure_rate", `Float 0.0);
    ("p95_duration_ms", `Null);
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
  let runtime = Dashboard_governance_judge.runtime_status_at ~now_ts base_path in
  let alert_level = if runtime.judge_online then "ok" else "warn" in
  (* Governance case tracking is retired, but judge runtime status is still live. *)
  (`Assoc [
    ("alert_level", `String alert_level);
    ("cases_open", `Int 0);
    ("pending_ruling", `Int 0);
    ("ready_auto_execute", `Int 0);
    ("needs_human_gate", `Int 0);
    ("executed", `Int 0);
    ("blocked", `Int 0);
    ("oldest_open_case_age_s", `Null);
    ("last_activity_age_s", `Null);
    ("slo_target_case_age_s", `Int 0);
    ("slo_breached", `Bool false);
    ("judge_online", `Bool runtime.judge_online);
    ("case_tracking_available", `Bool false);
    ("note", `String Dashboard_governance.case_tracking_note);
  ], true)

let slot_monitoring_json () : Yojson.Safe.t =
  try
    let idle = Discovery_cache.idle_slot_count () in
    let busy = Discovery_cache.busy_slot_count () in
    let total = idle + busy in
    let endpoints = Discovery_cache.get_cached_or_refresh () in
    `Assoc [
      ("idle", `Int idle);
      ("busy", `Int busy);
      ("total", `Int total);
      ("utilization",
        `Float (if total > 0
                then float_of_int busy /. float_of_int total
                else 0.0));
      ("cache_age_s", `Float (Discovery_cache.cache_age_seconds ()));
      ("endpoints", `List (List.map Discovery_cache.endpoint_to_json endpoints));
    ]
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ ->
    `Assoc [
      ("idle", `Int 0); ("busy", `Int 0); ("total", `Int 0);
      ("utilization", `Float 0.0);
      ("cache_age_s", `Float 0.0);
      ("endpoints", `List []);
    ]

let executor_outcomes_json (config : Room.config) : Yojson.Safe.t =
  try
    let since = Time_compat.now () -. 86400.0 in
    let events = Telemetry_eio.read_events_since config ~since in
    let total = ref 0 in
    let successes = ref 0 in
    List.iter (fun (r : Telemetry_eio.event_record) ->
      match r.event with
      | Telemetry_eio.Tool_called { tool_name; success; _ }
        when String.length tool_name > 9
          && String.sub tool_name 0 9 = "executor:" ->
        incr total;
        if success then incr successes
      | _ -> ()
    ) events;
    `Assoc [
      ("total_24h", `Int !total);
      ("success_24h", `Int !successes);
      ("failure_24h", `Int (!total - !successes));
    ]
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ ->
    `Assoc [
      ("total_24h", `Int 0);
      ("success_24h", `Int 0);
      ("failure_24h", `Int 0);
    ]
