(** Eio runtime engine for long-running team sessions. *)

type runtime_state = {
  mutable stop_requested : bool;
  mutable stop_reason : string option;
  mutable finalizing : bool;
  mutable generate_report_on_finalize : bool;
}

let runtimes : (string, runtime_state) Hashtbl.t = Hashtbl.create 16
let runtimes_mutex = Eio.Mutex.create ()
let finalize_mutex = Eio.Mutex.create ()

let with_runtimes_lock f = Eio.Mutex.use_rw ~protect:true runtimes_mutex f
let with_finalize_lock f = Eio.Mutex.use_rw ~protect:true finalize_mutex f

let () = Random.self_init ()

let now_iso () = Types.now_iso ()
let is_cancelled exn = match exn with Eio.Cancel.Cancelled _ -> true | _ -> false

let clamp_int ~min_v ~max_v v = max min_v (min max_v v)

let rec take n xs =
  if n <= 0 then []
  else
    match xs with
    | [] -> []
    | x :: rest -> x :: take (n - 1) rest

let take_last max_items xs =
  if max_items <= 0 then []
  else
    let len = List.length xs in
    if len <= max_items then xs
    else
      let rec drop n ys =
        if n <= 0 then ys
        else
          match ys with
          | [] -> []
          | _ :: rest -> drop (n - 1) rest
      in
      drop (len - max_items) xs

let room_active_agent_names (config : Room.config) =
  Room.get_agents_raw config
  |> List.map (fun (a : Types.agent) -> a.name)
  |> Team_session_types.dedup_strings
  |> List.sort String.compare

let session_active_agent_names (session : Team_session_types.session) =
  Team_session_types.participant_names session

let bootstrap_grace_seconds (session : Team_session_types.session) =
  float_of_int (session.checkpoint_interval_sec * max 1 session.min_agents)

let session_visible_to_agent ~(agent_name : string)
    (session : Team_session_types.session) =
  String.equal agent_name session.created_by
  || List.exists (String.equal agent_name) session.agent_names

let session_allows_actor ~(actor : string) (session : Team_session_types.session) =
  String.equal actor session.created_by
  || List.exists (String.equal actor) session.agent_names

let session_has_attached_actor ~(config : Room.config) ~(session_id : string)
    ~(actor : string) =
  let open Yojson.Safe.Util in
  Team_session_store.read_events config session_id
  |> List.exists (fun event_json ->
         match event_json |> member "event_type" with
         | `String "session_agent_attached" -> (
             match event_json |> member "detail" |> member "actor" with
             | `String attached -> String.equal attached actor
             | _ -> false)
         | _ -> false)

let compute_live_done_delta (config : Room.config)
    (session : Team_session_types.session) =
  let backlog = Room.read_backlog config in
  let current_done = Team_session_types.done_counts_from_backlog backlog in
  let deltas =
    Team_session_types.done_delta_by_agent ~baseline:session.baseline_done_counts
      ~current:current_done ~agents:session.agent_names
  in
  let done_total = List.fold_left (fun acc (_, n) -> acc + n) 0 deltas in
  (deltas, done_total)

let done_delta_metrics (config : Room.config) (session : Team_session_types.session)
    : (string * int) list * int =
  match (session.final_done_delta_by_agent, session.final_done_delta_total) with
  | Some deltas, Some total -> (deltas, total)
  | Some deltas, None ->
      (deltas, List.fold_left (fun acc (_, n) -> acc + n) 0 deltas)
  | None, Some total ->
      let deltas, _ = compute_live_done_delta config session in
      (deltas, total)
  | None, None -> compute_live_done_delta config session

let policy_violations_add violations entry =
  Team_session_types.dedup_strings (violations @ [ entry ])
  |> take_last 64

let parse_summary_int key (json : Yojson.Safe.t) =
  match Yojson.Safe.Util.member key json with
  | `Int n -> n
  | `Intlit s -> (try int_of_string s with _ -> 0)
  | `Float v -> int_of_float v
  | _ -> 0

let parse_summary_float key (json : Yojson.Safe.t) =
  match Yojson.Safe.Util.member key json with
  | `Float v -> v
  | `Int n -> float_of_int n
  | `Intlit s -> (try float_of_string s with _ -> 0.0)
  | _ -> 0.0

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

let orchestration_state_json (session : Team_session_types.session) =
  `Assoc
    [
      ( "mode",
        `String
          (Team_session_types.orchestration_mode_to_string
             session.orchestration_mode) );
      ( "instruction_profile",
        `String
          (Team_session_types.instruction_profile_to_string
             session.instruction_profile) );
      ( "fallback_policy",
        `String
          (Team_session_types.fallback_policy_to_string
             session.fallback_policy) );
      ( "policy_violations",
        `List (List.map (fun v -> `String v) session.policy_violations) );
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

let generate_and_mark_report ~(config : Room.config)
    (session : Team_session_types.session) : unit =
  match Team_session_report.generate config session with
  | Ok _ -> (
      match Team_session_store.mark_report_generated config session.session_id with
      | Ok _ -> ()
      | Error e ->
          Printf.eprintf
            "[team_session] failed to mark report generated (%s): %s\n%!"
            session.session_id e)
  | Error e ->
      Printf.eprintf "[team_session] report generation failed (%s): %s\n%!"
        session.session_id e;
      Team_session_store.append_event config session.session_id
        ~event_type:"report_generation_failed"
        ~detail:(`Assoc [ ("error", `String e); ("ts_iso", `String (now_iso ())) ])

let summary_json_of_session (config : Room.config)
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
  let active_agents = session_active_agent_names session in
  let planned_runtime_actors = Team_session_types.planned_worker_actor_names session in
  let planned_participants = Team_session_types.planned_participant_names session in
  let room_active_agents = room_active_agent_names config in
  `Assoc
    [
      ("session_id", `String session.session_id);
      ("status", `String (Team_session_types.status_to_string session.status));
      ("elapsed_sec", `Int (int_of_float elapsed));
      ("remaining_sec", `Int (int_of_float remaining));
      ("progress_pct", `Float progress_pct);
      ("done_delta_total", `Int done_total);
      ("done_delta_by_agent", Team_session_types.assoc_int_to_json deltas);
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
      ( "last_checkpoint_at",
        Option.fold ~none:`Null ~some:(fun v -> `Float v)
          session.last_checkpoint_at );
      ("last_event_at", Option.fold ~none:`Null ~some:(fun v -> `Float v) session.last_event_at);
    ]

let status_sections (config : Room.config) (session : Team_session_types.session) =
  let summary = summary_json_of_session config session in
  let active_agents = session_active_agent_names session in
  let team_health = team_health_json session active_agents in
  let communication_metrics = communication_metrics_json session in
  let orchestration_state = orchestration_state_json session in
  let cascade_metrics = cascade_metrics_json session in
  (summary, team_health, communication_metrics, orchestration_state, cascade_metrics)

let session_status_json (config : Room.config) (session : Team_session_types.session) =
  let runtime_running =
    with_runtimes_lock (fun () -> Hashtbl.mem runtimes session.session_id)
  in
  let llm_cache_metrics = Prometheus.llm_cache_metrics_json () in
  let summary, team_health, communication_metrics, orchestration_state,
      cascade_metrics =
    status_sections config session
  in
  `Assoc
    [
      ("session", Team_session_types.session_to_yojson session);
      ("runtime_running", `Bool runtime_running);
      ("summary", summary);
      ("team_health", team_health);
      ("communication_metrics", communication_metrics);
      ("orchestration_state", orchestration_state);
      ("cascade_metrics", cascade_metrics);
      ("llm_cache_metrics", llm_cache_metrics);
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
    ]

let write_checkpoint (config : Room.config) (session : Team_session_types.session) =
  let now = Time_compat.now () in
  let backlog = Room.read_backlog config in
  let current_done = Team_session_types.done_counts_from_backlog backlog in
  let deltas =
    Team_session_types.done_delta_by_agent ~baseline:session.baseline_done_counts
      ~current:current_done ~agents:session.agent_names
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
  let active_agents = session_active_agent_names session in
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
  let active_agents = session_active_agent_names session in
  let active_count = List.length active_agents in
  let under_min_agents = active_count < session.min_agents in
  let now = Time_compat.now () in
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
            let updated =
              {
                session with
                status = final_status;
                stopped_at = Some now;
                stop_reason = Some reason;
                final_done_delta_total = Some final_done_delta_total;
                final_done_delta_by_agent = Some final_done_delta_by_agent;
                last_event_at = Some now;
                updated_at_iso = now_iso ();
              }
            in
            Team_session_store.save_session config updated;
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

let start_runtime_loop ~sw ~(clock : _ Eio.Time.clock) ~(config : Room.config)
    ~(session_id : string) =
  Eio.Fiber.fork ~sw (fun () ->
      let rec loop () =
        match Team_session_store.load_session config session_id with
        | None ->
            with_runtimes_lock (fun () -> Hashtbl.remove runtimes session_id)
        | Some session ->
            if session.status <> Team_session_types.Running then
              with_runtimes_lock (fun () -> Hashtbl.remove runtimes session_id)
            else
              let runtime_snapshot =
                with_runtimes_lock (fun () -> Hashtbl.find_opt runtimes session_id)
              in
              let stop_requested, stop_reason, generate_report_on_finalize =
                match runtime_snapshot with
                | Some r ->
                    ( r.stop_requested,
                      Option.value r.stop_reason ~default:"stop_requested",
                      r.generate_report_on_finalize )
                | None -> (true, "runtime_missing", true)
              in
              let now = Time_compat.now () in
              if stop_requested then
                ignore
                  (finalize_session ~config ~session_id
                     ~final_status:Team_session_types.Interrupted ~reason:stop_reason
                     ~generate_report:generate_report_on_finalize)
              else if now >= session.planned_end_at then
                ignore
                  (finalize_session ~config ~session_id
                     ~final_status:Team_session_types.Completed
                     ~reason:"duration_reached" ~generate_report:true)
              else begin
                let should_checkpoint =
                  match session.last_checkpoint_at with
                  | None -> true
                  | Some ts ->
                      now -. ts >= float_of_int session.checkpoint_interval_sec
                in
                if should_checkpoint then
                  with_finalize_lock (fun () ->
                      write_checkpoint config session;
                      let can_persist_running_state =
                        with_runtimes_lock (fun () ->
                            match Hashtbl.find_opt runtimes session_id with
                            | Some runtime ->
                                not runtime.stop_requested && not runtime.finalizing
                            | None -> false)
                      in
                      if can_persist_running_state then begin
                        let after_policy = apply_runtime_policy ~config session in
                        let updated =
                          {
                            after_policy with
                            last_checkpoint_at = Some now;
                            last_event_at = Some now;
                            updated_at_iso = now_iso ();
                          }
                        in
                        Team_session_store.save_session config updated;
                        Team_session_store.append_event config session_id
                          ~event_type:"checkpoint"
                          ~detail:(summary_json_of_session config updated)
                      end);
                let sleep_sec = min 15.0 (max 1.0 (session.planned_end_at -. now)) in
                Eio.Time.sleep clock sleep_sec;
                loop ()
              end
      in
      try loop ()
      with exn ->
        if is_cancelled exn then raise exn;
        let reason = Printexc.to_string exn in
        ignore
          (finalize_session ~config ~session_id
             ~final_status:Team_session_types.Failed ~reason
             ~generate_report:true))

let start_session ~sw ~(clock : _ Eio.Time.clock) ~(config : Room.config)
    ~(created_by : string) ~(goal : string) ~(duration_seconds : int)
    ~(execution_scope : Team_session_types.execution_scope)
    ~(checkpoint_interval_sec : int) ~(min_agents : int)
    ~(orchestration_mode : Team_session_types.orchestration_mode)
    ~(communication_mode : Team_session_types.communication_mode)
    ~(model_cascade : string list)
    ~(fallback_policy : Team_session_types.fallback_policy)
    ~(instruction_profile : Team_session_types.instruction_profile)
    ~(alert_channel : Team_session_types.alert_channel) ~(auto_resume : bool)
    ~(report_formats : Team_session_types.report_format list)
    ~(agent_names : string list) : (Yojson.Safe.t, string) result =
  try
    Room_utils.ensure_initialized config;
    let duration_seconds = clamp_int ~min_v:60 ~max_v:28800 duration_seconds in
    let checkpoint_interval_sec =
      clamp_int ~min_v:10 ~max_v:600 checkpoint_interval_sec
    in
    let min_agents = clamp_int ~min_v:1 ~max_v:64 min_agents in
    let now = Time_compat.now () in
    let session_id = Team_session_store.make_session_id () in
    Team_session_store.ensure_session_dirs config session_id;
    let room_id =
      Room_utils.read_current_room config |> Option.value ~default:"default"
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
        room_id;
        status = Team_session_types.Running;
        duration_seconds;
        execution_scope;
        checkpoint_interval_sec;
        min_agents;
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
        artifacts_dir = Team_session_store.session_dir config session_id;
        created_at_iso = now_iso ();
        updated_at_iso = now_iso ();
      }
    in
    Team_session_store.save_session config session;
    Team_session_store.append_event config session_id ~event_type:"session_started"
      ~detail:
        (`Assoc
          [
            ("goal", `String goal);
            ("created_by", `String created_by);
            ("duration_seconds", `Int duration_seconds);
            ("agent_count", `Int (List.length selected_agents));
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
    write_checkpoint config session;
    with_runtimes_lock (fun () ->
        Hashtbl.replace runtimes session_id
          {
            stop_requested = false;
            stop_reason = None;
            finalizing = false;
            generate_report_on_finalize = true;
          });
    start_runtime_loop ~sw ~clock ~config ~session_id;
    Ok
      (`Assoc
        [
          ("session_id", `String session_id);
          ("status", `String "running");
          ("started_at", `Float now);
          ("planned_end_at", `Float session.planned_end_at);
          ("artifacts_dir", `String session.artifacts_dir);
          ( "orchestration_mode",
            `String
              (Team_session_types.orchestration_mode_to_string orchestration_mode)
          );
          ( "communication_mode",
            `String
              (Team_session_types.communication_mode_to_string communication_mode)
          );
          ("model_cascade", `List (List.map (fun m -> `String m) model_cascade));
        ])
  with exn -> Error (Printexc.to_string exn)

let status_session ~(config : Room.config) ~(session_id : string) :
    (Yojson.Safe.t, string) result =
  match Team_session_store.load_session config session_id with
  | None -> Error (Printf.sprintf "team session not found: %s" session_id)
  | Some session -> Ok (session_status_json config session)

let stop_session ~(config : Room.config) ~(session_id : string) ~(reason : string)
    ~(generate_report : bool) : (Yojson.Safe.t, string) result =
  match Team_session_store.load_session config session_id with
  | None -> Error (Printf.sprintf "team session not found: %s" session_id)
  | Some session ->
      if session.status = Team_session_types.Running then begin
        let accepted =
          with_runtimes_lock (fun () ->
              match Hashtbl.find_opt runtimes session_id with
              | Some runtime ->
                  if runtime.finalizing then
                    false
                  else (
                    runtime.stop_requested <- true;
                    runtime.stop_reason <- Some reason;
                    runtime.generate_report_on_finalize <- generate_report;
                    true)
              | None -> false)
        in
        if accepted then
          Ok
            (`Assoc
              [
                ("session_id", `String session_id);
                ("status", `String "stop_requested");
                ("reason", `String reason);
              ])
        else
          let reloaded = Team_session_store.load_session config session_id in
          let updated =
            match reloaded with
            | Some s when s.status <> Team_session_types.Running -> Some s
            | _ ->
                finalize_session ~config ~session_id
                  ~final_status:Team_session_types.Interrupted ~reason
                  ~generate_report
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
  | Some session when session.status <> Team_session_types.Running ->
      Error "turn recording is only allowed while session is running"
  | Some session
    when not
           (session_allows_actor ~actor session
           || session_has_attached_actor ~config ~session_id ~actor) ->
      Error "actor is not authorized for this team session"
  | Some session -> (
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
      | Team_session_types.Turn_note ->
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
                  ( "message",
                    Option.fold ~none:`Null ~some:(fun s -> `String s) message );
                  ("ts_iso", `String (now_iso ()));
                ]);
          Ok
            (`Assoc
              [
                ("session_id", `String session_id);
                ("turn_no", `Int updated.turn_count);
                ("kind", `String "note");
              ])
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
            | `Intlit s -> (try float_of_string s > ts with _ -> false)
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
              Team_session_store.write_text_file proof_md_path proof_markdown;
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
              ("llm_cache_metrics", Prometheus.llm_cache_metrics_json ());
            ])
        sessions
    in
    Ok
      (`Assoc
        [
          ("count", `Int (List.length items));
          ("sessions", `List items);
        ])
  with exn -> Error (Printexc.to_string exn)

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

let recover_running_sessions ~sw ~(clock : _ Eio.Time.clock)
    ~(config : Room.config) : unit =
  let sessions = Team_session_store.list_sessions config in
  let now = Time_compat.now () in
  List.iter
    (fun (session : Team_session_types.session) ->
      if session.status = Team_session_types.Running && session.auto_resume then
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
            Team_session_store.append_event config session.session_id
              ~event_type:"recovered_after_restart"
              ~detail:
                (`Assoc
                  [
                    ( "remaining_sec",
                      `Int
                        (int_of_float (session.planned_end_at -. now)) );
                    ("ts_iso", `String (now_iso ()));
                  ]);
            start_runtime_loop ~sw ~clock ~config
              ~session_id:session.session_id
          end)
    sessions
