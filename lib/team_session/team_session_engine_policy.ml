include Team_session_engine_status

let write_checkpoint (config : Room.config) (session : Team_session_types.session) =
  let now = Time_compat.now () in
  let active_agents = session_active_agent_names config session ~now in
  let participant_agents = match active_agents with [] -> session.agent_names | a -> a in
  let backlog = Room.read_backlog config in
  let current_done = Team_session_types.done_counts_from_backlog backlog in
  (* Include backlog assignee names to handle nickname vs raw-name mismatches.
     See compute_live_done_delta for rationale. *)
  let agents =
    Team_session_types.dedup_strings
      (participant_agents
       @ List.map fst current_done
       @ List.map fst session.baseline_done_counts)
  in
  let deltas =
    Team_session_types.done_delta_by_agent ~baseline:session.baseline_done_counts
      ~current:current_done ~agents
  in
  let done_total = List.fold_left (fun acc (_, n) -> acc + n) 0 deltas in
  let elapsed = max 0.0 (now -. session.started_at) in
  let remaining = max 0.0 (session.planned_end_at -. now) in
  let progress_pct =
    if session.duration_seconds <= 0 then
      100.0
    else
      min 100.0 (100.0 *. (elapsed /. float_of_int session.duration_seconds))
  in
  let checkpoint : Team_session_types.checkpoint =
    {
      ts = now;
      ts_iso = now_iso ();
      status = session.status;
      elapsed_sec = int_of_float elapsed;
      remaining_sec = int_of_float remaining;
      progress_pct;
      done_delta_total = done_total;
      done_delta_by_agent = deltas;
      active_agents;
    }
  in
  Team_session_store.write_checkpoint config session.session_id checkpoint

let maybe_post_board_alert ~(config : Room.config) ~(session : Team_session_types.session)
    ~(message : string) : bool =
  match
    Board_dispatch.create_post ~author:"team-session" ~content:message
      ~visibility:Board.Internal ~ttl_hours:24
      ~hearth:"team-session"
      ~thread_id:session.session_id ()
  with
  | Ok _ -> true
  | Error e ->
      Team_session_store.append_event config session.session_id
        ~event_type:"alert_board_failed"
        ~detail:(`Assoc [ ("error", `String (Board.show_board_error e)); ("ts_iso", `String (now_iso ())) ]);
      false

let emit_alert ~(config : Room.config) ~(session : Team_session_types.session)
    ~(message : string) : Team_session_types.session =
  let can_broadcast =
    match session.communication_mode with
    | Team_session_types.Comm_off -> false
    | Team_session_types.Comm_broadcast | Team_session_types.Comm_hybrid -> true
    | Team_session_types.Comm_portal -> false
  in
  let can_portal =
    match session.communication_mode with
    | Team_session_types.Comm_portal | Team_session_types.Comm_hybrid -> true
    | Team_session_types.Comm_off | Team_session_types.Comm_broadcast -> false
  in
  let did_broadcast =
    match session.alert_channel with
    | Team_session_types.Alert_broadcast | Team_session_types.Alert_both ->
        if can_broadcast then (
          ignore
            (Room.broadcast config ~from_agent:"team-session"
               ~content:message);
          true)
        else false
    | Team_session_types.Alert_board -> false
  in
  let did_board =
    match session.alert_channel with
    | Team_session_types.Alert_board | Team_session_types.Alert_both ->
        maybe_post_board_alert ~config ~session ~message
    | Team_session_types.Alert_broadcast -> false
  in
  Team_session_store.append_event config session.session_id ~event_type:"alert_emitted"
    ~detail:
      (`Assoc
        [
          ("message", `String message);
          ("broadcast", `Bool did_broadcast);
          ("board", `Bool did_board);
          ("portal_ping", `Bool can_portal);
          ("ts_iso", `String (now_iso ()));
        ]);
  {
    session with
    broadcast_count = session.broadcast_count + (if did_broadcast then 1 else 0);
    portal_count = session.portal_count + (if can_portal then 1 else 0);
  }

let maybe_add_fallback_task ~(config : Room.config)
    ~(session : Team_session_types.session) ~(active_count : int) : Team_session_types.session =
  let should_create =
    match session.fallback_policy with
    | Team_session_types.Fallback_none -> false
    | Team_session_types.Fallback_task_only -> true
    | Team_session_types.Fallback_cascade_then_task ->
        session.model_cascade = [] || session.cascade_failed > 0
  in
  if not should_create then
    session
  else if session.fallback_task_created > 0 then
    session  (* already created a fallback task for this session *)
  else
    let title =
      Printf.sprintf "Team session fallback (%s)" session.session_id
    in
    let desc =
      Printf.sprintf
        "goal=%s | min_agents=%d | active_agents=%d | policy=%s | ts=%s"
        session.goal session.min_agents active_count
        (Team_session_types.fallback_policy_to_string session.fallback_policy)
        (now_iso ())
    in
    let result = Room.add_task config ~title ~priority:1 ~description:desc in
    Team_session_store.append_event config session.session_id
      ~event_type:"fallback_task_created"
      ~detail:
        (`Assoc
          [
            ("message", `String result);
            ("active_agents", `Int active_count);
            ("ts_iso", `String (now_iso ()));
          ]);
    {
      session with
      fallback_task_created = session.fallback_task_created + 1;
      updated_at_iso = now_iso ();
    }

let apply_runtime_policy ~(config : Room.config)
    (session : Team_session_types.session) : Team_session_types.session =
  let session =
    if
      session.control_profile
      = Team_session_types.Control_hierarchical_quality_v1
    then (
      let now = Time_compat.now () in
      let grace_elapsed =
        now -. session.started_at >= 60.0
      in
      let events =
        Team_session_store.read_events ~max_events:2000 config session.session_id
      in
      let has_turn_for_actor actor_name =
        List.exists
          (fun json ->
            match
              ( Yojson.Safe.Util.member "event_type" json,
                Yojson.Safe.Util.member "detail" json
                |> Yojson.Safe.Util.member "actor" )
            with
            | `String "team_turn", `String actor ->
                String.equal (String.trim actor) actor_name
            | _ -> false)
          events
      in
      let no_turn_workers =
        if grace_elapsed then
          session.planned_workers
          |> List.filter (fun (worker : Team_session_types.planned_worker) ->
                 match worker.runtime_actor with
                 | Some actor -> not (has_turn_for_actor actor)
                 | None -> false)
        else []
      in
      let low_confidence_workers =
        session.planned_workers
        |> List.filter (fun (worker : Team_session_types.planned_worker) ->
               match worker.routing_confidence with
               | Some value -> value < 0.72
               | None -> false)
      in
      let spawn_failures =
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
      in
      let detached_count =
        List.fold_left
          (fun acc json ->
            match Yojson.Safe.Util.member "event_type" json with
            | `String "session_agent_detached" -> acc + 1
            | _ -> acc)
          0 events
      in
      Team_session_store.append_event config session.session_id
        ~event_type:"controller_tick"
        ~detail:
          (`Assoc
            [
              ("control_profile", `String "hierarchical_quality_v1");
              ("controller_tree", controller_tree_json_of_session session);
              ("lane_health", lane_health_json config session);
              ("confidence_heatmap", confidence_heatmap_json session);
              ("context_pressure_by_lane", context_pressure_by_lane_json session);
              ("spawn_failures", `Int spawn_failures);
              ("detached_count", `Int detached_count);
              ("no_turn_worker_count", `Int (List.length no_turn_workers));
              ( "low_confidence_worker_count",
                `Int (List.length low_confidence_workers) );
              ("ts_iso", `String (now_iso ()));
            ]);
      if no_turn_workers <> [] then
        Team_session_store.append_event config session.session_id
          ~event_type:"controller_intervention"
          ~detail:
            (`Assoc
              [
                ("controller", `String "ctrl-root");
                ("action", `String "reroute_candidates");
                ( "actors",
                  `List
                    (List.filter_map
                       (fun (worker : Team_session_types.planned_worker) ->
                         Option.map (fun actor -> `String actor)
                           worker.runtime_actor)
                       no_turn_workers) );
                ("ts_iso", `String (now_iso ()));
              ]);
      if spawn_failures > 0 || detached_count > 0 || low_confidence_workers <> [] then
        Team_session_store.append_event config session.session_id
          ~event_type:"controller_escalation"
          ~detail:
            (`Assoc
              [
                ("controller", `String "ctrl-root");
                ("reason", `String "quality_or_runtime_signal");
                ("spawn_failures", `Int spawn_failures);
                ("detached_count", `Int detached_count);
                ( "low_confidence_worker_count",
                  `Int (List.length low_confidence_workers) );
                ("ts_iso", `String (now_iso ()));
              ]);
      let controller_violations =
        []
        |> fun acc ->
        let acc =
          if no_turn_workers <> [] then
            "controller:no_turn_workers" :: acc
          else acc
        in
        let acc =
          if spawn_failures > 0 then "controller:spawn_failures" :: acc else acc
        in
        let acc =
          if detached_count > 0 then "controller:detached_workers" :: acc else acc
        in
        if low_confidence_workers <> [] then
          "controller:low_confidence" :: acc
        else acc
      in
      {
        session with
        policy_violations =
          Team_session_types.dedup_strings
            (session.policy_violations @ controller_violations);
      })
    else
      session
  in
  let now = Time_compat.now () in
  let active_agents = session_active_agent_names config session ~now in
  let active_count = List.length active_agents in
  let under_min_agents = active_count < session.min_agents in
  let within_bootstrap_grace =
    now -. session.started_at < bootstrap_grace_seconds session
  in
  if not under_min_agents then begin
    if session.min_agents_violation_streak > 0 then
      Team_session_store.append_event config session.session_id
        ~event_type:"min_agents_recovered"
        ~detail:
          (`Assoc
            [
              ("active_agents", `Int active_count);
              ("required", `Int session.min_agents);
              ("ts_iso", `String (now_iso ()));
            ]);
    { session with min_agents_violation_streak = 0 }
  end else if within_bootstrap_grace then
    session
  else
    let next_streak = session.min_agents_violation_streak + 1 in
    let violation_label =
      Printf.sprintf "active_agents_below_min:%d<%d" active_count session.min_agents
    in
    let with_violation =
      {
        session with
        min_agents_violation_streak = next_streak;
        policy_violations =
          policy_violations_add session.policy_violations violation_label;
      }
    in
    Team_session_store.append_event config session.session_id
      ~event_type:"min_agents_violation"
      ~detail:
        (`Assoc
          [
            ("active_agents", `Int active_count);
            ("required", `Int session.min_agents);
            ("streak", `Int next_streak);
            ("ts_iso", `String (now_iso ()));
          ]);
    let alert_tick = next_streak = 1 || next_streak mod 3 = 0 in
    let after_alert =
      if alert_tick then
        let message =
          Printf.sprintf
            "[team-session:%s] min_agents violation (active=%d required=%d streak=%d)"
            session.session_id active_count session.min_agents next_streak
        in
        emit_alert ~config ~session:with_violation ~message
      else
        with_violation
    in
    let after_cascade =
      if alert_tick
         && after_alert.fallback_policy
            = Team_session_types.Fallback_cascade_then_task
         && after_alert.model_cascade <> []
      then (
        Team_session_store.append_event config session.session_id
          ~event_type:"cascade_attempted"
          ~detail:
            (`Assoc
              [
                ( "models",
                  `List
                    (List.map (fun m -> `String m) after_alert.model_cascade) );
                ("result", `String "failed_unavailable_executor");
                ("ts_iso", `String (now_iso ()));
              ]);
        {
          after_alert with
          cascade_attempted = after_alert.cascade_attempted + 1;
          cascade_failed = after_alert.cascade_failed + 1;
          policy_violations =
            policy_violations_add after_alert.policy_violations
              "cascade_unavailable_executor";
        })
      else
        after_alert
    in
    if alert_tick then
      maybe_add_fallback_task ~config ~session:after_cascade ~active_count
    else
      after_cascade

let finalize_session ~(config : Room.config) ~(session_id : string)
    ~(final_status : Team_session_types.session_status) ~(reason : string)
    ~(generate_report : bool) : Team_session_types.session option =
  with_finalize_lock (fun () ->
      with_runtimes_lock (fun () ->
          match Hashtbl.find_opt runtimes session_id with
          | Some runtime -> runtime.finalizing <- true
          | None -> ());
      match Team_session_store.load_session config session_id with
      | None ->
          with_runtimes_lock (fun () -> Hashtbl.remove runtimes session_id);
          None
      | Some session ->
          if session.status <> Team_session_types.Running then begin
            if generate_report && not session.generated_report then
              generate_and_mark_report ~config session;
            with_runtimes_lock (fun () -> Hashtbl.remove runtimes session_id);
            Some session
          end else
            let now = Time_compat.now () in
            let final_done_delta_by_agent, final_done_delta_total =
              compute_live_done_delta config session
            in
            let terminal_status =
              match Team_session_state.terminal_status_of_session_status final_status with
              | Some status -> status
              | None ->
                  invalid_arg
                    "team_session_engine_policy.finalize_session: expected terminal status"
            in
            let running =
              match Team_session_state.of_running session with
              | Some running -> running
              | None ->
                  invalid_arg
                    "team_session_engine_policy.finalize_session: expected running session"
            in
            let updated =
              Team_session_state.finalize running ~final_status:terminal_status
                ~reason ~now
              |> Team_session_state.session
              |> fun value ->
              {
                value with
                final_done_delta_total = Some final_done_delta_total;
                final_done_delta_by_agent = Some final_done_delta_by_agent;
              }
            in
            Team_session_store.save_session config updated;
            detach_operation_attachment ~config ~session:updated;
            Team_session_store.append_event config session_id
              ~event_type:"session_finalized"
              ~detail:
                (`Assoc
                  [
                    ( "status",
                      `String
                        (Team_session_types.status_to_string final_status) );
                    ("reason", `String reason);
                    ("ts_iso", `String (now_iso ()));
                  ]);
            if generate_report then
              generate_and_mark_report ~config updated;
            with_runtimes_lock (fun () -> Hashtbl.remove runtimes session_id);
            Some updated)
