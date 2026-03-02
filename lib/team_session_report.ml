(** Team session report generation (Markdown + JSON). *)

let done_counts_from_backlog (backlog : Types.backlog) : (string * int) list =
  let tbl = Hashtbl.create 16 in
  let bump agent =
    let v = match Hashtbl.find_opt tbl agent with Some n -> n | None -> 0 in
    Hashtbl.replace tbl agent (v + 1)
  in
  List.iter
    (fun (task : Types.task) ->
      match task.task_status with
      | Types.Done { assignee; _ } -> bump assignee
      | _ -> ())
    backlog.tasks;
  Hashtbl.fold (fun k v acc -> (k, v) :: acc) tbl [] |> List.sort (fun (a, _) (b, _) -> compare a b)

let assoc_find_default k pairs default =
  match List.assoc_opt k pairs with Some v -> v | None -> default

let compute_done_delta ~(baseline : (string * int) list) ~(current : (string * int) list)
    ~(agents : string list) =
  let normalized_agents =
    let rec dedup acc = function
      | [] -> List.rev acc
      | x :: xs -> if List.mem x acc then dedup acc xs else dedup (x :: acc) xs
    in
    dedup [] agents
  in
  let from_agents =
    List.map
      (fun agent ->
        let base = assoc_find_default agent baseline 0 in
        let now = assoc_find_default agent current 0 in
        (agent, max 0 (now - base)))
      normalized_agents
  in
  let extra_agents =
    current
    |> List.filter (fun (agent, _) -> not (List.mem_assoc agent baseline))
    |> List.filter (fun (agent, _) -> not (List.mem_assoc agent from_agents))
  in
  (from_agents @ extra_agents)
  |> List.sort (fun (a, _) (b, _) -> compare a b)

let summary_metrics (session : Team_session_types.session) config =
  let backlog = Room.read_backlog config in
  let current_done = done_counts_from_backlog backlog in
  let delta_by_agent =
    compute_done_delta ~baseline:session.baseline_done_counts ~current:current_done
      ~agents:session.agent_names
  in
  let done_delta_total = List.fold_left (fun acc (_, n) -> acc + n) 0 delta_by_agent in
  let now = Time_compat.now () in
  let end_time = Option.value session.stopped_at ~default:now in
  let elapsed = max 0.0 (end_time -. session.started_at) in
  let remaining = max 0.0 (session.planned_end_at -. now) in
  let progress_pct =
    if session.duration_seconds <= 0 then 100.0
    else
      min 100.0
        (100.0 *. (elapsed /. float_of_int session.duration_seconds))
  in
  let active_agents =
    Room.get_agents_raw config
    |> List.map (fun (a : Types.agent) -> a.name)
    |> List.sort String.compare
  in
  (`Assoc [
      ("elapsed_sec", `Int (int_of_float elapsed));
      ("remaining_sec", `Int (int_of_float remaining));
      ("progress_pct", `Float progress_pct);
      ("done_delta_total", `Int done_delta_total);
      ("done_delta_by_agent", Team_session_types.assoc_int_to_json delta_by_agent);
      ("active_agents", `List (List.map (fun a -> `String a) active_agents));
    ],
   done_delta_total,
   delta_by_agent,
   active_agents)

let recent_event_lines events limit =
  let rev = List.rev events in
  let rec take n acc = function
    | [] -> List.rev acc
    | _ when n <= 0 -> List.rev acc
    | x :: xs -> take (n - 1) (x :: acc) xs
  in
  take limit [] rev
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
      "Session lifecycle is now first-class via start/status/stop/report APIs.";
      "Periodic checkpoints and final reports improve handoff quality for long runs.";
    ]
  in
  let with_recovery =
    if session.auto_resume then
      "Auto-resume policy is encoded in session state for restart resilience." :: base
    else base
  in
  let with_events =
    if checkpoints_count >= 3 then
      "Multiple checkpoints were recorded, reducing observability blind spots." :: with_recovery
    else with_recovery
  in
  let with_outcome =
    if done_delta_total > 0 then
      "Task throughput delta confirms team-play outcomes were captured quantitatively."
      :: with_events
    else "No task delta observed; report still provides timeline and operational diagnostics." :: with_events
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
    "Recovery path was exercised (recovered_after_restart event present)." :: with_outcome
  else with_outcome

let markdown_of_report
    ~(session : Team_session_types.session)
    ~(summary_json : Yojson.Safe.t)
    ~(events : Yojson.Safe.t list)
    ~(checkpoints_count : int)
    ~(done_delta_by_agent : (string * int) list)
    ~(mcp_notes : string list) =
  let status = Team_session_types.status_to_string session.status in
  let open Yojson.Safe.Util in
  let elapsed = summary_json |> member "elapsed_sec" |> to_int_option |> Option.value ~default:0 in
  let remaining = summary_json |> member "remaining_sec" |> to_int_option |> Option.value ~default:0 in
  let progress = summary_json |> member "progress_pct" |> to_float_option |> Option.value ~default:0.0 in
  let done_total = summary_json |> member "done_delta_total" |> to_int_option |> Option.value ~default:0 in
  let event_lines = recent_event_lines events 12 in
  let contribution_lines =
    if done_delta_by_agent = [] then ["- (no tracked contributors)"]
    else
      List.map (fun (agent, delta) -> Printf.sprintf "- %s: %d" agent delta) done_delta_by_agent
  in
  let risks =
    if status = "interrupted" || status = "failed" then
      ["- Session did not finish cleanly; inspect event timeline and stop_reason."]
    else if done_total = 0 then
      ["- No completed-task delta observed; consider tighter task decomposition."]
    else
      ["- No critical runtime issues detected in this session."]
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
      "## Goal vs Outcome";
      Printf.sprintf "- Goal statement: %s" session.goal;
      Printf.sprintf "- Completed task delta: %d" done_total;
      (if done_total > 0 then "- Outcome: achieved" else "- Outcome: in_progress_or_inconclusive");
      "";
      "## Team Activity Timeline";
      (if event_lines = [] then "- (no timeline events)" else String.concat "\n" event_lines);
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

let generate config (session : Team_session_types.session) : (Yojson.Safe.t * string, string) result =
  try
    let events = Team_session_store.read_events config session.session_id in
    let checkpoint_paths = Team_session_store.list_checkpoint_paths config session.session_id in
    let checkpoints_count = List.length checkpoint_paths in
    let (summary_json, done_delta_total, done_delta_by_agent, active_agents) =
      summary_metrics session config
    in
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
          ("outcomes", `Assoc [ ("completed_task_delta", `Int done_delta_total) ]);
          ("agent_metrics", Team_session_types.assoc_int_to_json done_delta_by_agent);
          ("goal_metrics", `Assoc [ ("status", `String (if done_delta_total > 0 then "achieved" else "inconclusive")) ]);
          ("incidents", `Assoc [ ("status", `String (Team_session_types.status_to_string session.status)) ]);
          ("mcp_improvements", `List (List.map (fun s -> `String s) mcp_notes));
          ("evidence", `Assoc [
            ("events_count", `Int (List.length events));
            ("checkpoints_count", `Int checkpoints_count);
            ("active_agents", `List (List.map (fun a -> `String a) active_agents));
          ]);
        ]
    in
    let markdown =
      markdown_of_report ~session ~summary_json ~events ~checkpoints_count
        ~done_delta_by_agent ~mcp_notes
    in
    let report_json_path = Team_session_store.report_json_path config session.session_id in
    Room_utils.write_json config report_json_path report_json;
    let report_md_path = Team_session_store.report_md_path config session.session_id in
    Team_session_store.write_text_file report_md_path markdown;
    Ok (report_json, markdown)
  with exn -> Error (Printexc.to_string exn)
