open Operator_pending_confirm
include Operator_digest_types
open Operator_digest_event

let build_worker_cards ~(session : Team_session_types.session) ~(events : Yojson.Safe.t list)
    ~now =
  let worker_keys =
    if session.planned_workers <> [] then
      session.planned_workers
      |> List.map (fun (worker : Team_session_types.planned_worker) ->
             ( worker.runtime_actor,
               Some worker.spawn_agent,
               worker.spawn_role,
               worker.spawn_model,
               Option.map Team_session_types.execution_scope_to_string
                 worker.execution_scope,
               Option.map Team_session_types.worker_class_to_string
                 worker.worker_class,
               worker.parent_actor,
               Option.map Team_session_types.capsule_mode_to_string
                 worker.capsule_mode,
               worker.runtime_pool,
               worker.lane_id,
               Option.map Team_session_types.controller_level_to_string
                 worker.controller_level,
               Option.map Team_session_types.control_domain_to_string
                 worker.control_domain,
               worker.supervisor_actor,
               Option.map Team_session_types.task_profile_to_string
                 worker.task_profile,
               Option.map Team_session_types.risk_level_to_string
                 worker.risk_level,
               worker.routing_confidence,
               worker.routing_reason ))
    else
      session.agent_names
      |> List.map (fun actor ->
               ( Some actor,
                 None,
                 None,
                 None,
                 None,
                 None,
                 None,
               None,
               None,
               None,
               None,
               None,
               None,
               None,
               None,
               None,
               None ))
  in
  worker_keys
  |> List.map
       (fun
         ( actor,
           spawn_agent,
           spawn_role,
           spawn_model,
           execution_scope,
           worker_class,
           parent_actor,
           capsule_mode,
           runtime_pool,
           lane_id,
           controller_level,
           control_domain,
           supervisor_actor,
           task_profile,
           risk_level,
           routing_confidence,
           routing_reason ) ->
         let turn_count =
           match actor with
           | Some value -> turn_count_by_actor events value
           | None -> 0
         in
         let empty_note_turn_count =
           match actor with
           | Some value -> empty_note_turn_count_for_actor events value
           | None -> 0
         in
         let has_turn = turn_count > 0 in
         let last_turn_ts_iso =
           match actor with
           | Some value -> last_turn_ts_iso_for_actor events value
           | None -> None
        in
        let last_turn_age_sec =
          match actor with
          | Some value -> last_turn_age_sec_for_actor events value ~now
          | None -> None
        in
        let status =
          match actor with
          | Some _ ->
              let bootstrap_age_sec = now -. session.started_at in
              if has_turn then (
                match last_turn_age_sec with
                | Some age when age <= int_of_float stalled_session_threshold_sec ->
                    "live"
                | Some _ -> "stale_turn"
                | None -> "seen_no_timestamp")
              else if bootstrap_age_sec >= planned_worker_turn_grace_sec then
                "planned_no_turn"
              else "grace_period"
           | None -> "planned"
         in
         let evidence_source =
           match (has_turn, last_turn_age_sec) with
           | false, _ -> "spawn_only"
           | true, Some age when age <= int_of_float stalled_session_threshold_sec ->
               "turn_live"
           | true, Some _ -> "turn_stale"
           | true, None -> "turn_seen"
         in
         {
           actor;
           spawn_agent;
           spawn_role;
           spawn_model;
           execution_scope;
           worker_class;
           parent_actor;
           capsule_mode;
           runtime_pool;
           lane_id;
           controller_level;
           control_domain;
           supervisor_actor;
           task_profile;
           risk_level;
           routing_confidence;
           routing_reason;
           status;
           turn_count;
           empty_note_turn_count;
           has_turn;
           last_turn_age_sec;
           evidence_source;
           last_turn_ts_iso;
         })
  |> List.sort compare_worker_card

let session_attention_items ~(session : Team_session_types.session)
    ~(events : Yojson.Safe.t list) ~(worker_cards : worker_card list) ~now =
  let spawn_failure_count = count_spawn_failures events in
  let detached_actor_count = count_detached_actors events in
  let empty_note_actors = empty_note_turn_actors events in
  let low_confidence_cards =
    worker_cards
    |> List.filter (fun (card : worker_card) ->
           match card.routing_confidence with
           | Some value -> value < 0.72
           | None -> false)
  in
  let escalated_worker_count =
    session.planned_workers
    |> List.fold_left
         (fun acc (worker : Team_session_types.planned_worker) ->
           if worker.routing_escalated then acc + 1 else acc)
         0
  in
  let local64_missing_roles =
    if
      session.scale_profile = Team_session_types.Scale_local64
      && session.planned_workers <> []
    then
      let present_roles =
        session.planned_workers
        |> List.filter_map (fun (worker : Team_session_types.planned_worker) ->
               Option.map Team_session_types.worker_class_to_string worker.worker_class)
      in
      [ "manager"; "metacog"; "librarian"; "scout" ]
      |> List.filter (fun role -> not (List.mem role present_roles))
    else []
  in
  let base = [] in
  let base =
    if low_confidence_cards <> [] then
      {
        kind = "low_confidence_routing";
        severity = "warn";
        summary =
          Printf.sprintf "%d worker(s) have low routing confidence"
            (List.length low_confidence_cards);
        target_type = "team_session";
        target_id = Some session.session_id;
        actor = None;
        evidence =
          `Assoc
            [
              ( "actors",
                `List
                  (List.filter_map
                     (fun (card : worker_card) ->
                       Option.map (fun actor -> `String actor) card.actor)
                     low_confidence_cards) );
            ];
      }
      :: base
    else base
  in
  let base =
    if escalated_worker_count > 0 then
      {
        kind = "routing_escalation_present";
        severity = "warn";
        summary =
          Printf.sprintf "%d worker(s) were escalated to a higher tier"
            escalated_worker_count;
        target_type = "team_session";
        target_id = Some session.session_id;
        actor = None;
        evidence = `Assoc [ ("count", `Int escalated_worker_count) ];
      }
      :: base
    else base
  in
  let base =
    if spawn_failure_count > 0 then
      {
        kind = "spawn_failure_present";
        severity = "bad";
        summary =
          Printf.sprintf "session has %d failed spawn event(s)" spawn_failure_count;
        target_type = "team_session";
        target_id = Some session.session_id;
        actor = None;
        evidence = `Assoc [ ("count", `Int spawn_failure_count) ];
      }
      :: base
    else base
  in
  let base =
    if detached_actor_count > 0 then
      {
        kind = "detached_actor_present";
        severity = "warn";
        summary =
          Printf.sprintf "session detached %d runtime actor(s)"
            detached_actor_count;
        target_type = "team_session";
        target_id = Some session.session_id;
        actor = None;
        evidence = `Assoc [ ("count", `Int detached_actor_count) ];
      }
      :: base
    else base
  in
  let base =
    if local64_missing_roles <> [] then
      {
        kind = "local64_role_gap";
        severity = "warn";
        summary =
          Printf.sprintf "local64 session is missing swarm support roles: %s"
            (String.concat ", " local64_missing_roles);
        target_type = "team_session";
        target_id = Some session.session_id;
        actor = None;
        evidence =
          `Assoc
            [
              ( "missing_roles",
                `List (List.map (fun role -> `String role) local64_missing_roles) );
            ];
      }
      :: base
    else base
  in
  let base =
    if empty_note_actors <> [] then
      {
        kind = "empty_note_turn_present";
        severity = "warn";
        summary = "session contains historical empty note turn evidence";
        target_type = "team_session";
        target_id = Some session.session_id;
        actor = None;
        evidence =
          `Assoc
            [
              ("count", `Int (List.length empty_note_actors));
              ("actors", `List (List.map (fun actor -> `String actor) empty_note_actors));
            ];
      }
      :: base
    else base
  in
  let age_since_last_turn =
    now -. Option.value ~default:session.started_at session.last_turn_at
  in
  let base =
    if session.status = Team_session_types.Running
       && session.planned_workers <> []
       && age_since_last_turn >= stalled_session_threshold_sec
    then
      {
        kind = "stalled_session";
        severity = "bad";
        summary =
          Printf.sprintf "session has been idle for %d seconds"
            (int_of_float age_since_last_turn);
        target_type = "team_session";
        target_id = Some session.session_id;
        actor = None;
        evidence =
          `Assoc
            [
              ("last_turn_age_sec", `Int (int_of_float age_since_last_turn));
              ( "last_turn_at",
                option_to_json (fun value -> `Float value) session.last_turn_at );
            ];
      }
      :: base
    else base
  in
  let no_turn_workers =
    if session.status = Team_session_types.Running
       && now -. session.started_at >= planned_worker_turn_grace_sec
    then
      worker_cards
      |> List.filter (fun (card : worker_card) ->
             String.equal card.status "planned_no_turn"
             && Option.value ~default:"" card.actor <> "")
    else []
  in
  let base =
    if no_turn_workers <> [] then
      {
        kind = "planned_worker_without_turn";
        severity = "warn";
        summary =
          Printf.sprintf "%d planned worker(s) have not recorded a turn"
            (List.length no_turn_workers);
        target_type = "team_session";
        target_id = Some session.session_id;
        actor = None;
        evidence =
          `Assoc
            [
              ( "actors",
                `List
                  (List.filter_map
                     (fun (card : worker_card) ->
                       Option.map (fun actor -> `String actor) card.actor)
                     no_turn_workers) );
            ];
      }
      :: base
    else base
  in
  List.sort compare_attention base

let session_recommendations ~(session : Team_session_types.session)
    ~(attentions : attention_item list) ~(worker_cards : worker_card list) =
  let no_turn_worker_cards =
    worker_cards
    |> List.filter (fun (card : worker_card) ->
           String.equal card.status "planned_no_turn"
           && Option.is_some card.spawn_agent)
  in
  let suggestions =
    attentions
    |> List.filter_map (fun item ->
           match item.kind with
           | "spawn_failure_present" ->
               Some
                 {
                   action_type = "team_task_inject";
                   target_type = "team_session";
                   target_id = Some session.session_id;
                   severity = item.severity;
                   reason = item.summary;
                   suggested_payload =
                     `Assoc
                       [
                         ("title", `String "Recover failed worker coverage");
                         ( "description",
                           `String
                             "Spawn failure evidence is present. Add explicit recovery work or reassign the missing worker contribution." );
                         ("priority", `Int 1);
                       ];
                 }
           | "detached_actor_present" ->
               Some
                 {
                   action_type = "team_note";
                   target_type = "team_session";
                   target_id = Some session.session_id;
                   severity = item.severity;
                   reason = item.summary;
                   suggested_payload =
                     `Assoc
                       [
                         ( "message",
                           `String
                             "[operator] A runtime actor detached. Reassign the missing work and record the replacement explicitly." );
                       ];
                 }
           | "empty_note_turn_present" ->
               Some
                 {
                   action_type = "team_note";
                   target_type = "team_session";
                   target_id = Some session.session_id;
                   severity = item.severity;
                   reason = item.summary;
                   suggested_payload =
                     `Assoc
                       [
                         ( "message",
                           `String
                             "[operator] Record explicit non-empty contribution notes for each worker turn." );
                       ];
                 }
           | "stalled_session" ->
               Some
                 {
                   action_type = "team_stop";
                   target_type = "team_session";
                   target_id = Some session.session_id;
                   severity = item.severity;
                   reason = item.summary;
                   suggested_payload =
                     `Assoc
                       [
                         ("reason", `String "stalled_session_detected");
                         ("generate_report", `Bool true);
                       ];
                 }
           | "planned_worker_without_turn" ->
               if no_turn_worker_cards = [] then
                 Some
                   {
                     action_type = "team_note";
                     target_type = "team_session";
                     target_id = Some session.session_id;
                     severity = item.severity;
                     reason = item.summary;
                     suggested_payload =
                       `Assoc
                         [
                           ( "message",
                             `String
                               "[operator] Planned workers have not reported yet. Record a concrete progress note or detach and replace the missing worker." );
                         ];
                   }
               else
                 Some
                   {
                     action_type = "team_worker_spawn_batch";
                     target_type = "team_session";
                     target_id = Some session.session_id;
                     severity = item.severity;
                     reason = item.summary;
                   suggested_payload =
                       spawn_batch_template_of_cards no_turn_worker_cards;
                   }
           | "local64_role_gap" ->
	               let missing_roles =
	                 match item.evidence |> U.member "missing_roles" with
	                 | `List xs ->
	                     xs
	                     |> List.filter_map (function
	                          | `String role when String.trim role <> "" ->
	                              Some (String.trim role)
	                          | _ -> None)
	                 | _ -> []
	               in
	               let spawn_batch =
	                 missing_roles
	                 |> List.map (fun role ->
	                        let spawn_role, capsule_mode =
	                          match role with
	                          | "manager" -> ("middle-manager", "capsule")
	                          | "metacog" -> ("metacog-observer", "capsule")
	                          | "librarian" -> ("knowledge-librarian", "capsule")
	                          | "scout" -> ("research-scout", "fresh")
	                          | other -> (other, "fresh")
	                        in
	                        `Assoc
	                          [
	                            ( "spawn_prompt",
	                              `String
	                                (Printf.sprintf
	                                   "REQUIRED: provide explicit spawn_prompt for local64 %s role"
	                                   role) );
	                            ("spawn_role", `String spawn_role);
	                            ("worker_class", `String role);
	                            ("capsule_mode", `String capsule_mode);
	                            ("runtime_pool", `String "local64");
	                          ])
	               in
	               Some
	                 {
	                   action_type = "team_worker_spawn_batch";
	                   target_type = "team_session";
	                   target_id = Some session.session_id;
	                   severity = item.severity;
	                   reason = item.summary;
	                   suggested_payload = `Assoc [ ("spawn_batch", `List spawn_batch) ];
	                 }
           | "low_confidence_routing" ->
               Some
                 {
                   action_type = "team_note";
                   target_type = "team_session";
                   target_id = Some session.session_id;
                   severity = item.severity;
                   reason = item.summary;
                   suggested_payload =
                     `Assoc
                       [
                         ( "message",
                           `String
                             "[operator] Low-confidence routing detected. Re-check ambiguous workers and escalate disputed outputs to 35B." );
                       ];
                 }
           | "routing_escalation_present" ->
               Some
                 {
                   action_type = "team_note";
                   target_type = "team_session";
                   target_id = Some session.session_id;
                   severity = item.severity;
                   reason = item.summary;
                   suggested_payload =
                     `Assoc
                       [
                         ( "message",
                           `String
                             "[operator] Tier escalation is active. Audit the escalated workers and keep final judgment on 35B." );
                       ];
                 }
	           | _ -> None)
  in
  dedup_recommendations suggestions

let health_from_attention_items (items : attention_item list) =
  if
    List.exists
      (fun (item : attention_item) -> String.equal item.severity "bad")
      items
  then "bad"
  else if items <> [] then "warn"
  else "ok"

let normalize_team_health = function
  | "healthy" -> "ok"
  | "degraded" -> "warn"
  | "critical" -> "bad"
  | other -> other

let assoc_member json field =
  match json with
  | `Assoc _ -> U.member field json
  | _ -> `Null

let nested_string_member json ~parent ~child =
  match assoc_member json parent with
  | `Assoc _ as nested -> (
      match U.member child nested with
      | `String value -> Some value
      | _ -> None)
  | _ -> None

let build_session_digest ?status_json:cached_status config (session : Team_session_types.session) ~now =
  let status_json =
    match cached_status with
    | Some s -> s
    | None ->
        (* Team_session_engine_eio removed — return empty status *)
        ignore (config, session);
        `Assoc []
  in
  let summary = assoc_member status_json "summary" in
  let team_health = assoc_member status_json "team_health" in
  let summary_member field = assoc_member summary field in
  let team_health_member field = assoc_member team_health field in
  let status_member field = assoc_member status_json field in
  let events =
    (* Team_session_store removed — return empty *)
    ignore (config, session.Team_session_types.session_id);
    []
  in
  let worker_cards = build_worker_cards ~session ~events ~now in
  let attention_items = session_attention_items ~session ~events ~worker_cards ~now in
  let recommended_actions =
    session_recommendations ~session ~attentions:attention_items ~worker_cards
  in
  let active_agent_count =
    match summary_member "active_agents" with
    | `List xs -> List.length xs
    | _ -> 0
  in
  let last_turn_age_sec =
    match session.last_turn_at with
    | Some ts -> Some (max 0 (int_of_float (now -. ts)))
    | None when session.status = Team_session_types.Running ->
        Some (max 0 (int_of_float (now -. session.started_at)))
    | None -> None
  in
  {
    session_id = session.session_id;
    goal = session.goal;
    status =
      (match nested_string_member status_json ~parent:"session" ~child:"status" with
      | Some status -> status
      | None -> Team_session_types.status_to_string session.status);
    health =
      (let attention_health = health_from_attention_items attention_items in
       if not (String.equal attention_health "ok") then attention_health
       else
         match team_health_member "status" with
         | `String status -> normalize_team_health status
         | _ -> attention_health);
    scale_profile =
      (match summary_member "scale_profile" with
      | `String value -> value
      | _ -> Team_session_types.scale_profile_to_string session.scale_profile);
    control_profile =
      (match summary_member "control_profile" with
      | `String value -> value
      | _ ->
          Team_session_types.control_profile_to_string session.control_profile);
    planned_worker_count = List.length session.planned_workers;
    active_agent_count;
    last_turn_age_sec;
    worker_class_counts =
      (match summary_member "worker_class_counts" with
      | `Assoc _ as json -> json
      | _ ->
          Team_session_types.worker_class_counts session.planned_workers
          |> Team_session_types.counts_to_json);
    runtime_pool_counts =
      (match summary_member "runtime_pool_counts" with
      | `Assoc _ as json -> json
      | _ ->
          Team_session_types.runtime_pool_counts session.planned_workers
          |> Team_session_types.counts_to_json);
    lane_counts =
      (match summary_member "lane_counts" with
      | `Assoc _ as json -> json
      | _ ->
          Team_session_types.lane_counts session.planned_workers
          |> Team_session_types.counts_to_json);
    controller_counts =
      (match summary_member "controller_counts" with
      | `Assoc _ as json -> json
      | _ ->
          Team_session_types.controller_level_counts session.planned_workers
          |> Team_session_types.counts_to_json);
    control_domain_counts =
      (match summary_member "control_domain_counts" with
      | `Assoc _ as json -> json
      | _ ->
          Team_session_types.control_domain_counts session.planned_workers
          |> Team_session_types.counts_to_json);
    task_profile_counts =
      (match summary_member "task_profile_counts" with
      | `Assoc _ as json -> json
      | _ ->
          Team_session_types.task_profile_counts session.planned_workers
          |> Team_session_types.counts_to_json);
    escalation_count =
      (match summary_member "escalation_count" with
      | `Int value -> value
      | `Intlit raw -> (Option.value ~default:0 (int_of_string_opt raw))
      | _ -> Team_session_types.escalation_count session.planned_workers);
    controller_tree =
      (match summary_member "controller_tree" with
      | `Assoc _ as json -> json
      | _ -> `Assoc []);
    lane_health =
      (match summary_member "lane_health" with
      | `Assoc _ as json -> json
      | _ -> `Assoc []);
    confidence_heatmap =
      (match summary_member "confidence_heatmap" with
      | `Assoc _ as json -> json
      | _ -> `Assoc []);
    context_pressure_by_lane =
      (match summary_member "context_pressure_by_lane" with
      | `Assoc _ as json -> json
      | _ -> `Assoc []);
    intervention_counters =
      (match summary_member "intervention_counters" with
      | `Assoc _ as json -> json
      | _ -> `Assoc []);
    local_runtime =
      (match status_member "local_runtime" with
      | `Assoc _ as json -> json
      | `Null as json -> json
      | _ -> `Null);
    attention_items;
    recommended_actions;
    worker_cards;
    risk_digest = Risk_digest.(compute ~session ~worker_cards |> to_yojson);
  }
