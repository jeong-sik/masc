(** Team session report generation (Markdown + JSON). *)

let report_schema_version = "1.0.0"
let proof_schema_version = "1.0.0"

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
  let active_agents = Team_session_types.participant_names session in
  let planned_runtime_actors =
    Team_session_types.planned_worker_actor_names session
  in
  let planned_participants =
    Team_session_types.planned_participant_names session
  in
  let room_active_agents =
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
        ( "planned_workers",
          `List
            (List.map Team_session_types.planned_worker_to_yojson
               session.planned_workers) );
        ( "planned_runtime_actors",
          `List (List.map (fun a -> `String a) planned_runtime_actors) );
        ( "planned_participants",
          `List (List.map (fun a -> `String a) planned_participants) );
        ("room_active_agents", `List (List.map (fun a -> `String a) room_active_agents));
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

let turn_counts_by_agent events =
  let tbl = Hashtbl.create 16 in
  List.iter
    (fun json ->
      let open Yojson.Safe.Util in
      match (member "event_type" json, member "detail" json |> member "actor") with
      | `String "team_turn", `String actor ->
          let actor = String.trim actor in
          if actor <> "" then
            let count =
              match Hashtbl.find_opt tbl actor with Some n -> n | None -> 0
            in
            Hashtbl.replace tbl actor (count + 1)
      | _ -> ())
    events;
  Hashtbl.fold (fun agent count acc -> (agent, count) :: acc) tbl []
  |> List.sort (fun (a, _) (b, _) -> compare a b)

let note_message_opt_for_report json =
  let open Yojson.Safe.Util in
  match (member "event_type" json, member "detail" json |> member "kind") with
  | `String "team_turn", `String "note" -> (
      match member "detail" json |> member "message" with
      | `String message ->
          let message = String.trim message in
          if message = "" then None else Some message
      | _ -> None)
  | _ -> None

let empty_note_turn_actor_for_report json =
  let open Yojson.Safe.Util in
  match (member "event_type" json, member "detail" json |> member "kind") with
  | `String "team_turn", `String "note" -> (
      match (member "detail" json |> member "actor", note_message_opt_for_report json) with
      | `String actor, None ->
          let actor = String.trim actor in
          if actor = "" then None else Some actor
      | _ -> None)
  | _ -> None

let count_empty_note_turns_for_report events =
  List.fold_left
    (fun acc json ->
      match empty_note_turn_actor_for_report json with
      | Some _ -> acc + 1
      | None -> acc)
    0 events

let empty_note_turn_actors_for_report events =
  events |> List.filter_map empty_note_turn_actor_for_report
  |> Team_session_types.dedup_strings

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
  let with_turns =
    if session.turn_count > 0 then
      "Turn-level orchestration evidence exists via masc_team_session_turn events."
      :: with_fallback
    else with_fallback
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
    :: with_turns
  else with_turns

let spawn_failure_count_for_report events =
  List.fold_left
    (fun acc json ->
      match Yojson.Safe.Util.member "event_type" json with
      | `String "team_step_spawn" -> (
          match
            Yojson.Safe.Util.member "detail" json
            |> Yojson.Safe.Util.member "success"
          with
          | `Bool false -> acc + 1
          | _ -> acc)
      | _ -> acc)
    0 events

let failed_spawn_roster_for_report events =
  let open Yojson.Safe.Util in
  events
  |> List.filter_map (fun json ->
         match member "event_type" json with
         | `String "team_step_spawn" -> (
             match member "detail" json |> member "success" with
             | `Bool false ->
                 Some
                   (`Assoc
                     [
                       ("runtime_actor", member "detail" json |> member "runtime_actor");
                       ("spawn_agent", member "detail" json |> member "spawn_agent");
                       ("spawn_role", member "detail" json |> member "spawn_role");
                       ("spawn_model", member "detail" json |> member "spawn_model");
                       ("error", member "detail" json |> member "error");
                       ("elapsed_ms", member "detail" json |> member "elapsed_ms");
                       ("ts_iso", member "ts_iso" json);
                     ])
             | _ -> None)
         | _ -> None)

let detached_actor_roster_for_report events =
  let open Yojson.Safe.Util in
  events
  |> List.filter_map (fun json ->
         match member "event_type" json with
         | `String "session_agent_detached" ->
             Some
               (`Assoc
                 [
                   ("actor", member "detail" json |> member "actor");
                   ("reason", member "detail" json |> member "reason");
                   ("ts_iso", member "ts_iso" json);
                 ])
         | _ -> None)

let empty_note_turn_roster_for_report events =
  empty_note_turn_actors_for_report events |> List.map (fun actor -> `String actor)

let markdown_of_report ~(session : Team_session_types.session)
    ~(summary_json : Yojson.Safe.t) ~(events : Yojson.Safe.t list)
    ~(checkpoints_count : int) ~(done_delta_by_agent : (string * int) list)
    ~(turn_count_by_agent : (string * int) list)
    ~(team_health_json : Yojson.Safe.t)
    ~(incidents_json : Yojson.Safe.t)
    ~(communication_metrics_json : Yojson.Safe.t)
    ~(llm_cache_metrics_json : Yojson.Safe.t)
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
  let room_active =
    match summary_json |> member "room_active_agents" with
    | `List xs -> List.length xs
    | _ -> 0
  in
  let planned_participants =
    match summary_json |> member "planned_participants" with
    | `List xs -> List.length xs
    | _ -> health_active
  in
  let planned_workers =
    match summary_json |> member "planned_workers" with
    | `List xs -> xs
    | _ -> []
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
  let llm_cache_hits =
    llm_cache_metrics_json |> member "hits" |> to_int_option
    |> Option.value ~default:0
  in
  let llm_cache_misses =
    llm_cache_metrics_json |> member "misses" |> to_int_option
    |> Option.value ~default:0
  in
  let llm_cache_writes =
    llm_cache_metrics_json |> member "writes" |> to_int_option
    |> Option.value ~default:0
  in
  let llm_cache_bypass =
    llm_cache_metrics_json |> member "bypass" |> to_int_option
    |> Option.value ~default:0
  in
  let llm_cache_errors =
    llm_cache_metrics_json |> member "errors" |> to_int_option
    |> Option.value ~default:0
  in
  let llm_cache_hit_rate =
    llm_cache_metrics_json |> member "hit_rate" |> to_float_option
    |> Option.value ~default:0.0
  in
  let turn_count = session.turn_count in
  let cascade_attempted =
    cascade_metrics_json |> member "attempted" |> to_int_option
    |> Option.value ~default:0
  in
  let cascade_failed =
    cascade_metrics_json |> member "failed" |> to_int_option
    |> Option.value ~default:0
  in
  let event_lines = recent_event_lines events 12 in
  let contribution_agents =
    Team_session_types.dedup_strings
      (List.map fst done_delta_by_agent @ List.map fst turn_count_by_agent)
  in
  let contribution_lines =
    if contribution_agents = [] then [ "- (no tracked contributors)" ]
    else
      List.map
        (fun agent ->
          let done_delta =
            Team_session_types.assoc_find_default agent done_delta_by_agent 0
          in
          let turns =
            Team_session_types.assoc_find_default agent turn_count_by_agent 0
          in
          Printf.sprintf "- %s: turns=%d, done_delta=%d" agent turns done_delta)
        contribution_agents
  in
  let spawn_failure_count =
    match incidents_json with
    | `Assoc _ ->
        incidents_json |> member "spawn_failure_count" |> to_int_option
        |> Option.value ~default:0
    | _ -> 0
  in
  let detached_agent_count =
    match incidents_json with
    | `Assoc _ ->
        incidents_json |> member "detached_agent_count" |> to_int_option
        |> Option.value ~default:0
    | _ -> 0
  in
  let failed_spawn_roster =
    match incidents_json with
    | `Assoc _ -> (
        match incidents_json |> member "failed_spawn_roster" with
        | `List xs -> xs
        | _ -> [])
    | _ -> []
  in
  let detached_actor_roster =
    match incidents_json with
    | `Assoc _ -> (
        match incidents_json |> member "detached_actor_roster" with
        | `List xs -> xs
        | _ -> [])
    | _ -> []
  in
  let empty_note_turn_count =
    match incidents_json with
    | `Assoc _ ->
        incidents_json |> member "empty_note_turn_count" |> to_int_option
        |> Option.value ~default:0
    | _ -> 0
  in
  let empty_note_turn_actors =
    match incidents_json with
    | `Assoc _ -> (
        match incidents_json |> member "empty_note_turn_actors" with
        | `List xs -> xs
        | _ -> [])
    | _ -> []
  in
  let failed_spawn_lines =
    failed_spawn_roster
    |> List.map (fun item ->
           let runtime_actor =
             item |> member "runtime_actor" |> to_string_option
             |> Option.value ~default:"(unknown)"
           in
           let spawn_role =
             item |> member "spawn_role" |> to_string_option
             |> Option.value ~default:"(unspecified)"
           in
           let error =
             item |> member "error" |> to_string_option
             |> Option.value ~default:"(not recorded)"
           in
           Printf.sprintf "- %s | role=%s | error=%s" runtime_actor spawn_role
             error)
  in
  let detached_actor_lines =
    detached_actor_roster
    |> List.map (fun item ->
           let actor =
             item |> member "actor" |> to_string_option
             |> Option.value ~default:"(unknown)"
           in
           let reason =
             item |> member "reason" |> to_string_option
             |> Option.value ~default:"(not recorded)"
           in
           Printf.sprintf "- %s | reason=%s" actor reason)
  in
  let empty_note_turn_lines =
    empty_note_turn_actors
    |> List.map (fun item ->
           item |> to_string_option |> Option.value ~default:"(unknown)")
    |> List.map (fun actor -> Printf.sprintf "- %s" actor)
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
      Printf.sprintf "- Session participants: %d" health_active;
      Printf.sprintf "- Planned participants: %d" planned_participants;
      Printf.sprintf "- Planned workers: %d" (List.length planned_workers);
      Printf.sprintf "- Room active agents: %d" room_active;
      Printf.sprintf "- Required agents(min_agents): %d" health_required;
      Printf.sprintf "- min_agents_violation events: %d" violation_count;
      "";
      "## Spawn Failure Evidence";
      Printf.sprintf "- Failed spawn events: %d" spawn_failure_count;
      Printf.sprintf "- Detached failed actors: %d" detached_agent_count;
      (if failed_spawn_lines = [] then "- Failed spawn roster: (none)"
       else String.concat "\n" failed_spawn_lines);
      (if detached_actor_lines = [] then "- Detached actor roster: (none)"
       else String.concat "\n" detached_actor_lines);
      "";
      "## Low-Signal Turn Evidence";
      Printf.sprintf "- Empty note turns: %d" empty_note_turn_count;
      (if empty_note_turn_lines = [] then "- Empty note turn actors: (none)"
       else String.concat "\n" empty_note_turn_lines);
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
      Printf.sprintf "- Recorded turns: %d" turn_count;
      Printf.sprintf "- Alerts emitted: %d" alert_count;
      Printf.sprintf "- Cascade attempted: %d" cascade_attempted;
      Printf.sprintf "- Cascade failed: %d" cascade_failed;
      Printf.sprintf "- Fallback tasks created: %d" fallback_task_created;
      Printf.sprintf "- LLM cache hits/misses: %d/%d" llm_cache_hits
        llm_cache_misses;
      Printf.sprintf "- LLM cache writes: %d" llm_cache_writes;
      Printf.sprintf "- LLM cache bypass/errors: %d/%d" llm_cache_bypass
        llm_cache_errors;
      Printf.sprintf "- LLM cache hit rate: %.3f" llm_cache_hit_rate;
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
    let turn_count_by_agent = turn_counts_by_agent events in
    let alert_count = event_count events "alert_emitted" in
    let violation_count = event_count events "min_agents_violation" in
    let spawn_failure_count = spawn_failure_count_for_report events in
    let detached_agent_count = event_count events "session_agent_detached" in
    let empty_note_turn_count = count_empty_note_turns_for_report events in
    let failed_spawn_roster = failed_spawn_roster_for_report events in
    let detached_actor_roster = detached_actor_roster_for_report events in
    let empty_note_turn_actors = empty_note_turn_roster_for_report events in
    let mcp_notes =
      mcp_improvements session events checkpoints_count done_delta_total
    in
    let llm_cache_metrics = Prometheus.llm_cache_metrics_json () in
    let incidents_json =
      `Assoc
        [
          ("status", `String (Team_session_types.status_to_string session.status));
          ("alert_count", `Int alert_count);
          ("min_agents_violation_count", `Int violation_count);
          ("spawn_failure_count", `Int spawn_failure_count);
          ("detached_agent_count", `Int detached_agent_count);
          ("failed_spawn_roster", `List failed_spawn_roster);
          ("detached_actor_roster", `List detached_actor_roster);
          ("empty_note_turn_count", `Int empty_note_turn_count);
          ("empty_note_turn_actors", `List empty_note_turn_actors);
        ]
    in
    let report_json =
      `Assoc
        [
          ("schema_version", `String report_schema_version);
          ("session", Team_session_types.session_to_yojson session);
          ("goal", `String session.goal);
          ("duration", `Int session.duration_seconds);
          ("summary", summary_json);
          ("team_health", team_health);
          ("communication_metrics", communication_metrics);
          ("llm_cache_metrics", llm_cache_metrics);
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
          ("agent_turn_metrics", Team_session_types.assoc_int_to_json turn_count_by_agent);
          ( "goal_metrics",
            `Assoc
              [
                ( "status",
                  `String
                    (if done_delta_total > 0 then "achieved"
                     else "inconclusive") );
              ] );
          ("incidents", incidents_json);
          ("mcp_improvements", `List (List.map (fun s -> `String s) mcp_notes));
          ( "evidence",
            `Assoc
              [
                ("events_count", `Int (List.length events));
                ("checkpoints_count", `Int checkpoints_count);
                ("turn_count", `Int session.turn_count);
                ("active_agents", `List (List.map (fun a -> `String a) active_agents));
                ("spawn_failure_count", `Int spawn_failure_count);
                ("detached_agent_count", `Int detached_agent_count);
                ("empty_note_turn_count", `Int empty_note_turn_count);
              ] );
        ]
    in
    let markdown =
      markdown_of_report ~session ~summary_json ~events ~checkpoints_count
        ~done_delta_by_agent ~turn_count_by_agent ~team_health_json:team_health
        ~incidents_json
        ~communication_metrics_json:communication_metrics
        ~llm_cache_metrics_json:llm_cache_metrics
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

let bool_of_criterion evidence =
  match Yojson.Safe.Util.member "passed" evidence with
  | `Bool b -> b
  | _ -> false

let criterion name passed detail =
  `Assoc [ ("name", `String name); ("passed", `Bool passed); ("detail", `String detail) ]

let has_event_type (json : Yojson.Safe.t) expected =
  match Yojson.Safe.Util.member "event_type" json with
  | `String e -> String.equal e expected
  | _ -> false

let count_event_type events expected =
  List.fold_left
    (fun acc json -> if has_event_type json expected then acc + 1 else acc)
    0 events

let turn_actor_of_event (json : Yojson.Safe.t) =
  if has_event_type json "team_turn" then
    match
      Yojson.Safe.Util.member "detail" json |> Yojson.Safe.Util.member "actor"
    with
    | `String actor ->
        let actor = String.trim actor in
        if actor = "" then None else Some actor
    | _ -> None
  else
    None

let turn_kind_of_event (json : Yojson.Safe.t) =
  if has_event_type json "team_turn" then
    match
      Yojson.Safe.Util.member "detail" json |> Yojson.Safe.Util.member "kind"
    with
    | `String kind -> Some (String.lowercase_ascii (String.trim kind))
    | _ -> None
  else
    None

let turn_message_of_event (json : Yojson.Safe.t) =
  if has_event_type json "team_turn" then
    match
      Yojson.Safe.Util.member "detail" json |> Yojson.Safe.Util.member "message"
    with
    | `String message ->
        let message = String.trim message in
        if message = "" then None else Some message
    | _ -> None
  else
    None

let empty_note_turn_actor_of_event (json : Yojson.Safe.t) =
  match (turn_kind_of_event json, turn_actor_of_event json, turn_message_of_event json) with
  | Some "note", Some actor, None -> Some actor
  | _ -> None

let count_empty_note_turns events =
  List.fold_left
    (fun acc json ->
      match empty_note_turn_actor_of_event json with Some _ -> acc + 1 | None -> acc)
    0 events

let empty_note_turn_actors_of_events events =
  events |> List.filter_map empty_note_turn_actor_of_event
  |> Team_session_types.dedup_strings

let team_step_spawn_agent (json : Yojson.Safe.t) =
  if has_event_type json "team_step_spawn" then
    match
      Yojson.Safe.Util.member "detail" json
      |> Yojson.Safe.Util.member "spawn_agent"
    with
    | `String agent ->
        let agent = String.trim agent in
        if agent = "" then None else Some agent
    | _ -> None
  else
    None

let team_step_runtime_actor (json : Yojson.Safe.t) =
  if has_event_type json "team_step_spawn" then
    match
      Yojson.Safe.Util.member "detail" json
      |> Yojson.Safe.Util.member "runtime_actor"
    with
    | `String actor ->
        let actor = String.trim actor in
        if actor = "" then None else Some actor
    | _ -> None
  else
    None

let team_step_spawn_success (json : Yojson.Safe.t) =
  if has_event_type json "team_step_spawn" then
    match
      Yojson.Safe.Util.member "detail" json
      |> Yojson.Safe.Util.member "success"
    with
    | `Bool b -> Some b
    | _ -> None
  else
    None

let count_turn_kind events expected_kind =
  List.fold_left
    (fun acc json ->
      match turn_kind_of_event json with
      | Some kind when String.equal kind expected_kind -> acc + 1
      | _ -> acc)
    0 events

let count_spawn_success events =
  List.fold_left
    (fun acc json ->
      match team_step_spawn_success json with
      | Some true -> acc + 1
      | _ -> acc)
    0 events

let count_spawn_failure events =
  List.fold_left
    (fun acc json ->
      match team_step_spawn_success json with
      | Some false -> acc + 1
      | _ -> acc)
    0 events

let find_criterion criteria name =
  criteria
  |> List.find_opt (fun item ->
         match Yojson.Safe.Util.member "name" item with
         | `String n -> String.equal n name
         | _ -> false)
  |> Option.value ~default:(criterion name false "missing")
  |> bool_of_criterion

let all_criteria_pass criteria =
  List.for_all bool_of_criterion criteria

let make_standard_criteria ~event_started ~checkpoints_count ~turn_events
    ~communication_total ~goal_recorded ~participants_count
    ~unique_turn_actors_count ~required_turn_actors
    ~unauthorized_turn_actors ~report_json_exists ~report_md_exists
    ~done_delta_total =
  [
    criterion "session_started_event" event_started "session_started 이벤트 존재";
    criterion "checkpoint_recorded" (checkpoints_count > 0)
      (Printf.sprintf "checkpoints=%d" checkpoints_count);
    criterion "turn_or_communication_recorded"
      (turn_events > 0 || communication_total > 0)
      (Printf.sprintf "turn_events=%d communication_total=%d" turn_events
         communication_total);
    criterion "goal_recorded" goal_recorded "goal 문자열 존재";
    criterion "participants_recorded" (participants_count > 0)
      (Printf.sprintf "participants=%d" participants_count);
    criterion "multi_actor_turn_coverage"
      (unique_turn_actors_count >= required_turn_actors)
      (Printf.sprintf "unique_turn_actors=%d required_turn_actors=%d"
         unique_turn_actors_count required_turn_actors);
    criterion "turn_actor_authorized" (unauthorized_turn_actors = [])
      (if unauthorized_turn_actors = [] then
         "all turn actors are session participants"
       else
         Printf.sprintf "unauthorized=%s"
           (String.concat "," unauthorized_turn_actors));
    criterion "report_artifacts" (report_json_exists && report_md_exists)
      (Printf.sprintf "report_json=%b report_md=%b" report_json_exists
         report_md_exists);
    criterion "outcome_traceable" (done_delta_total >= 0)
      (Printf.sprintf "done_delta_total=%d" done_delta_total);
  ]

let make_strong_criteria ~required_spawn_agents ~spawn_events
    ~spawn_success_count ~unique_spawn_agents_count ~required_turn_actors
    ~min_turn_events ~turn_events ~min_communication ~communication_total
    ~vote_events ~run_deliverables ~empty_note_turn_count =
  [
    criterion "spawn_evidence_present" (spawn_events >= required_spawn_agents)
      (Printf.sprintf "spawn_events=%d required_spawn_agents=%d" spawn_events
         required_spawn_agents);
    criterion "spawn_success_observed"
      (spawn_success_count >= required_spawn_agents)
      (Printf.sprintf "spawn_success=%d required_spawn_agents=%d"
         spawn_success_count required_spawn_agents);
    criterion "spawn_actor_diversity"
      (unique_spawn_agents_count >= required_turn_actors)
      (Printf.sprintf "unique_spawn_agents=%d required_turn_actors=%d"
         unique_spawn_agents_count required_turn_actors);
    criterion "turn_volume_threshold" (turn_events >= min_turn_events)
      (Printf.sprintf "turn_events=%d min_turn_events=%d" turn_events
         min_turn_events);
    criterion "communication_volume_threshold"
      (communication_total >= min_communication)
      (Printf.sprintf "communication_total=%d min_communication=%d"
         communication_total min_communication);
    criterion "vote_evidence_present" (vote_events >= 1)
      (Printf.sprintf "vote_events=%d required>=1" vote_events);
    criterion "deliverable_evidence_present" (run_deliverables >= 1)
      (Printf.sprintf "run_deliverables=%d required>=1" run_deliverables);
    criterion "empty_note_turns_absent" (empty_note_turn_count = 0)
      (Printf.sprintf "empty_note_turn_count=%d" empty_note_turn_count);
  ]

let mandatory_ok_for_level ~proof_level criteria =
  match proof_level with
  | Team_session_types.Proof_standard ->
      find_criterion criteria "session_started_event"
      && find_criterion criteria "checkpoint_recorded"
      && find_criterion criteria "turn_or_communication_recorded"
      && find_criterion criteria "multi_actor_turn_coverage"
      && find_criterion criteria "turn_actor_authorized"
      && find_criterion criteria "report_artifacts"
  | Team_session_types.Proof_strong -> all_criteria_pass criteria

let verdict_for_level ~proof_level ~mandatory_ok =
  match proof_level with
  | Team_session_types.Proof_standard ->
      if mandatory_ok then "proved" else "insufficient_evidence"
  | Team_session_types.Proof_strong ->
      if mandatory_ok then "proved_strong" else "insufficient_evidence_strong"

let proof_profile_summary ~proof_level ~required_spawn_agents ~min_turn_events
    ~min_communication =
  `Assoc
    [
      ("proof_level", `String (Team_session_types.proof_level_to_string proof_level));
      ("required_spawn_agents", `Int required_spawn_agents);
      ("min_turn_events", `Int min_turn_events);
      ("min_communication_events", `Int min_communication);
    ]

let required_spawn_agents_for_session (session : Team_session_types.session) =
  let planned_workers = List.length session.planned_workers in
  if planned_workers > 0 then
    max 1 (min 4 planned_workers)
  else
    let participants = max 1 (List.length session.agent_names) in
    max 1 (min 4 participants)

let min_turn_events_for_session required_turn_actors =
  max 4 (required_turn_actors * 3)

let min_communication_for_session required_turn_actors =
  max 1 (required_turn_actors * 3)

let default_proof_level = Team_session_types.Proof_standard

let proof_level_of_optional_string = function
  | None -> default_proof_level
  | Some s -> Team_session_types.proof_level_of_string (String.lowercase_ascii (String.trim s))

let parse_proof_level_json_value (json : Yojson.Safe.t) =
  match Yojson.Safe.Util.member "proof_level" json with
  | `String s -> proof_level_of_optional_string (Some s)
  | _ -> default_proof_level

let parse_proof_level_arg s = proof_level_of_optional_string (Some s)

let parse_proof_level_opt = function
  | None -> default_proof_level
  | Some s -> parse_proof_level_arg s

let parse_proof_level_default () = default_proof_level

let normalize_proof_level = function
  | Team_session_types.Proof_standard -> Team_session_types.Proof_standard
  | Team_session_types.Proof_strong -> Team_session_types.Proof_strong

let resolve_proof_level ?proof_level () =
  match proof_level with
  | Some p -> normalize_proof_level p
  | None -> default_proof_level

let parse_proof_level ?proof_level () = resolve_proof_level ?proof_level ()

let proof_level_to_string = Team_session_types.proof_level_to_string

let parse_event_bool path json =
  match Yojson.Safe.Util.member path json with
  | `Bool b -> Some b
  | _ -> None

let parse_event_string path json =
  match Yojson.Safe.Util.member path json with
  | `String s ->
      let t = String.trim s in
      if t = "" then None else Some t
  | _ -> None

let parse_event_int path json =
  match Yojson.Safe.Util.member path json with
  | `Int n -> Some n
  | `Intlit s -> int_of_string_opt s
  | _ -> None

let parse_event_detail json = Yojson.Safe.Util.member "detail" json

let parse_spawn_agent json = parse_event_detail json |> parse_event_string "spawn_agent"

let parse_spawn_success json = parse_event_detail json |> parse_event_bool "success"

let parse_spawn_model json = parse_event_detail json |> parse_event_string "spawn_model"

let parse_spawn_selection_note json =
  parse_event_detail json |> parse_event_string "spawn_selection_note"

let parse_spawn_role json = parse_event_detail json |> parse_event_string "spawn_role"

let parse_spawn_error json = parse_event_detail json |> parse_event_string "error"

let parse_spawn_elapsed_ms json =
  parse_event_detail json |> parse_event_int "elapsed_ms"

let parse_detached_actor json =
  if has_event_type json "session_agent_detached" then
    parse_event_detail json |> parse_event_string "actor"
  else
    None

let parse_detached_reason json =
  if has_event_type json "session_agent_detached" then
    parse_event_detail json |> parse_event_string "reason"
  else
    None

let parse_ts_iso json = parse_event_string "ts_iso" json

let spawn_agent_of_event json =
  if has_event_type json "team_step_spawn" then parse_spawn_agent json else None

let spawn_runtime_actor_of_event json =
  if has_event_type json "team_step_spawn" then team_step_runtime_actor json
  else None

let spawn_success_of_event json =
  if has_event_type json "team_step_spawn" then parse_spawn_success json else None

let spawn_model_of_event json =
  if has_event_type json "team_step_spawn" then parse_spawn_model json else None

let spawn_selection_note_of_event json =
  if has_event_type json "team_step_spawn" then parse_spawn_selection_note json
  else None

let collect_spawn_agents events =
  events |> List.filter_map spawn_agent_of_event |> Team_session_types.dedup_strings

let collect_spawn_runtime_actors events =
  events |> List.filter_map spawn_runtime_actor_of_event
  |> Team_session_types.dedup_strings

let collect_spawn_models events =
  events |> List.filter_map spawn_model_of_event |> Team_session_types.dedup_strings

let collect_spawn_selection_notes events =
  events |> List.filter_map spawn_selection_note_of_event
  |> Team_session_types.dedup_strings

let failed_spawn_roster_of_events events =
  events
  |> List.filter_map (fun json ->
         match team_step_spawn_success json with
         | Some false ->
             Some
               (`Assoc
                 [
                   ( "runtime_actor",
                     Option.fold ~none:`Null ~some:(fun s -> `String s)
                       (team_step_runtime_actor json) );
                   ( "spawn_agent",
                     Option.fold ~none:`Null ~some:(fun s -> `String s)
                       (parse_spawn_agent json) );
                   ( "spawn_role",
                     Option.fold ~none:`Null ~some:(fun s -> `String s)
                       (parse_spawn_role json) );
                   ( "spawn_model",
                     Option.fold ~none:`Null ~some:(fun s -> `String s)
                       (parse_spawn_model json) );
                   ( "error",
                     Option.fold ~none:`Null ~some:(fun s -> `String s)
                       (parse_spawn_error json) );
                   ( "elapsed_ms",
                     Option.fold ~none:`Null ~some:(fun n -> `Int n)
                       (parse_spawn_elapsed_ms json) );
                   ( "ts_iso",
                     Option.fold ~none:`Null ~some:(fun s -> `String s)
                       (parse_ts_iso json) );
                 ])
         | _ -> None)

let detached_actor_roster_of_events events =
  events
  |> List.filter_map (fun json ->
         match parse_detached_actor json with
         | Some actor ->
             Some
               (`Assoc
                 [
                   ("actor", `String actor);
                   ( "reason",
                     Option.fold ~none:`Null ~some:(fun s -> `String s)
                       (parse_detached_reason json) );
                   ( "ts_iso",
                     Option.fold ~none:`Null ~some:(fun s -> `String s)
                       (parse_ts_iso json) );
                 ])
         | None -> None)

let proof_level_name proof_level = proof_level_to_string proof_level

let proof_kind_summary proof_level =
  match proof_level with
  | Team_session_types.Proof_standard -> "standard"
  | Team_session_types.Proof_strong -> "strong"

let proof_profile_title proof_level =
  match proof_level with
  | Team_session_types.Proof_standard -> "Standard Proof"
  | Team_session_types.Proof_strong -> "Strong Proof"

let proof_profile_description proof_level =
  match proof_level with
  | Team_session_types.Proof_standard ->
      "Baseline evidence requirements for team session traceability."
  | Team_session_types.Proof_strong ->
      "Strict evidence requirements for multi-agent spawned collaboration."

let proof_profile_meta proof_level =
  `Assoc
    [
      ("name", `String (proof_profile_title proof_level));
      ("level", `String (proof_kind_summary proof_level));
      ("description", `String (proof_profile_description proof_level));
    ]

let proof_profile proof_level = proof_profile_meta proof_level

let proof_metadata ~proof_level ~required_spawn_agents ~min_turn_events
    ~min_communication =
  `Assoc
    [
      ("profile", proof_profile proof_level);
      ("thresholds", proof_profile_summary ~proof_level ~required_spawn_agents ~min_turn_events ~min_communication);
    ]

let proof_markdown ~(session : Team_session_types.session)
    ~(proof_level : Team_session_types.proof_level)
    ~(score_pct : float) ~(verdict : string) ~(criteria : Yojson.Safe.t list)
    ~(checkpoints_count : int) ~(events_count : int) ~(turn_events : int)
    ~(report_exists : bool) ~(unique_turn_actors_count : int)
    ~(required_turn_actors : int) ~(spawn_models : string list)
    ~(spawn_failure_count : int) ~(detached_agent_count : int)
    ~(empty_note_turn_count : int)
    ~(failed_spawn_roster : Yojson.Safe.t list)
    ~(empty_note_turn_actors : string list)
    ~(detached_actor_roster : Yojson.Safe.t list)
    ~(planned_workers : Team_session_types.planned_worker list)
    ~(unique_spawn_runtime_actors_count : int)
    ~(spawn_selection_note_summary : string option)
    ~(proof_generated_at_iso : string) =
  let criteria_lines =
    criteria
    |> List.map (fun item ->
           let open Yojson.Safe.Util in
           let name =
             item |> member "name" |> to_string_option
             |> Option.value ~default:"unknown"
           in
           let passed =
             item |> member "passed" |> to_bool_option |> Option.value ~default:false
           in
           let detail =
             item |> member "detail" |> to_string_option
             |> Option.value ~default:""
           in
           let status = if passed then "PASS" else "FAIL" in
           Printf.sprintf "- [%s] %s%s" status name
             (if detail = "" then "" else " - " ^ detail))
  in
  let planned_worker_lines =
    planned_workers
    |> List.map (fun worker ->
           let role =
             Option.value ~default:"(unspecified)"
               (Option.map String.trim worker.Team_session_types.spawn_role)
           in
           let model =
             Option.value ~default:"(default)"
               (Option.map String.trim worker.Team_session_types.spawn_model)
           in
           let actor =
             Option.value ~default:"(pending)"
               (Option.map String.trim worker.Team_session_types.runtime_actor)
           in
           Printf.sprintf "- %s | role=%s | model=%s | runtime_actor=%s"
             worker.Team_session_types.spawn_agent role model actor)
  in
  let failed_spawn_lines =
    failed_spawn_roster
    |> List.map (fun item ->
           let open Yojson.Safe.Util in
           let runtime_actor =
             item |> member "runtime_actor" |> to_string_option
             |> Option.value ~default:"(unknown)"
           in
           let spawn_agent =
             item |> member "spawn_agent" |> to_string_option
             |> Option.value ~default:"(unknown)"
           in
           let spawn_role =
             item |> member "spawn_role" |> to_string_option
             |> Option.value ~default:"(unspecified)"
           in
           let spawn_model =
             item |> member "spawn_model" |> to_string_option
             |> Option.value ~default:"(unknown)"
           in
           let error =
             item |> member "error" |> to_string_option
             |> Option.value ~default:"(not recorded)"
           in
           let elapsed_ms =
             item |> member "elapsed_ms" |> to_int_option
             |> Option.map string_of_int
             |> Option.value ~default:"?"
           in
           Printf.sprintf
             "- %s | agent=%s | role=%s | model=%s | elapsed_ms=%s | error=%s"
             runtime_actor spawn_agent spawn_role spawn_model elapsed_ms error)
  in
  let detached_actor_lines =
    detached_actor_roster
    |> List.map (fun item ->
           let open Yojson.Safe.Util in
           let actor =
             item |> member "actor" |> to_string_option
             |> Option.value ~default:"(unknown)"
           in
           let reason =
             item |> member "reason" |> to_string_option
             |> Option.value ~default:"(not recorded)"
           in
           Printf.sprintf "- %s | reason=%s" actor reason)
  in
  let empty_note_turn_lines =
    empty_note_turn_actors |> List.map (fun actor -> Printf.sprintf "- %s" actor)
  in
  String.concat "\n"
    [
      "# Team Session Proof";
      "";
      "## Verdict";
      Printf.sprintf "- Session ID: %s" session.session_id;
      Printf.sprintf "- Proof level: %s"
        (Team_session_types.proof_level_to_string proof_level);
      Printf.sprintf "- Verdict: %s" verdict;
      Printf.sprintf "- Score(%%): %.1f" score_pct;
      Printf.sprintf "- Generated at: %s" proof_generated_at_iso;
      "";
      "## Evidence Summary";
      Printf.sprintf "- Events count: %d" events_count;
      Printf.sprintf "- Checkpoints count: %d" checkpoints_count;
      Printf.sprintf "- Turn events count: %d" turn_events;
      Printf.sprintf "- Unique turn actors: %d (required >= %d)"
        unique_turn_actors_count required_turn_actors;
      Printf.sprintf "- Planned workers: %d" (List.length planned_workers);
      Printf.sprintf "- Unique spawned runtime actors: %d"
        unique_spawn_runtime_actors_count;
      Printf.sprintf "- Failed spawn events: %d" spawn_failure_count;
      Printf.sprintf "- Detached failed actors: %d" detached_agent_count;
      Printf.sprintf "- Empty note turns: %d" empty_note_turn_count;
      Printf.sprintf "- Spawn models: %s"
        (match spawn_models with
        | [] -> "(not recorded)"
        | xs -> String.concat ", " xs);
      Printf.sprintf "- Model selection rationale: %s"
        (match spawn_selection_note_summary with
        | Some note -> note
        | None -> "(not recorded)");
      Printf.sprintf "- Report artifacts exist: %b" report_exists;
      "";
      "## Planned Worker Roster";
      (if planned_worker_lines = [] then "- (not recorded)"
       else String.concat "\n" planned_worker_lines);
      "";
      "## Failed Spawn Roster";
      (if failed_spawn_lines = [] then "- (none)"
       else String.concat "\n" failed_spawn_lines);
      "";
      "## Detached Failed Actors";
      (if detached_actor_lines = [] then "- (none)"
       else String.concat "\n" detached_actor_lines);
      "";
      "## Low-Signal Note Turns";
      (if empty_note_turn_lines = [] then "- (none)"
       else String.concat "\n" empty_note_turn_lines);
      "";
      "## Criteria";
      (if criteria_lines = [] then "- (no criteria)"
       else String.concat "\n" criteria_lines);
    ]

let generate_proof ?(proof_level = default_proof_level) config
    (session : Team_session_types.session) :
    (Yojson.Safe.t * string, string) result =
  try
    let proof_level = resolve_proof_level ~proof_level () in
    let events =
      Team_session_store.read_events ~max_events:5000 config session.session_id
    in
    let checkpoints_count =
      Team_session_store.list_checkpoint_paths config session.session_id
      |> List.length
    in
    let event_started = List.exists (fun json -> has_event_type json "session_started") events in
    let turn_events = count_event_type events "team_turn" in
    let turn_actors =
      events |> List.filter_map turn_actor_of_event
      |> Team_session_types.dedup_strings
    in
    let unique_turn_actors_count = List.length turn_actors in
    let required_turn_actors =
      let participants = max 1 (List.length session.agent_names) in
      max 1 (min session.min_agents participants)
    in
    let unauthorized_turn_actors =
      List.filter
        (fun actor ->
          not
            (String.equal actor session.created_by
            || List.exists (String.equal actor) session.agent_names))
        turn_actors
    in
    let report_json_exists =
      Room_utils.path_exists config
        (Team_session_store.report_json_path config session.session_id)
    in
    let report_md_exists =
      Room_utils.path_exists config
        (Team_session_store.report_md_path config session.session_id)
    in
    let communication_total = session.broadcast_count + session.portal_count in
    let done_delta_total =
      match session.final_done_delta_total with
      | Some n -> n
      | None ->
          let backlog = Room.read_backlog config in
          let current_done = Team_session_types.done_counts_from_backlog backlog in
          Team_session_types.done_delta_by_agent ~baseline:session.baseline_done_counts
            ~current:current_done ~agents:session.agent_names
          |> List.fold_left (fun acc (_, n) -> acc + n) 0
    in
    let participants_count = List.length session.agent_names in
    let goal_recorded = String.trim session.goal <> "" in
    let standard_criteria =
      make_standard_criteria ~event_started ~checkpoints_count ~turn_events
        ~communication_total ~goal_recorded ~participants_count
        ~unique_turn_actors_count ~required_turn_actors
        ~unauthorized_turn_actors ~report_json_exists ~report_md_exists
        ~done_delta_total
    in
    let required_spawn_agents = required_spawn_agents_for_session session in
    let spawn_events = count_event_type events "team_step_spawn" in
    let spawn_success_count = count_spawn_success events in
    let spawn_failure_count = count_spawn_failure events in
    let unique_spawn_agents =
      collect_spawn_agents events |> Team_session_types.dedup_strings
    in
    let unique_spawn_agents_count = List.length unique_spawn_agents in
    let unique_spawn_runtime_actors =
      collect_spawn_runtime_actors events
      |> Team_session_types.dedup_strings
    in
    let unique_spawn_runtime_actors_count =
      List.length unique_spawn_runtime_actors
    in
    let spawn_models = collect_spawn_models events in
    let spawn_selection_notes = collect_spawn_selection_notes events in
    let spawn_selection_note_summary =
      match spawn_selection_notes with
      | [] -> None
      | xs -> Some (String.concat " | " xs)
    in
    let failed_spawn_roster = failed_spawn_roster_of_events events in
    let empty_note_turn_count = count_empty_note_turns events in
    let empty_note_turn_actors = empty_note_turn_actors_of_events events in
    let detached_actor_roster = detached_actor_roster_of_events events in
    let detached_agent_count = count_event_type events "session_agent_detached" in
    let min_turn_events = min_turn_events_for_session required_turn_actors in
    let min_communication = min_communication_for_session required_turn_actors in
    let vote_events =
      count_event_type events "team_vote_created"
      + count_event_type events "team_vote_cast"
    in
    let run_deliverables = count_event_type events "team_run_deliverable" in
    let criteria =
      match proof_level with
      | Team_session_types.Proof_standard -> standard_criteria
      | Team_session_types.Proof_strong ->
          standard_criteria
          @ make_strong_criteria ~required_spawn_agents ~spawn_events
              ~spawn_success_count
              ~unique_spawn_agents_count:
                (max unique_spawn_agents_count unique_spawn_runtime_actors_count)
              ~required_turn_actors ~min_turn_events ~turn_events
              ~min_communication ~communication_total ~vote_events
              ~run_deliverables ~empty_note_turn_count
    in
    let total = max 1 (List.length criteria) in
    let passed =
      List.fold_left
        (fun acc item -> if bool_of_criterion item then acc + 1 else acc)
        0 criteria
    in
    let score_pct = (100.0 *. float_of_int passed) /. float_of_int total in
    let mandatory_ok = mandatory_ok_for_level ~proof_level criteria in
    let verdict = verdict_for_level ~proof_level ~mandatory_ok in
    let generated_at_iso = Types.now_iso () in
    let proof_json =
      `Assoc
        [
          ("schema_version", `String proof_schema_version);
          ("session_id", `String session.session_id);
          ("goal", `String session.goal);
          ("status", `String (Team_session_types.status_to_string session.status));
          ("proof_level", `String (Team_session_types.proof_level_to_string proof_level));
          ("verdict", `String verdict);
          ("score_pct", `Float score_pct);
          ("criteria", `List criteria);
          ( "proof_profile",
            proof_metadata ~proof_level ~required_spawn_agents
              ~min_turn_events ~min_communication );
          ( "evidence",
            `Assoc
              [
                ("events_count", `Int (List.length events));
                ("checkpoints_count", `Int checkpoints_count);
                ("turn_events", `Int turn_events);
                ("unique_turn_actors", `List (List.map (fun a -> `String a) turn_actors));
                ("unique_turn_actors_count", `Int unique_turn_actors_count);
                ("required_turn_actors", `Int required_turn_actors);
                ("spawn_events", `Int spawn_events);
                ("spawn_success_count", `Int spawn_success_count);
                ("spawn_failure_count", `Int spawn_failure_count);
                ("failed_spawn_roster", `List failed_spawn_roster);
                ("empty_note_turn_count", `Int empty_note_turn_count);
                ("empty_note_turn_actors", `List (List.map (fun actor -> `String actor) empty_note_turn_actors));
                ("unique_spawn_agents", `List (List.map (fun a -> `String a) unique_spawn_agents));
                ("unique_spawn_agents_count", `Int unique_spawn_agents_count);
                ( "unique_spawn_runtime_actors",
                  `List
                    (List.map (fun a -> `String a) unique_spawn_runtime_actors) );
                ( "unique_spawn_runtime_actors_count",
                  `Int unique_spawn_runtime_actors_count );
                ( "planned_workers",
                  `List
                    (List.map Team_session_types.planned_worker_to_yojson
                       session.planned_workers) );
                ("planned_worker_count", `Int (List.length session.planned_workers));
                ("spawn_models", `List (List.map (fun m -> `String m) spawn_models));
                ( "spawn_selection_notes",
                  `List (List.map (fun note -> `String note) spawn_selection_notes)
                );
                ( "spawn_selection_note_summary",
                  Option.fold ~none:`Null ~some:(fun note -> `String note)
                    spawn_selection_note_summary );
                ("detached_agent_count", `Int detached_agent_count);
                ("detached_actor_roster", `List detached_actor_roster);
                ("vote_events", `Int vote_events);
                ("run_deliverables", `Int run_deliverables);
                ("broadcast_count", `Int session.broadcast_count);
                ("portal_count", `Int session.portal_count);
                ("done_delta_total", `Int done_delta_total);
                ("report_json_exists", `Bool report_json_exists);
                ("report_md_exists", `Bool report_md_exists);
              ] );
          ("generated_at_iso", `String generated_at_iso);
        ]
    in
    let markdown =
      proof_markdown ~session ~proof_level ~score_pct ~verdict ~criteria
        ~checkpoints_count ~events_count:(List.length events) ~turn_events
        ~report_exists:(report_json_exists && report_md_exists)
        ~unique_turn_actors_count ~required_turn_actors ~spawn_models
        ~spawn_failure_count ~detached_agent_count ~empty_note_turn_count
        ~failed_spawn_roster ~empty_note_turn_actors ~detached_actor_roster
        ~planned_workers:session.planned_workers
        ~unique_spawn_runtime_actors_count
        ~spawn_selection_note_summary
        ~proof_generated_at_iso:generated_at_iso
    in
    Ok (proof_json, markdown)
  with exn -> Error (Printexc.to_string exn)
