(** Team session report generation (Markdown + JSON). *)

let team_health_json (session : Team_session_types.session) active_agents =
  let active_count = List.length active_agents in
  let required = max 1 session.min_agents in
  let coverage_ratio = min 1.0 (float_of_int active_count /. float_of_int required) in
  let health =
    if active_count >= required then
      "healthy"
    else if active_count >= max 1 (required / 2) then
      "degraded"
    else
      "critical"
  in
  `Assoc
    [
      ("status", `String health);
      ("active_agents_count", `Int active_count);
      ("required_agents", `Int required);
      ("coverage_ratio", `Float coverage_ratio);
      ("min_agents_violation_streak", `Int session.min_agents_violation_streak);
    ]

let communication_metrics_json (session : Team_session_types.session) =
  `Assoc
    [
      ( "mode",
        `String
          (Team_session_types.communication_mode_to_string
             session.communication_mode) );
      ("broadcast_count", `Int session.broadcast_count);
      ("portal_count", `Int session.portal_count);
      ("total", `Int (session.broadcast_count + session.portal_count));
    ]

let cascade_metrics_json (session : Team_session_types.session) =
  let attempted = max 0 session.cascade_attempted in
  let success = max 0 session.cascade_success in
  let success_rate =
    if attempted = 0 then
      0.0
    else
      float_of_int success /. float_of_int attempted
  in
  `Assoc
    [
      ("model_cascade", `List (List.map (fun m -> `String m) session.model_cascade));
      ("attempted", `Int attempted);
      ("success", `Int success);
      ("failed", `Int (max 0 session.cascade_failed));
      ("success_rate", `Float success_rate);
      ("fallback_task_created", `Int (max 0 session.fallback_task_created));
    ]

let summary_metrics (session : Team_session_types.session) config =
  let live_delta_by_agent, live_done_delta_total =
    let backlog = Room.read_backlog config in
    let current_done = Team_session_types.done_counts_from_backlog backlog in
    let delta_by_agent =
      Team_session_types.done_delta_by_agent ~baseline:session.baseline_done_counts
        ~current:current_done ~agents:session.agent_names
    in
    let done_delta_total =
      List.fold_left (fun acc (_, n) -> acc + n) 0 delta_by_agent
    in
    (delta_by_agent, done_delta_total)
  in
  let delta_by_agent, done_delta_total =
    match (session.final_done_delta_by_agent, session.final_done_delta_total) with
    | Some deltas, Some total -> (deltas, total)
    | Some deltas, None ->
        (deltas, List.fold_left (fun acc (_, n) -> acc + n) 0 deltas)
    | None, Some total -> (live_delta_by_agent, total)
    | None, None -> (live_delta_by_agent, live_done_delta_total)
  in
  let now = Time_compat.now () in
  let end_time = Option.value session.stopped_at ~default:now in
  let elapsed = max 0.0 (end_time -. session.started_at) in
  let remaining = max 0.0 (session.planned_end_at -. now) in
  let progress_pct =
    if session.duration_seconds <= 0 then
      100.0
    else min 100.0 (100.0 *. (elapsed /. float_of_int session.duration_seconds))
  in
  let active_agents =
    Room.get_agents_raw config
    |> List.map (fun (a : Types.agent) -> a.name)
    |> Team_session_types.dedup_strings
    |> List.sort String.compare
  in
  let team_health = team_health_json session active_agents in
  let communication_metrics = communication_metrics_json session in
  let cascade_metrics = cascade_metrics_json session in
  ( `Assoc
      [
        ("elapsed_sec", `Int (int_of_float elapsed));
        ("remaining_sec", `Int (int_of_float remaining));
        ("progress_pct", `Float progress_pct);
        ("done_delta_total", `Int done_delta_total);
        ("done_delta_by_agent", Team_session_types.assoc_int_to_json delta_by_agent);
        ("active_agents", `List (List.map (fun a -> `String a) active_agents));
      ],
    done_delta_total,
    delta_by_agent,
    active_agents,
    team_health,
    communication_metrics,
    cascade_metrics )

let event_count events event_type =
  List.fold_left
    (fun acc json ->
      match Yojson.Safe.Util.member "event_type" json with
      | `String e when e = event_type -> acc + 1
      | _ -> acc)
    0 events

let recent_event_lines events limit =
  let recent_chronological =
    let rev = List.rev events in
    let rec take n acc = function
      | [] -> acc
      | _ when n <= 0 -> acc
      | x :: xs -> take (n - 1) (x :: acc) xs
    in
    take limit [] rev
  in
  recent_chronological
  |> List.filter_map (fun json ->
         let open Yojson.Safe.Util in
         match (member "ts_iso" json, member "event_type" json) with
         | `String ts_iso, `String event_type ->
             Some (Printf.sprintf "- %s | %s" ts_iso event_type)
         | _ -> None)

let mcp_improvements (session : Team_session_types.session) events checkpoints_count
    done_delta_total =
  let base =
    [
      "Session lifecycle is now first-class via start/status/stop/report/list/compare APIs.";
      "Periodic checkpoints and final reports improve handoff quality for long runs.";
    ]
  in
  let with_policy =
    if session.policy_violations <> [] then
      "Policy violations were captured with explicit evidence for operational review."
      :: base
    else base
  in
  let with_recovery =
    if session.auto_resume then
      "Auto-resume policy is encoded in session state for restart resilience."
      :: with_policy
    else with_policy
  in
  let with_events =
    if checkpoints_count >= 3 then
      "Multiple checkpoints were recorded, reducing observability blind spots."
      :: with_recovery
    else with_recovery
  in
  let with_outcome =
    if done_delta_total > 0 then
      "Task throughput delta confirms team-play outcomes were captured quantitatively."
      :: with_events
    else
      "No task delta observed; report still provides timeline and operational diagnostics."
      :: with_events
  in
  let with_fallback =
    if session.fallback_task_created > 0 then
      "Fallback tasks were auto-created when team-health policy was violated."
      :: with_outcome
    else with_outcome
  in
  let recovered_events =
    List.filter
      (fun json ->
        match Yojson.Safe.Util.member "event_type" json with
        | `String "recovered_after_restart" -> true
        | _ -> false)
      events
  in
  if recovered_events <> [] then
    "Recovery path was exercised (recovered_after_restart event present)."
    :: with_fallback
  else with_fallback

let markdown_of_report ~(session : Team_session_types.session)
    ~(summary_json : Yojson.Safe.t) ~(events : Yojson.Safe.t list)
    ~(checkpoints_count : int) ~(done_delta_by_agent : (string * int) list)
    ~(team_health_json : Yojson.Safe.t)
    ~(communication_metrics_json : Yojson.Safe.t)
    ~(cascade_metrics_json : Yojson.Safe.t) ~(alert_count : int)
    ~(violation_count : int) ~(mcp_notes : string list) =
  let status = Team_session_types.status_to_string session.status in
  let open Yojson.Safe.Util in
  let elapsed =
    summary_json |> member "elapsed_sec" |> to_int_option |> Option.value ~default:0
  in
  let remaining =
    summary_json |> member "remaining_sec" |> to_int_option
    |> Option.value ~default:0
  in
  let progress =
    summary_json |> member "progress_pct" |> to_float_option
    |> Option.value ~default:0.0
  in
  let done_total =
    summary_json |> member "done_delta_total" |> to_int_option
    |> Option.value ~default:0
  in
  let health_status =
    team_health_json |> member "status" |> to_string_option
    |> Option.value ~default:"unknown"
  in
  let health_active =
    team_health_json |> member "active_agents_count" |> to_int_option
    |> Option.value ~default:0
  in
  let health_required =
    team_health_json |> member "required_agents" |> to_int_option
    |> Option.value ~default:0
  in
  let broadcast_count =
    communication_metrics_json |> member "broadcast_count" |> to_int_option
    |> Option.value ~default:0
  in
  let portal_count =
    communication_metrics_json |> member "portal_count" |> to_int_option
    |> Option.value ~default:0
  in
  let fallback_task_created =
    cascade_metrics_json |> member "fallback_task_created" |> to_int_option
    |> Option.value ~default:0
  in
  let cascade_attempted =
    cascade_metrics_json |> member "attempted" |> to_int_option
    |> Option.value ~default:0
  in
  let cascade_failed =
    cascade_metrics_json |> member "failed" |> to_int_option
    |> Option.value ~default:0
  in
  let event_lines = recent_event_lines events 12 in
  let contribution_lines =
    if done_delta_by_agent = [] then [ "- (no tracked contributors)" ]
    else
      List.map
        (fun (agent, delta) -> Printf.sprintf "- %s: %d" agent delta)
        done_delta_by_agent
  in
  let policy_lines =
    [
      Printf.sprintf "- Orchestration mode: %s"
        (Team_session_types.orchestration_mode_to_string
           session.orchestration_mode);
      Printf.sprintf "- Communication mode: %s"
        (Team_session_types.communication_mode_to_string session.communication_mode);
      Printf.sprintf "- Instruction profile: %s"
        (Team_session_types.instruction_profile_to_string
           session.instruction_profile);
      Printf.sprintf "- Fallback policy: %s"
        (Team_session_types.fallback_policy_to_string session.fallback_policy);
      Printf.sprintf "- Alert channel: %s"
        (Team_session_types.alert_channel_to_string session.alert_channel);
    ]
  in
  let risks =
    if status = "interrupted" || status = "failed" then
      [ "- Session did not finish cleanly; inspect event timeline and stop_reason." ]
    else if health_status = "critical" then
      [
        "- Team health reached critical; increase participating agents or lower min_agents threshold.";
      ]
    else if done_total = 0 then
      [
        "- No completed-task delta observed; consider tighter task decomposition.";
      ]
    else [ "- No critical runtime issues detected in this session." ]
  in
  String.concat "\n"
    [
      "# Team Session Report";
      "";
      "## Session Overview";
      Printf.sprintf "- Session ID: %s" session.session_id;
      Printf.sprintf "- Goal: %s" session.goal;
      Printf.sprintf "- Status: %s" status;
      Printf.sprintf "- Duration(seconds): %d" session.duration_seconds;
      Printf.sprintf "- Elapsed(seconds): %d" elapsed;
      Printf.sprintf "- Remaining(seconds): %d" remaining;
      Printf.sprintf "- Progress(%%): %.1f" progress;
      "";
      "## Orchestration Policy";
      String.concat "\n" policy_lines;
      "";
      "## Team Health";
      Printf.sprintf "- Health status: %s" health_status;
      Printf.sprintf "- Active agents: %d" health_active;
      Printf.sprintf "- Required agents(min_agents): %d" health_required;
      Printf.sprintf "- min_agents_violation events: %d" violation_count;
      "";
      "## Goal vs Outcome";
      Printf.sprintf "- Goal statement: %s" session.goal;
      Printf.sprintf "- Completed task delta: %d" done_total;
      (if done_total > 0 then
         "- Outcome: achieved"
       else "- Outcome: in_progress_or_inconclusive");
      "";
      "## Communication/Cascade Metrics";
      Printf.sprintf "- Broadcast count: %d" broadcast_count;
      Printf.sprintf "- Portal signal count: %d" portal_count;
      Printf.sprintf "- Alerts emitted: %d" alert_count;
      Printf.sprintf "- Cascade attempted: %d" cascade_attempted;
      Printf.sprintf "- Cascade failed: %d" cascade_failed;
      Printf.sprintf "- Fallback tasks created: %d" fallback_task_created;
      "";
      "## Team Activity Timeline";
      (if event_lines = [] then
         "- (no timeline events)"
       else String.concat "\n" event_lines);
      "";
      "## Agent Contribution";
      String.concat "\n" contribution_lines;
      "";
      "## Risks/Failures";
      String.concat "\n" risks;
      "";
      "## MCP Improvement Findings";
      String.concat "\n" (List.map (fun s -> "- " ^ s) mcp_notes);
      "";
      "## Next Actions";
      "- Review this report and convert unresolved observations into explicit backlog tasks.";
      "- If interrupted/failed, rerun with same goal and compare deltas across sessions.";
      Printf.sprintf "- Checkpoints captured: %d" checkpoints_count;
    ]

let generate config (session : Team_session_types.session) :
    (Yojson.Safe.t * string, string) result =
  try
    let events = Team_session_store.read_events ~max_events:4000 config session.session_id in
    let checkpoint_paths =
      Team_session_store.list_checkpoint_paths config session.session_id
    in
    let checkpoints_count = List.length checkpoint_paths in
    let summary_json, done_delta_total, done_delta_by_agent, active_agents,
        team_health, communication_metrics, cascade_metrics =
      summary_metrics session config
    in
    let alert_count = event_count events "alert_emitted" in
    let violation_count = event_count events "min_agents_violation" in
    let mcp_notes =
      mcp_improvements session events checkpoints_count done_delta_total
    in
    let report_json =
      `Assoc
        [
          ("session", Team_session_types.session_to_yojson session);
          ("goal", `String session.goal);
          ("duration", `Int session.duration_seconds);
          ("summary", summary_json);
          ("team_health", team_health);
          ("communication_metrics", communication_metrics);
          ("cascade_metrics", cascade_metrics);
          ( "policy",
            `Assoc
              [
                ( "orchestration_mode",
                  `String
                    (Team_session_types.orchestration_mode_to_string
                       session.orchestration_mode) );
                ( "fallback_policy",
                  `String
                    (Team_session_types.fallback_policy_to_string
                       session.fallback_policy) );
                ( "instruction_profile",
                  `String
                    (Team_session_types.instruction_profile_to_string
                       session.instruction_profile) );
                ("policy_violations", `List (List.map (fun v -> `String v) session.policy_violations));
              ] );
          ("outcomes", `Assoc [ ("completed_task_delta", `Int done_delta_total) ]);
          ("agent_metrics", Team_session_types.assoc_int_to_json done_delta_by_agent);
          ( "goal_metrics",
            `Assoc
              [
                ( "status",
                  `String
                    (if done_delta_total > 0 then "achieved"
                     else "inconclusive") );
              ] );
          ( "incidents",
            `Assoc
              [
                ("status", `String (Team_session_types.status_to_string session.status));
                ("alert_count", `Int alert_count);
                ("min_agents_violation_count", `Int violation_count);
              ] );
          ("mcp_improvements", `List (List.map (fun s -> `String s) mcp_notes));
          ( "evidence",
            `Assoc
              [
                ("events_count", `Int (List.length events));
                ("checkpoints_count", `Int checkpoints_count);
                ("active_agents", `List (List.map (fun a -> `String a) active_agents));
              ] );
        ]
    in
    let markdown =
      markdown_of_report ~session ~summary_json ~events ~checkpoints_count
        ~done_delta_by_agent ~team_health_json:team_health
        ~communication_metrics_json:communication_metrics
        ~cascade_metrics_json:cascade_metrics ~alert_count ~violation_count
        ~mcp_notes
    in
    let report_json_path =
      Team_session_store.report_json_path config session.session_id
    in
    Room_utils.write_json config report_json_path report_json;
    let report_md_path =
      Team_session_store.report_md_path config session.session_id
    in
    Team_session_store.write_text_file report_md_path markdown;
    Ok (report_json, markdown)
  with exn -> Error (Printexc.to_string exn)
