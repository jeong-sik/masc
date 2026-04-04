(** Eio runtime engine for long-running team sessions. *)

include Team_session_engine_policy
open Result_syntax

(* Phase C-2d: start_runtime_loop removed.
   All modes now use Team_session_swarm_runner.run_swarm via OAS Runner.
   Checkpoint/policy logic is handled by swarm callbacks. *)

let start_session ~sw ~(env : < clock : _ Eio.Time.clock ; process_mgr : _ Eio.Process.mgr ; .. >) ~(config : Room.config)
    ~(created_by : string) ~(goal : string) ~(duration_seconds : int)
    ~(execution_scope : Team_session_types.execution_scope)
    ~(checkpoint_interval_sec : int) ~(min_agents : int)
    ~(scale_profile : Team_session_types.scale_profile)
    ~(control_profile : Team_session_types.control_profile)
    ~(orchestration_mode : Team_session_types.orchestration_mode)
    ~(communication_mode : Team_session_types.communication_mode)
    ~(model_cascade : string list)
    ~(fallback_policy : Team_session_types.fallback_policy)
    ~(instruction_profile : Team_session_types.instruction_profile)
    ~(alert_channel : Team_session_types.alert_channel) ~(auto_resume : bool)
    ~(report_formats : Team_session_types.report_format list)
    ~(agent_names : string list) ~(operation_id : string option)
    : (Yojson.Safe.t, string) result =
  try
    Room_utils.ensure_initialized config;
    let session_task_id = Printf.sprintf "team_session_start_%s"
      (string_of_int (int_of_float (Time_compat.now () *. 1000.0))) in
    let session_tracker = Progress.start_tracking ~task_id:session_task_id ~total_steps:5 () in
    Progress.Tracker.step session_tracker ~message:"Validating session parameters" ();
    let duration_seconds = clamp_int ~min_v:60 ~max_v:28800 duration_seconds in
    let checkpoint_interval_sec =
      clamp_int ~min_v:10 ~max_v:600 checkpoint_interval_sec
    in
    let min_agents = clamp_int ~min_v:1 ~max_v:64 min_agents in
    let now = Time_compat.now () in
    let session_id = Team_session_store.make_session_id () in
    let* () =
      match operation_id with
      | Some value -> validate_operation_attachment ~config ~operation_id:value
      | None -> Ok ()
    in
    let room_id =
      "default"
    in
    let selected_agents =
      if agent_names <> [] then
        Team_session_types.dedup_strings agent_names
      else
        let discovered = room_active_agent_names config in
        if discovered = [] then [ created_by ] else discovered
    in
    let baseline_done_counts =
      Team_session_types.done_counts_from_backlog (Room.read_backlog config)
    in
    let model_cascade = Team_session_types.dedup_strings model_cascade in
    let session : Team_session_types.session =
      {
        session_id;
        goal;
        created_by;
        origin_kind =
          Team_session_types.infer_session_origin_kind
            ~created_by ~orchestration_mode;
        room_id;
        operation_id;
        status = Team_session_types.Running;
        duration_seconds;
        execution_scope;
        checkpoint_interval_sec;
        min_agents;
        scale_profile;
        control_profile;
        orchestration_mode;
        communication_mode;
        model_cascade;
        fallback_policy;
        instruction_profile;
        alert_channel;
        auto_resume;
        report_formats =
          (if report_formats = [] then
             [ Team_session_types.Markdown; Team_session_types.Json ]
           else report_formats);
        turn_count = 0;
        agent_names = selected_agents;
        planned_workers = [];
        broadcast_count = 0;
        portal_count = 0;
        cascade_attempted = 0;
        cascade_success = 0;
        cascade_failed = 0;
        fallback_task_created = 0;
        min_agents_violation_streak = 0;
        policy_violations = [];
        baseline_done_counts;
        final_done_delta_total = None;
        final_done_delta_by_agent = None;
        started_at = now;
        planned_end_at = now +. float_of_int duration_seconds;
        stopped_at = None;
        last_checkpoint_at = Some now;
        last_event_at = Some now;
        last_turn_at = None;
        stop_reason = None;
        generated_report = false;
        delivery_contract = None;
        latest_delivery_verdict = None;
        artifacts_dir = Team_session_store.session_dir config session_id;
        created_at_iso = now_iso ();
        updated_at_iso = now_iso ();
      }
    in
    (* Create dirs only after validation succeeds — prevents orphaned
       directories when validate_operation_attachment returns Error. *)
    Progress.Tracker.step session_tracker ~message:"Creating session directories" ();
    Team_session_store.ensure_session_dirs config session_id;
    Team_session_store.save_session config session;
    let* () =
      match operation_id with
      | Some value -> (
          match
            Command_plane_v2.update_operation config ~actor:created_by
              ~operation_id:value ~event_type:"team_session_attached"
              ~detail:
                (`Assoc
                  [
                    ("session_id", `String session_id);
                    ("goal", `String goal);
                  ])
              (fun current ->
                { current with
                  detachment_session_id = Some session_id;
                  note =
                    (match current.note with
                    | Some note when String.trim note <> "" -> Some note
                    | _ -> Some ("team_session:" ^ session_id))
                })
          with
          | Ok _ -> Ok ()
          | Error err -> Error err)
      | None -> Ok ()
    in
    Progress.Tracker.step session_tracker ~message:"Recording session start event" ();
    Team_session_store.append_event config session_id ~event_type:"session_started"
      ~detail:
        (`Assoc
          [
            ("goal", `String goal);
            ("created_by", `String created_by);
            ("operation_id", Option.fold ~none:`Null ~some:(fun value -> `String value) operation_id);
            ("duration_seconds", `Int duration_seconds);
            ("agent_count", `Int (List.length selected_agents));
            ( "scale_profile",
              `String
                (Team_session_types.scale_profile_to_string scale_profile) );
            ( "control_profile",
              `String
                (Team_session_types.control_profile_to_string control_profile) );
            ( "orchestration_mode",
              `String
                (Team_session_types.orchestration_mode_to_string
                   orchestration_mode) );
            ( "communication_mode",
              `String
                (Team_session_types.communication_mode_to_string communication_mode)
            );
            ("model_cascade", `List (List.map (fun m -> `String m) model_cascade));
            ( "fallback_policy",
              `String
                (Team_session_types.fallback_policy_to_string fallback_policy) );
            ( "instruction_profile",
              `String
                (Team_session_types.instruction_profile_to_string
                   instruction_profile) );
            ("alert_channel", `String (Team_session_types.alert_channel_to_string alert_channel));
          ]);
    if control_profile = Team_session_types.Control_hierarchical_quality_v1 then
      Team_session_store.append_event config session_id
        ~event_type:"controller_tree_materialized"
        ~detail:
          (`Assoc
            [
              ("controller_tree", controller_tree_json_of_session session);
              ("ts_iso", `String (now_iso ()));
            ]);
    write_checkpoint config session;
    Progress.Tracker.step session_tracker ~message:"Registering runtime state" ();
    with_runtimes_lock (fun () ->
        Hashtbl.replace runtimes session_id
          {
            stop_requested = false;
            stop_reason = None;
            finalizing = false;
            generate_report_on_finalize = true;
          });
    (* Phase C-2b-gate: Single-agent fallback gate (#3651).
       Classify task decomposability before swarm dispatch.
       Low → trim to single worker to avoid swarm overhead on sequential tasks. *)
    let decomp, decomp_reason =
      Team_session_engine_policy.classify_decomposability
        ~orchestration_mode
        ~planned_workers:session.planned_workers
    in
    let session =
      if decomp = Team_session_types.Decomposability_low
         && List.length session.planned_workers > 1 then begin
        let kept = match session.planned_workers with w :: _ -> [w] | [] -> [] in
        let trimmed = List.length session.planned_workers - List.length kept in
        Team_session_store.append_event config session_id
          ~event_type:"single_agent_gate"
          ~detail:(`Assoc [
            ("decomposability", `String (Team_session_types.decomposability_to_string decomp));
            ("reason", `String decomp_reason);
            ("original_worker_count", `Int (List.length session.planned_workers));
            ("trimmed_workers", `Int trimmed);
            ("ts_iso", `String (Types.now_iso ()));
          ]);
        { session with planned_workers = kept }
      end else begin
        Team_session_store.append_event config session_id
          ~event_type:"decomposability_classified"
          ~detail:(`Assoc [
            ("decomposability", `String (Team_session_types.decomposability_to_string decomp));
            ("reason", `String decomp_reason);
            ("worker_count", `Int (List.length session.planned_workers));
            ("ts_iso", `String (Types.now_iso ()));
          ]);
        session
      end
    in
    (* Phase C-2c: All modes use OAS Swarm Runner.
       orchestration_mode is mapped by the bridge:
         Auto → Decentralized, Manual/Assist → Supervisor.
       The old 15-second polling engine (start_runtime_loop) is no longer
       called for any mode.
       Skip swarm fork when planned_workers is empty — the session stays
       Running and accepts manual steps via masc_team_session_step. *)
    if session.planned_workers <> [] then
      Eio.Fiber.fork ~sw (fun () ->
        let result =
          match Team_session_oas_bridge.supported_local_worker_tools () with
          | Ok masc_tools ->
            Team_session_swarm_runner.run_swarm ~sw ~env ~config
              ~session_id ~masc_tools
              ~dispatch:(Team_session_oas_bridge.dispatch_supported_tool
                ~sw ~clock:env#clock ~config)
          | Error reason -> Error reason
        in
        match result with
        | Ok _session ->
          with_runtimes_lock (fun () -> Hashtbl.remove runtimes session_id)
        | Error reason ->
          Log.Session.error "team-session swarm startup failed: %s" reason;
          ignore (finalize_session ~config ~session_id
            ~final_status:Team_session_types.Failed ~reason
            ~generate_report:true);
          with_runtimes_lock (fun () -> Hashtbl.remove runtimes session_id));
    Progress.Tracker.complete session_tracker
      ~message:(Printf.sprintf "Team session %s started" session_id) ();
    Ok
      (`Assoc
        [
          ("session_id", `String session_id);
          ("status", `String "running");
          ("started_at", `Float now);
          ("planned_end_at", `Float session.planned_end_at);
          ("artifacts_dir", `String session.artifacts_dir);
          ("operation_id", Option.fold ~none:`Null ~some:(fun value -> `String value) operation_id);
          ( "orchestration_mode",
            `String
              (Team_session_types.orchestration_mode_to_string orchestration_mode)
          );
          ( "communication_mode",
            `String
              (Team_session_types.communication_mode_to_string communication_mode)
          );
          ( "control_profile",
            `String
              (Team_session_types.control_profile_to_string control_profile) );
          ("model_cascade", `List (List.map (fun m -> `String m) model_cascade));
        ])
  with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Error (Printexc.to_string exn)

let refresh_duration_expired_session ~(config : Room.config) ~(session_id : string)
    (session : Team_session_types.session) : Team_session_types.session =
  if session.status = Team_session_types.Running
     && Time_compat.now () >= session.planned_end_at
  then
    match
      finalize_session ~config ~session_id
        ~final_status:Team_session_types.Completed
        ~reason:"duration_elapsed" ~generate_report:true
    with
    | Some finalized -> finalized
    | None -> session
  else session

let status_session ~(config : Room.config) ~(session_id : string) :
    (Yojson.Safe.t, string) result =
  match Team_session_store.load_session config session_id with
  | None -> Error (Printf.sprintf "team session not found: %s" session_id)
  | Some session ->
      let session = refresh_duration_expired_session ~config ~session_id session in
      Ok (session_status_json config session)

let stop_session ~(config : Room.config) ~(session_id : string) ~(reason : string)
    ~(generate_report : bool) : (Yojson.Safe.t, string) result =
  match Team_session_store.load_session config session_id with
  | None -> Error (Printf.sprintf "team session not found: %s" session_id)
  | Some session ->
      let session = refresh_duration_expired_session ~config ~session_id session in
      if session.status = Team_session_types.Running then begin
        with_runtimes_lock (fun () ->
            match Hashtbl.find_opt runtimes session_id with
            | Some runtime when not runtime.finalizing ->
                runtime.stop_requested <- true;
                runtime.stop_reason <- Some reason;
                runtime.generate_report_on_finalize <- generate_report
            | _ -> ());
        (* Directly finalize rather than deferring to the runtime loop.
           The runtime loop sleeps up to 15s between ticks, so setting a flag
           alone would leave callers waiting. finalize_session is idempotent
           under with_finalize_lock, safe even if the runtime loop also fires. *)
        let reloaded = Team_session_store.load_session config session_id in
        let updated =
          match reloaded with
          | Some s when s.status <> Team_session_types.Running -> Some s
          | _ ->
              let final_status =
                if reason = "timeout" || reason = "error" || reason = "kill"
                   || reason = "keeper_down"
                then Team_session_types.Interrupted
                else Team_session_types.Completed
              in
              finalize_session ~config ~session_id
                ~final_status ~reason
                ~generate_report
        in
        let _gc_count =
          Operator_pending_confirm.remove_pending_confirms_by_target config
            ~target_type:"team_session" ~target_id:(Some session_id)
        in
        (match updated with
        | Some s -> Ok (session_status_json config s)
        | None ->
            Error (Printf.sprintf "team session not found: %s" session_id))
      end else
        let response =
          if generate_report then (
            generate_and_mark_report ~config session;
            `Assoc
              [
                ("session_id", `String session_id);
                ( "status",
                  `String (Team_session_types.status_to_string session.status) );
                ("report_generated", `Bool true);
              ])
          else
            `Assoc
              [
                ("session_id", `String session_id);
                ( "status",
                  `String (Team_session_types.status_to_string session.status) );
              ]
        in
        Ok response

let generate_report ~(config : Room.config) ~(session_id : string)
    ~(force_regenerate : bool) : (Yojson.Safe.t, string) result =
  match Team_session_store.load_session config session_id with
  | None -> Error (Printf.sprintf "team session not found: %s" session_id)
  | Some session ->
      let session = refresh_duration_expired_session ~config ~session_id session in
      let report_json_exists =
        Room_utils.path_exists config
          (Team_session_store.report_json_path config session_id)
      in
      let report_md_exists =
        Room_utils.path_exists config
          (Team_session_store.report_md_path config session_id)
      in
      if (not force_regenerate) && session.generated_report && report_json_exists
         && report_md_exists
      then
        Ok
          (`Assoc
            [
              ("session_id", `String session_id);
              ("status", `String "ok");
              ("regenerated", `Bool false);
              ( "delivery_contract",
                Option.fold ~none:`Null
                  ~some:Team_session_types.delivery_contract_to_yojson
                  session.delivery_contract );
              ( "latest_delivery_verdict",
                Option.fold ~none:`Null
                  ~some:Team_session_types.delivery_verdict_to_yojson
                  session.latest_delivery_verdict );
              ( "markdown_path",
                `String (Team_session_store.report_md_path config session_id) );
              ("json_path", `String (Team_session_store.report_json_path config session_id));
            ])
      else
        match Team_session_report.generate config session with
        | Error e -> Error e
        | Ok (_json, markdown) -> (
            match Team_session_store.mark_report_generated config session_id with
            | Ok _ ->
                Ok
                  (`Assoc
                    [
                      ("session_id", `String session_id);
                      ("status", `String "ok");
                      ("regenerated", `Bool true);
                      ( "delivery_contract",
                        Option.fold ~none:`Null
                          ~some:Team_session_types.delivery_contract_to_yojson
                          session.delivery_contract );
                      ( "latest_delivery_verdict",
                        Option.fold ~none:`Null
                          ~some:Team_session_types.delivery_verdict_to_yojson
                          session.latest_delivery_verdict );
                      ( "summary",
                        `String
                          (if String.length markdown > 240 then
                             String.sub markdown 0 240 ^ "..."
                           else markdown) );
                      ( "markdown_path",
                        `String (Team_session_store.report_md_path config session_id)
                      );
                      ( "json_path",
                        `String
                          (Team_session_store.report_json_path config session_id)
                      );
                    ])
            | Error e ->
                Error
                  (Printf.sprintf
                     "report generated but failed to mark generated_report: %s" e)
            )

let record_turn ~(config : Room.config) ~(session_id : string) ~(actor : string)
    ~(turn_kind : Team_session_types.turn_kind) ~(message : string option)
    ~(target_agent : string option) ~(task_title : string option)
    ~(task_description : string option) ~(task_priority : int) :
    (Yojson.Safe.t, string) result =
  let normalize_opt = function
    | Some s ->
        let t = String.trim s in
        if t = "" then None else Some t
    | None -> None
  in
  match Team_session_store.load_session config session_id with
  | None -> Error (Printf.sprintf "team session not found: %s" session_id)
  | Some session -> (
      let session = refresh_duration_expired_session ~config ~session_id session in
      if session.status <> Team_session_types.Running then
        Error "turn recording is only allowed while session is running"
      else if
        not
          (session_allows_actor ~actor session
          || session_has_attached_actor ~config ~session_id ~actor)
      then
        Error "actor is not authorized for this team session"
      else
      let message = normalize_opt message in
      let target_agent = normalize_opt target_agent in
      let task_title = normalize_opt task_title in
      let task_description =
        match normalize_opt task_description with
        | Some d -> d
        | None -> ""
      in
      let task_priority = clamp_int ~min_v:1 ~max_v:5 task_priority in
      let now = Time_compat.now () in
      match turn_kind with
      | Team_session_types.Turn_note -> (
          match message with
          | None -> Error "message is required for note turn"
          | Some msg ->
              let updated =
                {
                  session with
                  turn_count = session.turn_count + 1;
                  last_turn_at = Some now;
                  last_event_at = Some now;
                  updated_at_iso = now_iso ();
                }
              in
              Team_session_store.save_session config updated;
              Team_session_store.append_event config session_id ~event_type:"team_turn"
                ~detail:
                  (`Assoc
                    [
                      ("turn_no", `Int updated.turn_count);
                      ("kind", `String "note");
                      ("actor", `String actor);
                      ("message", `String msg);
                      ("ts_iso", `String (now_iso ()));
                    ]);
              Ok
                (`Assoc
                  [
                    ("session_id", `String session_id);
                    ("turn_no", `Int updated.turn_count);
                    ("kind", `String "note");
                  ]))
      | Team_session_types.Turn_broadcast -> (
          match message with
          | None -> Error "message is required for broadcast turn"
          | Some msg ->
              ignore (Room.broadcast config ~from_agent:actor ~content:msg);
              let updated =
                {
                  session with
                  turn_count = session.turn_count + 1;
                  broadcast_count = session.broadcast_count + 1;
                  last_turn_at = Some now;
                  last_event_at = Some now;
                  updated_at_iso = now_iso ();
                }
              in
              Team_session_store.save_session config updated;
              Team_session_store.append_event config session_id
                ~event_type:"team_turn"
                ~detail:
                  (`Assoc
                    [
                      ("turn_no", `Int updated.turn_count);
                      ("kind", `String "broadcast");
                      ("actor", `String actor);
                      ("message", `String msg);
                      ("broadcast", `Bool true);
                      ("ts_iso", `String (now_iso ()));
                    ]);
              Ok
                (`Assoc
                  [
                    ("session_id", `String session_id);
                    ("turn_no", `Int updated.turn_count);
                    ("kind", `String "broadcast");
                    ("broadcast", `Bool true);
                  ]))
      | Team_session_types.Turn_portal -> (
          match (target_agent, message) with
          | Some target, Some msg -> (
              let send_result =
                match
                  Room.portal_open_r config ~agent_name:actor
                    ~target_agent:target ~initial_message:(Some msg)
                with
                | Ok opened -> Ok opened
                | Error (Types.PortalAlreadyOpen _) ->
                    Room.portal_send_r config ~agent_name:actor ~message:msg
                | Error e -> Error e
              in
              match send_result with
              | Error e ->
                  let err = Types.masc_error_to_string e in
                  Team_session_store.append_event config session_id
                    ~event_type:"team_turn_failed"
                    ~detail:
                      (`Assoc
                        [
                          ("kind", `String "portal");
                          ("actor", `String actor);
                          ("target_agent", `String target);
                          ("error", `String err);
                          ("ts_iso", `String (now_iso ()));
                        ]);
                  Error err
              | Ok send_msg ->
                  let updated =
                    {
                      session with
                      turn_count = session.turn_count + 1;
                      portal_count = session.portal_count + 1;
                      last_turn_at = Some now;
                      last_event_at = Some now;
                      updated_at_iso = now_iso ();
                    }
                  in
                  Team_session_store.save_session config updated;
                  Team_session_store.append_event config session_id
                    ~event_type:"team_turn"
                    ~detail:
                      (`Assoc
                        [
                          ("turn_no", `Int updated.turn_count);
                          ("kind", `String "portal");
                          ("actor", `String actor);
                          ("target_agent", `String target);
                          ("message", `String msg);
                          ("result", `String send_msg);
                          ("ts_iso", `String (now_iso ()));
                        ]);
                  Ok
                    (`Assoc
                      [
                        ("session_id", `String session_id);
                        ("turn_no", `Int updated.turn_count);
                        ("kind", `String "portal");
                        ("target_agent", `String target);
                        ("result", `String send_msg);
                      ]))
          | _ -> Error "target_agent and message are required for portal turn")
      | Team_session_types.Turn_task -> (
          match task_title with
          | None -> Error "task_title is required for task turn"
          | Some title ->
              let add_result =
                Room.add_task config ~title ~priority:task_priority
                  ~description:task_description
              in
              let updated =
                {
                  session with
                  turn_count = session.turn_count + 1;
                  last_turn_at = Some now;
                  last_event_at = Some now;
                  updated_at_iso = now_iso ();
                }
              in
              Team_session_store.save_session config updated;
              Team_session_store.append_event config session_id
                ~event_type:"team_turn"
                ~detail:
                  (`Assoc
                    [
                      ("turn_no", `Int updated.turn_count);
                      ("kind", `String "task");
                      ("actor", `String actor);
                      ("task_title", `String title);
                      ("task_priority", `Int task_priority);
                      ("result", `String add_result);
                      ("ts_iso", `String (now_iso ()));
                    ]);
              Ok
                (`Assoc
                  [
                    ("session_id", `String session_id);
                    ("turn_no", `Int updated.turn_count);
                    ("kind", `String "task");
                    ("result", `String add_result);
                  ]))
      | Team_session_types.Turn_checkpoint ->
          write_checkpoint config session;
          let updated =
            {
              session with
              turn_count = session.turn_count + 1;
              last_turn_at = Some now;
              last_checkpoint_at = Some now;
              last_event_at = Some now;
              updated_at_iso = now_iso ();
            }
          in
          Team_session_store.save_session config updated;
          Team_session_store.append_event config session_id ~event_type:"team_turn"
            ~detail:
              (`Assoc
                [
                  ("turn_no", `Int updated.turn_count);
                  ("kind", `String "checkpoint");
                  ("actor", `String actor);
                  ("ts_iso", `String (now_iso ()));
                ]);
          Ok
            (`Assoc
              [
                ("session_id", `String session_id);
                ("turn_no", `Int updated.turn_count);
                ("kind", `String "checkpoint");
              ]))


let recover_running_sessions ~sw ~(env : < clock : _ Eio.Time.clock ; process_mgr : _ Eio.Process.mgr ; .. >)
    ~(config : Room.config) : unit =
  let sessions = Team_session_store.list_sessions config in
  let now = Time_compat.now () in
  List.iter
    (fun (session : Team_session_types.session) ->
      if session.status = Team_session_types.Running then begin
        if session.auto_resume then begin
          if now >= session.planned_end_at then
            ignore
              (finalize_session ~config ~session_id:session.session_id
                 ~final_status:Team_session_types.Completed
                 ~reason:"duration_elapsed_during_restart" ~generate_report:true)
          else
            let should_start =
              with_runtimes_lock (fun () ->
                  if Hashtbl.mem runtimes session.session_id then
                    false
                  else (
                    Hashtbl.replace runtimes session.session_id
                      {
                        stop_requested = false;
                        stop_reason = None;
                        finalizing = false;
                        generate_report_on_finalize = true;
                      };
                    true))
            in
            if should_start then begin
              let checkpoint_detail =
                match
                  Team_session_store.load_latest_checkpoint config
                    session.session_id
                with
                | None -> [ ("last_checkpoint", `Null) ]
                | Some cp ->
                    [
                      ( "last_checkpoint",
                        Team_session_types.checkpoint_to_yojson cp );
                      ("progress_at_restart", `Float cp.progress_pct);
                      ("done_at_restart", `Int cp.done_delta_total);
                    ]
              in
              let recent_events =
                Team_session_store.read_recent_events config
                  session.session_id ~max_count:10
              in
              let event_context =
                [
                  ( "recent_events_before_restart",
                    `List
                      (List.map Team_session_types.event_entry_to_yojson
                         recent_events) );
                  ( "event_count_before_restart",
                    `Int (List.length recent_events) );
                ]
              in
              Team_session_store.append_event config session.session_id
                ~event_type:"recovered_after_restart"
                ~detail:
                  (`Assoc
                    ([
                       ( "remaining_sec",
                         `Int
                           (int_of_float (session.planned_end_at -. now))
                       );
                       ("ts_iso", `String (now_iso ()));
                     ]
                    @ checkpoint_detail @ event_context));
              (* Phase C-2c: reconnect also uses swarm runner *)
              Eio.Fiber.fork ~sw (fun () ->
                let result =
                  match Team_session_oas_bridge.supported_local_worker_tools () with
                  | Ok masc_tools ->
                    Team_session_swarm_runner.run_swarm ~sw ~env ~config
                      ~session_id:session.session_id ~masc_tools
                      ~dispatch:(Team_session_oas_bridge.dispatch_supported_tool
                        ~sw ~clock:env#clock ~config)
                  | Error reason -> Error reason
                in
                match result with
                | Ok _s ->
                  with_runtimes_lock (fun () ->
                    Hashtbl.remove runtimes session.session_id)
                | Error reason ->
                  Log.Session.error "team-session swarm restart failed: %s" reason;
                  ignore (finalize_session ~config ~session_id:session.session_id
                    ~final_status:Team_session_types.Failed ~reason
                    ~generate_report:true);
                  with_runtimes_lock (fun () ->
                    Hashtbl.remove runtimes session.session_id))
            end
        end else begin
          Log.Session.warn
            "orphan session %s (auto_resume=false): transitioning to Interrupted"
            session.session_id;
          ignore
            (finalize_session ~config ~session_id:session.session_id
               ~final_status:Team_session_types.Interrupted
               ~reason:"no_auto_resume_on_restart" ~generate_report:true)
        end
      end)
    sessions
