include Team_session_engine_helpers

let generate_and_mark_report ~(config : Room.config)
    (session : Team_session_types.session) : unit =
  match Team_session_report.generate config session with
  | Ok _ -> (
      match Team_session_store.mark_report_generated config session.session_id with
      | Ok _ -> ()
      | Error e ->
          Log.Session.error
            "failed to mark report generated (%s): %s"
            session.session_id e)
  | Error e ->
      Log.Session.error "report generation failed (%s): %s"
        session.session_id e;
      Team_session_store.append_event config session.session_id
        ~event_type:"report_generation_failed"
        ~detail:(`Assoc [ ("error", `String e); ("ts_iso", `String (now_iso ())) ])

let summary_json_of_session ?events (config : Room.config)
    (session : Team_session_types.session) =
  let now = Time_compat.now () in
  let end_time = Option.value session.stopped_at ~default:now in
  let elapsed = max 0.0 (end_time -. session.started_at) in
  let remaining = max 0.0 (session.planned_end_at -. now) in
  let progress_pct =
    if session.duration_seconds <= 0 then
      100.0
    else
      min 100.0 (100.0 *. (elapsed /. float_of_int session.duration_seconds))
  in
  let deltas, done_total = done_delta_metrics config session in
  let seen_agents, active_agents =
    session_seen_and_live_agent_names ?events config session ~now
  in
  let planned_runtime_actors = Team_session_types.planned_worker_actor_names session in
  let planned_participants = Team_session_types.planned_participant_names session in
  let room_active_agents = room_active_agent_names config in
  let worker_class_counts =
    Team_session_types.worker_class_counts session.planned_workers
    |> Team_session_types.counts_to_json
  in
  let runtime_pool_counts =
    Team_session_types.runtime_pool_counts session.planned_workers
    |> Team_session_types.counts_to_json
  in
  let lane_counts =
    Team_session_types.lane_counts session.planned_workers
    |> Team_session_types.counts_to_json
  in
  let controller_counts =
    Team_session_types.controller_level_counts session.planned_workers
    |> Team_session_types.counts_to_json
  in
  let control_domain_counts =
    Team_session_types.control_domain_counts session.planned_workers
    |> Team_session_types.counts_to_json
  in
  let task_profile_counts =
    Team_session_types.task_profile_counts session.planned_workers
    |> Team_session_types.counts_to_json
  in
  let escalation_count =
    Team_session_types.escalation_count session.planned_workers
  in
  let routing_reason_summary =
    Team_session_types.routing_reason_summary session.planned_workers
  in
  `Assoc
    [
      ("session_id", `String session.session_id);
      ("status", `String (Team_session_types.status_to_string session.status));
      ("elapsed_sec", `Int (int_of_float elapsed));
      ("remaining_sec", `Int (int_of_float remaining));
      ("progress_pct", `Float progress_pct);
      ("done_delta_total", `Int done_total);
      ("done_delta_by_agent", Team_session_types.assoc_int_to_json deltas);
      ("scale_profile", `String (Team_session_types.scale_profile_to_string session.scale_profile));
      ("control_profile", `String (Team_session_types.control_profile_to_string session.control_profile));
      ("active_agents", `List (List.map (fun a -> `String a) active_agents));
      ("seen_agents", `List (List.map (fun a -> `String a) seen_agents));
      ("active_agents_count", `Int (List.length active_agents));
      ("seen_agents_count", `Int (List.length seen_agents));
      ("planned_worker_count", `Int (List.length session.planned_workers));
      ( "planned_workers",
        `List
          (List.map Team_session_types.planned_worker_to_yojson
             session.planned_workers) );
      ( "planned_runtime_actors",
        `List (List.map (fun a -> `String a) planned_runtime_actors) );
      ( "planned_participants",
        `List (List.map (fun a -> `String a) planned_participants) );
      ("worker_class_counts", worker_class_counts);
      ("runtime_pool_counts", runtime_pool_counts);
      ("lane_counts", lane_counts);
      ("controller_counts", controller_counts);
      ("control_domain_counts", control_domain_counts);
      ("task_profile_counts", task_profile_counts);
      ("escalation_count", `Int escalation_count);
      ( "routing_reason_summary",
        `List (List.map (fun reason -> `String reason) routing_reason_summary) );
      ("controller_tree", controller_tree_json_of_session session);
      ("lane_health", lane_health_json ?events config session);
      ("confidence_heatmap", confidence_heatmap_json session);
      ("context_pressure_by_lane", context_pressure_by_lane_json session);
      ("intervention_counters", controller_intervention_counts ?events config session.session_id);
      ("room_active_agents", `List (List.map (fun a -> `String a) room_active_agents));
      ( "last_checkpoint_at",
        Option.fold ~none:`Null ~some:(fun v -> `Float v)
          session.last_checkpoint_at );
      ("last_event_at", Option.fold ~none:`Null ~some:(fun v -> `Float v) session.last_event_at);
    ]

let recent_worker_run_meta_jsons config session_id =
  Team_session_store.list_worker_run_ids config session_id
  |> List.sort String.compare |> List.rev
  |> List.filter_map (fun worker_run_id ->
         let path =
           Team_session_store.worker_run_meta_path config session_id worker_run_id
         in
         if Room_utils.path_exists config path then
           Some (Room_utils.read_json config path)
         else None)

type worker_delegate_readiness = {
  worker_name : string;
  spawn_role : string option;
  execution_scope : string option;
  runtime_pool : string option;
  routing_reason : string option;
  has_meta : bool;
  has_checkpoint : bool;
  in_flight : bool;
  delegate_ready : bool;
  blocked_reason : string option;
  guidance : string;
}

let worker_delegate_guidance = function
  | Some "missing_container" ->
      "Spawn or rehydrate the worker before delegating."
  | Some "pending_checkpoint" ->
      "Wait for the worker to finish its first run and write a checkpoint."
  | Some "broken_container" ->
      "Repair or respawn the worker; a checkpoint exists without worker metadata."
  | Some "corrupt_meta" ->
      "Repair or respawn the worker; worker metadata is present but unreadable."
  | Some "corrupt_checkpoint" ->
      "Repair or respawn the worker; worker checkpoint is present but unreadable."
  | Some "in_flight" ->
      "Wait for the active worker run to complete before delegating again."
  | Some "unplanned_worker" ->
      "Delegate only to workers that are still present in the current planned worker set."
  | Some _ -> "Worker is blocked for an unspecified reason."
  | None -> "Worker is ready for delegation."

let worker_delegate_readiness_to_json (entry : worker_delegate_readiness) =
  `Assoc
    [
      ("worker_name", `String entry.worker_name);
      ( "spawn_role",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          entry.spawn_role );
      ( "execution_scope",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          entry.execution_scope );
      ( "runtime_pool",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          entry.runtime_pool );
      ( "routing_reason",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          entry.routing_reason );
      ("has_meta", `Bool entry.has_meta);
      ("has_checkpoint", `Bool entry.has_checkpoint);
      ("in_flight", `Bool entry.in_flight);
      ("delegate_ready", `Bool entry.delegate_ready);
      ( "blocked_reason",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          entry.blocked_reason );
      ("guidance", `String entry.guidance);
    ]

let planned_worker_for_actor (session : Team_session_types.session) worker_name =
  List.find_opt
    (fun (worker : Team_session_types.planned_worker) ->
      match worker.runtime_actor with
      | Some actor -> String.equal (String.trim actor) worker_name
      | None -> false)
    session.planned_workers

let worker_container_has_artifacts config session_id worker_name =
  let worker_dir =
    Team_session_store.worker_container_dir config session_id worker_name
  in
  Room_utils.path_exists config
    (Team_session_store.worker_container_meta_path config session_id worker_name)
  || Room_utils.path_exists config
       (Team_session_store.worker_container_checkpoint_path config session_id
          worker_name)
  || Team_session_store.immediate_dir_entries config worker_dir <> []

let worker_container_actor_names config session_id =
  Team_session_store.immediate_dir_entries config
    (Team_session_store.workers_dir config session_id)

let build_worker_delegate_readiness_entry config ~snapshot
    (session : Team_session_types.session) worker_name
    (planned_worker : Team_session_types.planned_worker option) =
  let team_session_id = Some session.session_id in
  let has_meta =
    Room_utils.path_exists config
      (Team_session_store.worker_container_meta_path config
         session.session_id worker_name)
  in
  let has_checkpoint =
    Room_utils.path_exists config
      (Team_session_store.worker_container_checkpoint_path config
         session.session_id worker_name)
  in
  let has_container_artifacts =
    has_meta || has_checkpoint
    || Team_session_store.immediate_dir_entries config
         (Team_session_store.worker_container_dir config session.session_id
            worker_name)
       <> []
  in
  let meta_is_valid =
    has_meta
    &&
    Option.is_some
      (Worker_container.load_worker_meta ~base_path:config.base_path
         ~team_session_id ~worker_name)
  in
  let checkpoint_is_valid =
    has_checkpoint
    &&
    Option.is_some
      (Worker_container.load_worker_checkpoint ~base_path:config.base_path
         ~team_session_id ~worker_name)
  in
  let in_flight = List.mem worker_name snapshot.in_flight_actors in
  let blocked_reason =
    if in_flight then Some "in_flight"
    else
      match planned_worker with
      | None when has_container_artifacts -> Some "unplanned_worker"
      | None -> Some "missing_container"
      | Some _ -> (
          match (has_meta, has_checkpoint) with
          | false, false -> Some "missing_container"
          | true, false -> Some "pending_checkpoint"
          | false, true -> Some "broken_container"
          | true, true when not meta_is_valid -> Some "corrupt_meta"
          | true, true when not checkpoint_is_valid -> Some "corrupt_checkpoint"
          | true, true -> None)
  in
  {
    worker_name;
    spawn_role = Option.bind planned_worker (fun worker -> worker.spawn_role);
    execution_scope =
      Option.bind planned_worker (fun worker ->
          Option.map Team_session_types.execution_scope_to_string
            worker.execution_scope);
    runtime_pool =
      Option.bind planned_worker (fun worker -> worker.runtime_pool);
    routing_reason =
      Option.bind planned_worker (fun worker -> worker.routing_reason);
    has_meta;
    has_checkpoint;
    in_flight;
    delegate_ready = Option.is_none blocked_reason;
    blocked_reason;
    guidance = worker_delegate_guidance blocked_reason;
  }

let worker_delegate_readiness_list ?events config
    (session : Team_session_types.session) =
  let snapshot = worker_run_event_snapshot ?events config session in
  let worker_names =
    Team_session_types.planned_worker_actor_names session
    @ worker_container_actor_names config session.session_id
    |> Team_session_types.dedup_strings
    |> List.sort String.compare
  in
  worker_names
  |> List.map (fun worker_name ->
         let planned_worker = planned_worker_for_actor session worker_name in
         build_worker_delegate_readiness_entry config ~snapshot session
           worker_name planned_worker)

let worker_delegate_readiness config (session : Team_session_types.session)
    worker_name =
  let snapshot = worker_run_event_snapshot config session in
  let planned_worker = planned_worker_for_actor session worker_name in
  if Option.is_some planned_worker
     || worker_container_has_artifacts config session.session_id worker_name
  then
    Some
      (build_worker_delegate_readiness_entry config ~snapshot session
         worker_name planned_worker)
  else
    None

let ready_worker_names config (session : Team_session_types.session) =
  Team_session_types.planned_worker_actor_names session
  |> List.filter (fun worker_name ->
         Room_utils.path_exists config
           (Team_session_store.worker_container_checkpoint_path config
              session.session_id worker_name))
  |> Team_session_types.dedup_strings |> List.sort String.compare

let pending_worker_names (session : Team_session_types.session) ready_names
    in_flight_actors =
  Team_session_types.planned_worker_actor_names session
  |> List.filter (fun worker_name -> not (List.mem worker_name ready_names))
  |> List.filter (fun worker_name ->
         List.mem worker_name in_flight_actors
         || not (List.mem worker_name ready_names))
  |> Team_session_types.dedup_strings |> List.sort String.compare

let worker_run_status_json (json : Yojson.Safe.t) =
  Worker_run_evidence_summary.summary_json json

let status_sections ?events (config : Room.config) (session : Team_session_types.session) =
  let events =
    match events with
    | Some rows -> rows
    | None -> Team_session_store.read_events ~max_events:200 config session.session_id
  in
  let summary = summary_json_of_session ~events config session in
  let active_agents =
    let now = Time_compat.now () in
    session_active_agent_names ~events config session ~now
  in
  let team_health = team_health_json session active_agents in
  let communication_metrics = communication_metrics_json session in
  let orchestration_state = orchestration_state_json session in
  let cascade_metrics = cascade_metrics_json session in
  (summary, team_health, communication_metrics, orchestration_state, cascade_metrics)

let _session_status_event_limit () =
  Dashboard_http_helpers.operator_snapshot_status_event_limit ()

let session_status_json (config : Room.config) (session : Team_session_types.session) =
  let events =
    Team_session_store.read_events
      ~max_events:(_session_status_event_limit ()) config session.session_id
  in
  let worker_run_summary =
    let snapshot = worker_run_event_snapshot ~events config session in
    let recent_runs =
      recent_worker_run_meta_jsons config session.session_id
      |> List.fold_left
           (fun acc json ->
             if List.length acc >= 12 then acc
             else worker_run_status_json json :: acc)
           []
      |> List.rev
    in
    let ready_workers = ready_worker_names config session in
    let worker_readiness =
      worker_delegate_readiness_list ~events config session
    in
    let delegate_ready_workers =
      worker_readiness
      |> List.filter (fun entry -> entry.delegate_ready)
      |> List.map (fun entry -> entry.worker_name)
    in
    let blocked_workers =
      worker_readiness
      |> List.filter (fun entry -> not entry.delegate_ready)
      |> List.map (fun entry -> entry.worker_name)
    in
    let pending_workers =
      pending_worker_names session ready_workers snapshot.in_flight_actors
    in
    `Assoc
      [
        ("requested_count", `Int (List.length snapshot.requested_ids));
        ("completed_success_count", `Int snapshot.completed_success_count);
        ("completed_failed_count", `Int snapshot.completed_failed_count);
        ("in_flight_count", `Int (List.length snapshot.in_flight_ids));
        ("in_flight_run_ids", `List (List.map (fun id -> `String id) snapshot.in_flight_ids));
        ("in_flight_actor_names", `List (List.map (fun id -> `String id) snapshot.in_flight_actors));
        ("ready_worker_count", `Int (List.length ready_workers));
        ("ready_worker_names", `List (List.map (fun name -> `String name) ready_workers));
        ( "delegate_ready_worker_names",
          `List
            (List.map (fun name -> `String name) delegate_ready_workers) );
        ( "blocked_worker_names",
          `List (List.map (fun name -> `String name) blocked_workers) );
        ("pending_worker_count", `Int (List.length pending_workers));
        ("pending_worker_names", `List (List.map (fun name -> `String name) pending_workers));
        ( "worker_readiness",
          `List
            (List.map worker_delegate_readiness_to_json worker_readiness) );
        ("recent_runs", `List recent_runs);
      ]
  in
  let runtime_running =
    with_runtimes_lock (fun () -> Hashtbl.mem runtimes session.session_id)
  in
  let local_runtime =
    match session.scale_profile with
    | Team_session_types.Scale_local64 -> Tool_local_runtime.runtime_status_json ()
    | Team_session_types.Scale_standard -> `Null
  in
  let summary, team_health, communication_metrics, orchestration_state,
      cascade_metrics =
    status_sections ~events config session
  in
  let linked_autoresearch = `Null in
  `Assoc
    [
      ("session", Team_session_types.session_to_yojson session);
      ( "delivery_contract",
        Option.fold ~none:`Null
          ~some:Team_session_types.delivery_contract_to_yojson
          session.delivery_contract );
      ( "latest_delivery_verdict",
        Option.fold ~none:`Null
          ~some:Team_session_types.delivery_verdict_to_yojson
          session.latest_delivery_verdict );
      ("runtime_running", `Bool runtime_running);
      ("scale_profile", `String (Team_session_types.scale_profile_to_string session.scale_profile));
      ("summary", summary);
      ("team_health", team_health);
      ("communication_metrics", communication_metrics);
      ("orchestration_state", orchestration_state);
      ("cascade_metrics", cascade_metrics);
      ("local_runtime", local_runtime);
      ("worker_runs", worker_run_summary);
      ( "command_plane",
        `Assoc
          [
            ( "operation_id",
              Option.fold ~none:`Null ~some:(fun value -> `String value)
                session.operation_id );
            ( "operation_path",
              Option.fold ~none:`Null
                ~some:(fun value ->
                  `String
                    (Printf.sprintf "/api/v1/command-plane/operations?operation_id=%s"
                       value))
                session.operation_id );
          ] );
      ( "report_paths",
        `Assoc
          [
            ( "markdown",
              `String
                (Team_session_store.report_md_path config session.session_id) );
            ("json", `String (Team_session_store.report_json_path config session.session_id));
            ( "proof_markdown",
              `String
                (Team_session_store.proof_md_path config session.session_id) );
            ("proof_json", `String (Team_session_store.proof_json_path config session.session_id));
          ] );
      ("linked_autoresearch", linked_autoresearch);
      ("plan", Team_session_plan.to_json session);
      ("plan_progress", `Float (Team_session_plan.progress session));
    ]


let list_events ~(config : Room.config) ~(session_id : string)
    ~(event_types : string list) ~(limit : int) ~(after_ts : float option) :
    (Yojson.Safe.t, string) result =
  match Team_session_store.load_session config session_id with
  | None -> Error (Printf.sprintf "team session not found: %s" session_id)
  | Some _ ->
      let normalize_types =
        event_types
        |> List.map String.trim
        |> List.filter (fun s -> s <> "")
        |> Team_session_types.dedup_strings
      in
      let max_events = clamp_int ~min_v:1 ~max_v:10000 (max 500 limit) in
      let limit = clamp_int ~min_v:1 ~max_v:1000 limit in
      let events = Team_session_store.read_events ~max_events config session_id in
      let matches_type json =
        if normalize_types = [] then
          true
        else
          match Yojson.Safe.Util.member "event_type" json with
          | `String t -> List.mem t normalize_types
          | _ -> false
      in
      let matches_after_ts json =
        match after_ts with
        | None -> true
        | Some ts -> (
            match Yojson.Safe.Util.member "ts" json with
            | `Float v -> v > ts
            | `Int n -> float_of_int n > ts
            | `Intlit s -> (try float_of_string s > ts with Failure _ -> false)
            | _ -> false)
      in
      let filtered =
        events
        |> List.filter matches_type
        |> List.filter matches_after_ts
        |> take_last limit
      in
      Ok
        (`Assoc
          [
            ("session_id", `String session_id);
            ("count", `Int (List.length filtered));
            ("events", `List filtered);
          ])

let prove_session ~(config : Room.config) ~(session_id : string)
    ~(proof_level : Team_session_types.proof_level)
    ~(generate_report_if_missing : bool) : (Yojson.Safe.t, string) result =
  match Team_session_store.load_session config session_id with
  | None -> Error (Printf.sprintf "team session not found: %s" session_id)
  | Some session ->
      let report_json_exists =
        Room_utils.path_exists config
          (Team_session_store.report_json_path config session_id)
      in
      let report_md_exists =
        Room_utils.path_exists config
          (Team_session_store.report_md_path config session_id)
      in
      let ensure_report_result : (Team_session_types.session, string) result =
        if generate_report_if_missing && not (report_json_exists && report_md_exists)
        then
          match Team_session_report.generate config session with
          | Ok (_json, _markdown) ->
              Team_session_store.mark_report_generated config session_id
          | Error e -> Error e
        else Ok session
      in
      match ensure_report_result with
      | Error e -> Error e
      | Ok refreshed_session -> (
          match
            Team_session_report.generate_proof ~proof_level config
              refreshed_session
          with
          | Error e -> Error e
          | Ok (proof_json, proof_markdown) ->
              let proof_json_path =
                Team_session_store.proof_json_path config session_id
              in
              let proof_md_path =
                Team_session_store.proof_md_path config session_id
              in
              Room_utils.write_json config proof_json_path proof_json;
              Team_session_store.write_artifact_text config proof_md_path
                proof_markdown;
              Team_session_store.append_event config session_id
                ~event_type:"session_proof_generated"
                ~detail:
                  (`Assoc
                    [
                      ("proof_json_path", `String proof_json_path);
                      ("proof_md_path", `String proof_md_path);
                      ("ts_iso", `String (now_iso ()));
                    ]);
              Ok
                (`Assoc
                  [
                    ("session_id", `String session_id);
                    ( "delivery_contract",
                      Option.fold ~none:`Null
                        ~some:Team_session_types.delivery_contract_to_yojson
                        refreshed_session.delivery_contract );
                    ( "latest_delivery_verdict",
                      Option.fold ~none:`Null
                        ~some:Team_session_types.delivery_verdict_to_yojson
                        refreshed_session.latest_delivery_verdict );
                    ("proof", proof_json);
                    ("proof_json_path", `String proof_json_path);
                    ("proof_md_path", `String proof_md_path);
                  ]))

let list_sessions ~(config : Room.config) ~(requester_agent : string option)
    ~(status_filter : Team_session_types.session_status option) ~(limit : int) :
    (Yojson.Safe.t, string) result =
  let limit = clamp_int ~min_v:1 ~max_v:200 limit in
  try
    let sessions =
      Team_session_store.list_sessions config
      |> List.sort (fun (a : Team_session_types.session)
                         (b : Team_session_types.session) ->
             compare b.started_at a.started_at)
      |> (fun xs ->
           match status_filter with
           | None -> xs
           | Some s ->
               List.filter
                 (fun (x : Team_session_types.session) -> x.status = s)
                 xs)
      |> (fun xs ->
           match requester_agent with
           | None -> xs
           | Some agent_name ->
               List.filter
                 (fun (x : Team_session_types.session) ->
                   session_visible_to_agent ~agent_name x)
                 xs)
      |> take limit
    in
    let items =
      List.map
        (fun (session : Team_session_types.session) ->
          let summary, team_health, communication_metrics, _orchestration_state,
              cascade_metrics =
            status_sections config session
          in
          `Assoc
            [
              ("session_id", `String session.session_id);
              ("goal", `String session.goal);
              ("status", `String (Team_session_types.status_to_string session.status));
              ("started_at", `Float session.started_at);
              ("planned_end_at", `Float session.planned_end_at);
              ("stopped_at", Option.fold ~none:`Null ~some:(fun v -> `Float v) session.stopped_at);
              ("generated_report", `Bool session.generated_report);
              ("summary", summary);
              ("team_health", team_health);
              ("communication_metrics", communication_metrics);
              ("cascade_metrics", cascade_metrics);
            ])
        sessions
    in
    Ok
      (`Assoc
        [
          ("count", `Int (List.length items));
          ("sessions", `List items);
        ])
  with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Error (Printexc.to_string exn)

let compare_sessions ~(config : Room.config) ~(requester_agent : string option)
    ~(base_session_id : string) ~(target_session_id : string) :
    (Yojson.Safe.t, string) result =
  match
    ( Team_session_store.load_session config base_session_id,
      Team_session_store.load_session config target_session_id )
  with
  | None, _ ->
      Error (Printf.sprintf "team session not found: %s" base_session_id)
  | _, None ->
      Error (Printf.sprintf "team session not found: %s" target_session_id)
  | Some base_session, Some target_session ->
      let authorized =
        match requester_agent with
        | None -> true
        | Some agent_name ->
            session_visible_to_agent ~agent_name base_session
            && session_visible_to_agent ~agent_name target_session
      in
      if not authorized then
        Error "not authorized for this team session compare"
      else
      let base_summary = summary_json_of_session config base_session in
      let target_summary = summary_json_of_session config target_session in
      let base_done = parse_summary_int "done_delta_total" base_summary in
      let target_done = parse_summary_int "done_delta_total" target_summary in
      let base_progress = parse_summary_float "progress_pct" base_summary in
      let target_progress = parse_summary_float "progress_pct" target_summary in
      let base_elapsed = parse_summary_int "elapsed_sec" base_summary in
      let target_elapsed = parse_summary_int "elapsed_sec" target_summary in
      let better_session =
        if target_done > base_done then
          target_session_id
        else if target_done < base_done then
          base_session_id
        else if target_progress > base_progress then
          target_session_id
        else
          base_session_id
      in
      Ok
        (`Assoc
          [
            ("base_session_id", `String base_session_id);
            ("target_session_id", `String target_session_id);
            ("better_session", `String better_session);
            ( "summary",
              `Assoc
                [
                  ( "done_delta",
                    `Assoc
                      [
                        ("base", `Int base_done);
                        ("target", `Int target_done);
                        ("delta", `Int (target_done - base_done));
                      ] );
                  ( "progress_pct",
                    `Assoc
                      [
                        ("base", `Float base_progress);
                        ("target", `Float target_progress);
                        ("delta", `Float (target_progress -. base_progress));
                      ] );
                  ( "elapsed_sec",
                    `Assoc
                      [
                        ("base", `Int base_elapsed);
                        ("target", `Int target_elapsed);
                        ("delta", `Int (target_elapsed - base_elapsed));
                      ] );
                ] );
            ( "policy",
              `Assoc
                [
                  ( "min_agents_violation_streak",
                    `Assoc
                      [
                        ("base", `Int base_session.min_agents_violation_streak);
                        ("target", `Int target_session.min_agents_violation_streak);
                      ] );
                  ( "fallback_task_created",
                    `Assoc
                      [
                        ("base", `Int base_session.fallback_task_created);
                        ("target", `Int target_session.fallback_task_created);
                      ] );
                  ( "cascade_attempted",
                    `Assoc
                      [
                        ("base", `Int base_session.cascade_attempted);
                        ("target", `Int target_session.cascade_attempted);
                      ] );
                  ( "cascade_failed",
                    `Assoc
                      [
                        ("base", `Int base_session.cascade_failed);
                        ("target", `Int target_session.cascade_failed);
                      ] );
                ] );
            ( "communication",
              `Assoc
                [
                  ( "broadcast_count",
                    `Assoc
                      [
                        ("base", `Int base_session.broadcast_count);
                        ("target", `Int target_session.broadcast_count);
                      ] );
                  ( "portal_count",
                    `Assoc
                      [
                        ("base", `Int base_session.portal_count);
                        ("target", `Int target_session.portal_count);
                      ] );
                ] );
          ])
