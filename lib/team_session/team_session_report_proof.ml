(** Team_session_report_proof — proof markdown generation and generate_proof entry point. *)

include Team_session_report_proof_helpers

let string_member_opt key (json : Yojson.Safe.t) =
  match Yojson.Safe.Util.member key json with
  | `String value when String.trim value <> "" -> Some value
  | _ -> None

let string_list_member key (json : Yojson.Safe.t) =
  match Yojson.Safe.Util.member key json with
  | `List items ->
      items
      |> List.filter_map (function
             | `String value when String.trim value <> "" -> Some value
             | _ -> None)
  | _ -> []

let worker_proof_refs config session_id =
  Team_session_store.list_worker_run_ids config session_id
  |> List.filter_map (fun worker_run_id ->
         let proof_path =
           Team_session_store.worker_run_proof_path config session_id
             worker_run_id
         in
         if not (Room_utils.path_exists config proof_path) then
           None
         else
           try
             let proof_json = Room_utils.read_json config proof_path in
             let meta_path =
               Team_session_store.worker_run_meta_path config session_id
                 worker_run_id
             in
             let meta_json =
               if Room_utils.path_exists config meta_path then
                 Some (Room_utils.read_json config meta_path)
               else None
             in
             let run_id =
               match string_member_opt "run_id" proof_json with
               | Some value -> value
               | None -> worker_run_id
             in
             Some
               (`Assoc
                 [
                   ("worker_run_id", `String worker_run_id);
                   ("cdal_run_id", `String run_id);
                   ( "worker_name",
                     match meta_json with
                     | Some meta -> (
                         match string_member_opt "worker_name" meta with
                         | Some value -> `String value
                         | None -> `Null)
                     | None -> `Null );
                   ( "contract_id",
                     match string_member_opt "contract_id" proof_json with
                     | Some value -> `String value
                     | None -> `Null );
                   ( "result_status",
                     match string_member_opt "result_status" proof_json with
                     | Some value -> `String value
                     | None -> `Null );
                   ("proof_path", `String proof_path);
                   ("meta_path", `String meta_path);
                   ( "manifest_ref",
                     `String
                       (Agent_sdk.Proof_store.make_ref ~run_id
                          ~subpath:"manifest.json") );
                   ( "contract_ref",
                     `String
                       (Agent_sdk.Proof_store.make_ref ~run_id
                          ~subpath:"contract.json") );
                   ( "tool_trace_refs",
                     `List
                       (List.map (fun ref_ -> `String ref_)
                          (string_list_member "tool_trace_refs" proof_json)) );
                   ( "raw_evidence_refs",
                     `List
                       (List.map (fun ref_ -> `String ref_)
                          (string_list_member "raw_evidence_refs" proof_json)) );
                   ( "checkpoint_ref",
                     match string_member_opt "checkpoint_ref" proof_json with
                     | Some value -> `String value
                     | None -> `Null );
                 ])
           with exn ->
             Log.Session.warn
               "team_session_report_proof: skipping malformed worker proof json for %s/%s: %s"
               session_id worker_run_id (Printexc.to_string exn);
             None)

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
           let tier =
             Option.value ~default:"(unspecified)"
               (Option.map Team_session_types.model_tier_to_string
                  worker.Team_session_types.model_tier)
           in
           let profile =
             Option.value ~default:"(unspecified)"
               (Option.map Team_session_types.task_profile_to_string
                  worker.Team_session_types.task_profile)
           in
           let risk =
             Option.value ~default:"(unspecified)"
               (Option.map Team_session_types.risk_level_to_string
                  worker.Team_session_types.risk_level)
           in
           let confidence =
             match worker.Team_session_types.routing_confidence with
             | Some value -> Printf.sprintf "%.2f" value
             | None -> "(unspecified)"
           in
           let reason =
             Option.value ~default:"(not recorded)"
               worker.Team_session_types.routing_reason
           in
           Printf.sprintf
             "- %s | role=%s | model=%s | runtime_actor=%s | tier=%s | profile=%s | risk=%s | confidence=%s | reason=%s"
             worker.Team_session_types.spawn_agent role model actor tier
             profile risk confidence reason)
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
        [
          Printf.sprintf "- Contract ID: %s" contract.contract_id;
          Printf.sprintf "- Summary: %s"
            (if String.trim contract.summary = "" then "(not recorded)"
             else contract.summary);
          Printf.sprintf "- Repair budget: %d" contract.repair_budget;
          Printf.sprintf "- Evaluator cascade: %s" contract.evaluator_cascade;
          Printf.sprintf "- Generator roles: %s"
            (match contract.generator_roles with
            | [] -> "(not recorded)"
            | xs -> String.concat ", " xs);
        ]
        @ acceptance @ artifacts
  in
  let latest_delivery_verdict_lines =
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
        ]
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
      Printf.sprintf "- Escalations: %d"
        (Team_session_types.escalation_count planned_workers);
      Printf.sprintf "- Spawn models: %s"
        (match spawn_models with
        | [] -> "(not recorded)"
       | xs -> String.concat ", " xs);
      Printf.sprintf "- Model tier counts: %s"
        (let pairs = Team_session_types.model_tier_counts planned_workers in
         if pairs = [] then
           "(not recorded)"
         else
           pairs
           |> List.map (fun (key, count) -> Printf.sprintf "%s=%d" key count)
           |> String.concat ", ");
      Printf.sprintf "- Task profile counts: %s"
        (let pairs = Team_session_types.task_profile_counts planned_workers in
         if pairs = [] then
           "(not recorded)"
         else
           pairs
           |> List.map (fun (key, count) -> Printf.sprintf "%s=%d" key count)
           |> String.concat ", ");
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
      "## Delivery Contract";
      String.concat "\n" delivery_contract_lines;
      "";
      "## Evaluator Verdict";
      String.concat "\n" latest_delivery_verdict_lines;
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
        ~done_delta_total ()
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
    let spawn_tool_names = collect_spawn_tool_names events in
    let spawn_tool_call_count = sum_spawn_tool_call_count events in
    let write_capable_spawn_count = count_write_capable_spawns events in
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
    let worker_proofs = worker_proof_refs config session.session_id in
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
          ( "delivery_contract",
            Option.fold ~none:`Null
              ~some:Team_session_types.delivery_contract_to_yojson
              session.delivery_contract );
          ( "latest_delivery_verdict",
            Option.fold ~none:`Null
              ~some:Team_session_types.delivery_verdict_to_yojson
              session.latest_delivery_verdict );
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
                ( "spawn_tool_names",
                  `List (List.map (fun value -> `String value) spawn_tool_names)
                );
                ("spawn_tool_call_count", `Int spawn_tool_call_count);
                ("write_capable_spawn_count", `Int write_capable_spawn_count);
                ( "spawn_selection_notes",
                  `List (List.map (fun note -> `String note) spawn_selection_notes)
                );
                ( "spawn_selection_note_summary",
                  Option.fold ~none:`Null ~some:(fun note -> `String note)
                    spawn_selection_note_summary );
                ( "tier_counts",
                  Team_session_types.model_tier_counts session.planned_workers
                  |> Team_session_types.counts_to_json );
                ( "task_profile_counts",
                  Team_session_types.task_profile_counts session.planned_workers
                  |> Team_session_types.counts_to_json );
                ( "escalation_count",
                  `Int
                    (Team_session_types.escalation_count session.planned_workers) );
                ( "routing_reason_summary",
                  `List
                    (List.map
                       (fun reason -> `String reason)
                       (Team_session_types.routing_reason_summary
                          session.planned_workers)) );
                ("detached_agent_count", `Int detached_agent_count);
                ("detached_actor_roster", `List detached_actor_roster);
                ("vote_events", `Int vote_events);
                ("run_deliverables", `Int run_deliverables);
                ("broadcast_count", `Int session.broadcast_count);
                ("portal_count", `Int session.portal_count);
                ("done_delta_total", `Int done_delta_total);
                ("report_json_exists", `Bool report_json_exists);
                ("report_md_exists", `Bool report_md_exists);
                ("worker_proof_count", `Int (List.length worker_proofs));
              ] );
          ("worker_proofs", `List worker_proofs);
          ("generated_at_iso", `String generated_at_iso);
          ("oas_cdal_integration", `Assoc [
            ("contract_wired", `Bool (Option.is_some session.delivery_contract));
            ("proof_schema_version", `Int 1);
            ("worker_proof_count", `Int (List.length worker_proofs));
            ("aggregated", `Bool (worker_proofs <> []));
            ("note", `String "Session proof aggregates worker-level OAS proof refs when present and falls back cleanly for legacy sessions without stored worker proofs.");
          ]);
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
  with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Error (Printexc.to_string exn)
