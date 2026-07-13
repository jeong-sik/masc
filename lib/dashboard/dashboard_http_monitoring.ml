(** Dashboard HTTP monitoring — tool-call health, board, and Gate monitors.

    Extracted from server_dashboard_http.ml. *)


open Dashboard_http_helpers

(** Compute tool-call health metrics from [Audit_log] entries within a
    configurable time window.  Reads the canonical date-split audit store
    and counts [ToolCall _] actions, partitioned by outcome.

    [~now_ts] is injectable for testing; defaults to wall-clock time. *)
let tool_call_health_json ?(now_ts = Unix.gettimeofday ()) (config : Workspace.config)
    : Yojson.Safe.t =
  let window_hours = 1.0 in
  let since = now_ts -. (window_hours *. Masc_time_constants.hour) in
  let entries =
    try Audit_log.read_entries ~n:50_000 config
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      Log.Dashboard.warn "tool_call_health: read_entries failed: %s"
        (Printexc.to_string exn);
      []
  in
  (* Single pass: aggregate totals and per-tool failure counts. *)
  let module SMap = Set_util.StringMap in
  let total, failures, per_tool =
    List.fold_left
      (fun (t, f, m) (e : Audit_log.audit_entry) ->
        match e.action with
        | Audit_log.ToolCall tool_name when e.timestamp >= since ->
          let is_fail =
            match e.outcome with Audit_log.Failure _ -> true | Audit_log.Success -> false
          in
          let calls, fails =
            match SMap.find_opt tool_name m with
            | Some (c, fl) -> (c, fl)
            | None -> (0, 0)
          in
          let m =
            SMap.add tool_name
              (calls + 1, if is_fail then fails + 1 else fails)
              m
          in
          (t + 1, (if is_fail then f + 1 else f), m)
        | _ -> (t, f, m))
      (0, 0, SMap.empty) entries
  in
  let failure_rate =
    if total = 0 then 0.0 else float_of_int failures /. float_of_int total
  in
  (* Single-pass take: return the first [n] elements without traversing
     the entire list to compute its length. *)
  let take n ls =
    let rec aux acc i = function
      | _ when i >= n -> List.rev acc
      | [] -> List.rev acc
      | x :: xs -> aux (x :: acc) (i + 1) xs
    in
    aux [] 0 ls
  in
  (* Top 10 tools by failure count, breaking ties by call count descending
     and then tool name ascending for deterministic ordering. *)
  let top_failures =
    SMap.bindings per_tool
    |> List.filter (fun (_, (_, f)) -> f > 0)
    |> List.sort (fun (name1, (c1, f1)) (name2, (c2, f2)) ->
           let by_failures = Int.compare f2 f1 in
           if by_failures <> 0 then by_failures
           else
             let by_calls = Int.compare c2 c1 in
             if by_calls <> 0 then by_calls
             else String.compare name1 name2)
    |> take 10
    |> List.map (fun (name, (calls, fails)) ->
         `Assoc [
           ("tool", `String name);
           ("calls", `Int calls);
           ("failures", `Int fails);
         ])
  in
  (* Top 10 tools by call count (most active), breaking ties by failures
     descending and then tool name ascending for deterministic ordering. *)
  let top_active =
    SMap.bindings per_tool
    |> List.sort (fun (name1, (c1, f1)) (name2, (c2, f2)) ->
           let by_calls = Int.compare c2 c1 in
           if by_calls <> 0 then by_calls
           else
             let by_failures = Int.compare f2 f1 in
             if by_failures <> 0 then by_failures
             else String.compare name1 name2)
    |> take 10
    |> List.map (fun (name, (calls, fails)) ->
         `Assoc [
           ("tool", `String name);
           ("calls", `Int calls);
           ("failures", `Int fails);
         ])
  in
  `Assoc [
    ("window_hours", `Float window_hours);
    ("tool_calls", `Int total);
    ("failures", `Int failures);
    ("failure_rate", `Float failure_rate);
    ("distinct_tools", `Int (SMap.cardinal per_tool));
    ("top_failures", `List top_failures);
    ("top_active", `List top_active);
    ("since_epoch", `Float since);
  ]

let board_monitoring_json ~(now_ts : float) : Yojson.Safe.t * bool =
  let warn_age_s = Masc_time_constants.hour_int in
  let bad_age_s = 21600 in
  let slo_target_age_s = 900 in
  try
    let posts = Board_dispatch.list_posts ~sort_by:Board_dispatch.Updated ~limit:200 () in
    let total_posts = List.length posts in
    let new_posts_24h =
      List.fold_left
        (fun acc (p : Board.post) ->
          if p.created_at >= (now_ts -. Masc_time_constants.day) then acc + 1 else acc)
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
      ("last_activity_age_s", Json_util.int_opt_to_json last_activity_age_s);
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

let credential_monitoring_json () : Yojson.Safe.t =
  (* Bare-form credential alias archive logic was removed; the legacy
     starvation counter is always zero.  The dashboard field is retained
     for API compatibility. *)
  `Assoc [
    ("alert_level", `String "ok");
    ("needs_attention", `Bool false);
    ("credential_archived_starvation_total", `Int 0);
    ("metric_name", `String "masc_config_credential_archived_starvation_total");
    ("reason", `Null);
  ]

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

let executor_outcomes_json (config : Workspace.config) : Yojson.Safe.t =
  try
    let since = Time_compat.now () -. Masc_time_constants.day in
    let events = Telemetry_eio.read_events_since config ~since in
    let total = ref 0 in
    let successes = ref 0 in
    List.iter (fun (r : Telemetry_eio.event_record) ->
      match r.event with
      | Telemetry_eio.Tool_called { tool_name; success; _ }
        when String.length tool_name > 9
          && String.starts_with ~prefix:"executor:" tool_name ->
        incr total;
        if success then incr successes
      | Telemetry_eio.Tool_called _ -> ()
      | Agent_session_bound _ | Agent_unbound _ | Task_started _ | Task_completed _
      | Handoff_triggered _ | Error_occurred _ | Tool_assigned _ -> ()
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
