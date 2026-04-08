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

let delivery_contract_json (session : Team_session_types.session) =
  Option.fold ~none:`Null
    ~some:Team_session_types.delivery_contract_to_yojson
    session.delivery_contract

let latest_delivery_verdict_json (session : Team_session_types.session) =
  Option.fold ~none:`Null
    ~some:Team_session_types.delivery_verdict_to_yojson
    session.latest_delivery_verdict

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

let count_assoc_lines json =
  match json with
  | `Assoc fields ->
      fields
      |> List.sort (fun (a, _) (b, _) -> String.compare a b)
      |> List.filter_map (fun (key, value) ->
             match value with
             | `Int count -> Some (Printf.sprintf "- %s: %d" key count)
             | `Intlit raw -> Some (Printf.sprintf "- %s: %s" key raw)
             | _ -> None)
  | _ -> []

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
      "Turn-level orchestration evidence exists in the session history."
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
    ~(inference_cache_metrics_json : Yojson.Safe.t)
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
  let task_profile_counts = summary_json |> member "task_profile_counts" in
  let escalation_count =
    summary_json |> member "escalation_count" |> to_int_option
    |> Option.value ~default:0
  in
  let routing_reason_summary =
    match summary_json |> member "routing_reason_summary" with
    | `List xs ->
        xs
        |> List.filter_map Yojson.Safe.Util.to_string_option
        |> List.filter (fun value -> String.trim value <> "")
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
  let inference_cache_hits =
    inference_cache_metrics_json |> member "hits" |> to_int_option
    |> Option.value ~default:0
  in
  let inference_cache_misses =
    inference_cache_metrics_json |> member "misses" |> to_int_option
    |> Option.value ~default:0
  in
  let inference_cache_writes =
    inference_cache_metrics_json |> member "writes" |> to_int_option
    |> Option.value ~default:0
  in
  let inference_cache_bypass =
    inference_cache_metrics_json |> member "bypass" |> to_int_option
    |> Option.value ~default:0
  in
  let inference_cache_errors =
    inference_cache_metrics_json |> member "errors" |> to_int_option
    |> Option.value ~default:0
  in
  let inference_cache_hit_rate =
    inference_cache_metrics_json |> member "hit_rate" |> to_float_option
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
  let task_profile_count_lines = count_assoc_lines task_profile_counts in
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
  let delivery_contract_lines =
    match session.delivery_contract with
    | None -> [ "- Delivery contract: (not recorded)" ]
    | Some contract ->
        let acceptance =
          if contract.acceptance_checks = [] then
            [ "- Acceptance checks: (not recorded)" ]
          else
            List.map
              (fun item -> Printf.sprintf "- Acceptance: %s" item)
              contract.acceptance_checks
        in
        let artifacts =
          if contract.required_artifacts = [] then
            [ "- Required artifacts: (not recorded)" ]
          else
            List.map
              (fun item -> Printf.sprintf "- Artifact: %s" item)
              contract.required_artifacts
        in
        let evidence =
          if contract.evidence_refs = [] then
            [ "- Evidence refs: (not recorded)" ]
          else
            List.map
              (fun item -> Printf.sprintf "- Evidence ref: %s" item)
              contract.evidence_refs
        in
        [
          Printf.sprintf "- Contract ID: %s" contract.contract_id;
          Printf.sprintf "- Summary: %s"
            (if String.trim contract.summary = "" then "(not recorded)"
             else contract.summary);
          Printf.sprintf "- Repair budget: %d" contract.repair_budget;
          Printf.sprintf "- Evaluator cascade: %s" contract.evaluator_cascade;
          Printf.sprintf "- Evaluator role: %s"
            (match contract.evaluator_role with
            | Some value -> value
            | None -> "(not recorded)");
          Printf.sprintf "- Generator roles: %s"
            (match contract.generator_roles with
            | [] -> "(not recorded)"
            | xs -> String.concat ", " xs);
        ]
        @ acceptance @ artifacts @ evidence
  in
  let latest_verdict_lines =
    match session.latest_delivery_verdict with
    | None -> [ "- Latest evaluator verdict: (not recorded)" ]
    | Some verdict ->
        [
          Printf.sprintf "- Status: %s"
            (Team_session_types.delivery_verdict_status_to_string
               verdict.status);
          Printf.sprintf "- Evaluator: %s" verdict.evaluator;
          Printf.sprintf "- Evaluator cascade: %s"
            verdict.evaluator_cascade;
          Printf.sprintf "- Summary: %s"
            (if String.trim verdict.summary = "" then "(not recorded)"
             else verdict.summary);
          Printf.sprintf "- Repair directive: %s"
            (match verdict.repair_directive with
            | Some value -> value
            | None -> "(none)");
          Printf.sprintf "- Generated at: %s" verdict.generated_at_iso;
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
      "## Delivery Contract";
      String.concat "\n" delivery_contract_lines;
      "";
      "## Evaluator Verdict";
      String.concat "\n" latest_verdict_lines;
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
      Printf.sprintf "- Recorded orchestration turns: %d" turn_count;
      Printf.sprintf "- Alerts emitted: %d" alert_count;
      Printf.sprintf "- Cascade attempted: %d" cascade_attempted;
      Printf.sprintf "- Cascade failed: %d" cascade_failed;
      Printf.sprintf "- Fallback tasks created: %d" fallback_task_created;
      Printf.sprintf "- inference cache hits/misses: %d/%d" inference_cache_hits
        inference_cache_misses;
      Printf.sprintf "- inference cache writes: %d" inference_cache_writes;
      Printf.sprintf "- inference cache bypass/errors: %d/%d" inference_cache_bypass
        inference_cache_errors;
      Printf.sprintf "- inference cache hit rate: %.3f" inference_cache_hit_rate;
      "";
      "## Routing Distribution";
      Printf.sprintf "- Escalation count: %d" escalation_count;
      (if task_profile_count_lines = [] then "- Task profiles: (not recorded)"
       else String.concat "\n" task_profile_count_lines);
      (if routing_reason_summary = [] then "- Routing rationale summary: (not recorded)"
       else
         String.concat "\n"
           (List.map
              (fun reason -> Printf.sprintf "- %s" reason)
              routing_reason_summary));
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

let collect_spawn_tool_names events =
  events
  |> List.concat_map (fun json ->
         if
           List.mem
             (Yojson.Safe.Util.member "event_type" json)
             [ `String "team_step_spawn"; `String "team_step_delegate" ]
         then
           (match
              Yojson.Safe.Util.member "detail" json |> Yojson.Safe.Util.member "tool_names"
            with
           | `List xs ->
               xs
               |> List.filter_map (function
                      | `String s ->
                          let t = String.trim s in
                          if t = "" then None else Some t
                      | _ -> None)
           | _ -> [])
         else [])
  |> Team_session_types.dedup_strings

let sum_spawn_tool_call_count events =
  events
  |> List.fold_left
       (fun acc json ->
         if
           List.mem
             (Yojson.Safe.Util.member "event_type" json)
             [ `String "team_step_spawn"; `String "team_step_delegate" ]
         then
           (match
              Yojson.Safe.Util.member "detail" json |> Yojson.Safe.Util.member "tool_call_count"
            with
           | `Int n -> acc + n
           | `Intlit s -> acc + Option.value ~default:0 (int_of_string_opt s)
           | _ -> acc)
         else acc)
       0

let count_write_capable_spawns events =
  events
  |> List.fold_left
       (fun acc json ->
         if Yojson.Safe.Util.member "event_type" json = `String "team_step_spawn"
         then
           match
             Yojson.Safe.Util.member "detail" json |> Yojson.Safe.Util.member "execution_scope"
           with
           | `String "limited_code_change" -> acc + 1
           | _ -> acc
         else acc)
       0

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
    let spawn_tool_names = collect_spawn_tool_names events in
    let spawn_tool_call_count = sum_spawn_tool_call_count events in
    let write_capable_spawn_count = count_write_capable_spawns events in
    let mcp_notes =
      mcp_improvements session events checkpoints_count done_delta_total
    in
    let inference_cache_metrics = Prometheus.inference_cache_metrics_json () in
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
          ("spawn_tool_call_count", `Int spawn_tool_call_count);
          ( "spawn_tool_names",
            `List (List.map (fun value -> `String value) spawn_tool_names) );
          ("write_capable_spawn_count", `Int write_capable_spawn_count);
        ]
    in
    let report_json =
      `Assoc
        [
          ("schema_version", `String report_schema_version);
          ("session", Team_session_types.session_to_yojson session);
          ("delivery_contract", delivery_contract_json session);
          ("latest_delivery_verdict", latest_delivery_verdict_json session);
          ("goal", `String session.goal);
          ("duration", `Int session.duration_seconds);
          ("summary", summary_json);
          ("team_health", team_health);
          ("communication_metrics", communication_metrics);
          ("inference_cache_metrics", inference_cache_metrics);
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
                ("spawn_tool_call_count", `Int spawn_tool_call_count);
                ( "spawn_tool_names",
                  `List (List.map (fun value -> `String value) spawn_tool_names)
                );
                ("write_capable_spawn_count", `Int write_capable_spawn_count);
                ( "task_profile_counts",
                  match Yojson.Safe.Util.member "task_profile_counts" summary_json with
                  | `Assoc _ as json -> json
                  | _ -> `Assoc [] );
                ( "escalation_count",
                  match Yojson.Safe.Util.member "escalation_count" summary_json with
                  | `Int _ as json -> json
                  | _ -> `Int 0 );
                ( "routing_reason_summary",
                  match Yojson.Safe.Util.member "routing_reason_summary" summary_json with
                  | `List _ as json -> json
                  | _ -> `List [] );
              ] );
        ]
    in
    let markdown =
      markdown_of_report ~session ~summary_json ~events ~checkpoints_count
        ~done_delta_by_agent ~turn_count_by_agent ~team_health_json:team_health
        ~incidents_json
        ~communication_metrics_json:communication_metrics
        ~inference_cache_metrics_json:inference_cache_metrics
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
    Team_session_store.write_artifact_text config report_md_path markdown;
    Ok (report_json, markdown)
  with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Error (Printexc.to_string exn)
