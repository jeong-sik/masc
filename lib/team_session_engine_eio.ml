(** Eio runtime engine for long-running team sessions. *)

type runtime_state = {
  mutable stop_requested : bool;
  mutable stop_reason : string option;
  mutable finalizing : bool;
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
        ~detail:
          (`Assoc
            [ ("error", `String e); ("ts_iso", `String (now_iso ())) ])

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

let summary_json_of_session (config : Room.config) (session : Team_session_types.session) =
  let now = Time_compat.now () in
  let end_time = Option.value session.stopped_at ~default:now in
  let elapsed = max 0.0 (end_time -. session.started_at) in
  let remaining = max 0.0 (session.planned_end_at -. now) in
  let progress_pct =
    if session.duration_seconds <= 0 then 100.0
    else min 100.0 (100.0 *. (elapsed /. float_of_int session.duration_seconds))
  in
  let backlog = Room.read_backlog config in
  let current_done = done_counts_from_backlog backlog in
  let deltas =
    Team_session_types.done_delta_by_agent
      ~baseline:session.baseline_done_counts ~current:current_done
      ~agents:session.agent_names
  in
  let done_total = List.fold_left (fun acc (_, n) -> acc + n) 0 deltas in
  let active_agents =
    Room.get_agents_raw config
    |> List.map (fun (a : Types.agent) -> a.name)
    |> List.sort String.compare
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
      ("active_agents", `List (List.map (fun a -> `String a) active_agents));
      ("last_checkpoint_at", Option.fold ~none:`Null ~some:(fun v -> `Float v) session.last_checkpoint_at);
      ("last_event_at", Option.fold ~none:`Null ~some:(fun v -> `Float v) session.last_event_at);
    ]

let session_status_json (config : Room.config) (session : Team_session_types.session) =
  let runtime_running =
    with_runtimes_lock (fun () -> Hashtbl.mem runtimes session.session_id)
  in
  let summary = summary_json_of_session config session in
  `Assoc
    [
      ("session", Team_session_types.session_to_yojson session);
      ("runtime_running", `Bool runtime_running);
      ("summary", summary);
      ("report_paths", `Assoc [
        ("markdown", `String (Team_session_store.report_md_path config session.session_id));
        ("json", `String (Team_session_store.report_json_path config session.session_id));
      ]);
    ]

let write_checkpoint (config : Room.config) (session : Team_session_types.session) =
  let now = Time_compat.now () in
  let backlog = Room.read_backlog config in
  let current_done = done_counts_from_backlog backlog in
  let deltas =
    Team_session_types.done_delta_by_agent
      ~baseline:session.baseline_done_counts ~current:current_done
      ~agents:session.agent_names
  in
  let done_total = List.fold_left (fun acc (_, n) -> acc + n) 0 deltas in
  let elapsed = max 0.0 (now -. session.started_at) in
  let remaining = max 0.0 (session.planned_end_at -. now) in
  let progress_pct =
    if session.duration_seconds <= 0 then 100.0
    else min 100.0 (100.0 *. (elapsed /. float_of_int session.duration_seconds))
  in
  let active_agents =
    Room.get_agents_raw config
    |> List.map (fun (a : Types.agent) -> a.name)
    |> List.sort String.compare
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
            if generate_report && (not session.generated_report) then
              generate_and_mark_report ~config session;
            with_runtimes_lock (fun () -> Hashtbl.remove runtimes session_id);
            Some session
          end else
            let now = Time_compat.now () in
            let updated =
              {
                session with
                status = final_status;
                stopped_at = Some now;
                stop_reason = Some reason;
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
              let stop_requested, stop_reason =
                match runtime_snapshot with
                | Some r -> (r.stop_requested, Option.value r.stop_reason ~default:"stop_requested")
                | None -> (true, "runtime_missing")
              in
              let now = Time_compat.now () in
              if stop_requested then
                ignore
                  (finalize_session ~config ~session_id
                     ~final_status:Team_session_types.Interrupted ~reason:stop_reason
                     ~generate_report:true)
              else if now >= session.planned_end_at then
                ignore
                  (finalize_session ~config ~session_id
                     ~final_status:Team_session_types.Completed
                     ~reason:"duration_reached" ~generate_report:true)
              else begin
                let should_checkpoint =
                  match session.last_checkpoint_at with
                  | None -> true
                  | Some ts -> (now -. ts) >= float_of_int session.checkpoint_interval_sec
                in
                if should_checkpoint then begin
                  write_checkpoint config session;
                  let can_persist_running_state =
                    with_runtimes_lock (fun () ->
                        match Hashtbl.find_opt runtimes session_id with
                        | Some runtime ->
                            (not runtime.stop_requested)
                            && not runtime.finalizing
                        | None -> false)
                  in
                  if can_persist_running_state then begin
                    let updated =
                      {
                        session with
                        last_checkpoint_at = Some now;
                        last_event_at = Some now;
                        updated_at_iso = now_iso ();
                      }
                    in
                    Team_session_store.save_session config updated;
                    Team_session_store.append_event config session_id
                      ~event_type:"checkpoint"
                      ~detail:(summary_json_of_session config updated)
                  end
                end;
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
             ~final_status:Team_session_types.Failed ~reason ~generate_report:true))

let start_session ~sw ~(clock : _ Eio.Time.clock) ~(config : Room.config)
    ~(created_by : string) ~(goal : string) ~(duration_seconds : int)
    ~(execution_scope : Team_session_types.execution_scope)
    ~(checkpoint_interval_sec : int) ~(min_agents : int)
    ~(auto_resume : bool) ~(report_formats : Team_session_types.report_format list)
    ~(agent_names : string list) : (Yojson.Safe.t, string) result =
  try
    Room_utils.ensure_initialized config;
    let duration_seconds = clamp_int ~min_v:60 ~max_v:28800 duration_seconds in
    let checkpoint_interval_sec = clamp_int ~min_v:10 ~max_v:600 checkpoint_interval_sec in
    let min_agents = clamp_int ~min_v:1 ~max_v:64 min_agents in
    let now = Time_compat.now () in
    let session_id = Team_session_store.make_session_id () in
    Team_session_store.ensure_session_dirs config session_id;
    let room_id = Room_utils.read_current_room config |> Option.value ~default:"default" in
    let selected_agents =
      if agent_names <> [] then
        agent_names
      else
        let discovered =
          Room.get_agents_raw config
          |> List.map (fun (a : Types.agent) -> a.name)
        in
        if discovered = [] then [ created_by ] else discovered
    in
    let baseline_done_counts = done_counts_from_backlog (Room.read_backlog config) in
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
        auto_resume;
        report_formats = if report_formats = [] then [ Team_session_types.Markdown; Team_session_types.Json ] else report_formats;
        agent_names = selected_agents;
        baseline_done_counts;
        started_at = now;
        planned_end_at = now +. float_of_int duration_seconds;
        stopped_at = None;
        last_checkpoint_at = Some now;
        last_event_at = Some now;
        stop_reason = None;
        generated_report = false;
        artifacts_dir = Team_session_store.session_dir config session_id;
        created_at_iso = now_iso ();
        updated_at_iso = now_iso ();
      }
    in
    Team_session_store.save_session config session;
    Team_session_store.append_event config session_id ~event_type:"session_started"
      ~detail:(`Assoc [
        ("goal", `String goal);
        ("created_by", `String created_by);
        ("duration_seconds", `Int duration_seconds);
        ("agent_count", `Int (List.length selected_agents));
      ]);
    write_checkpoint config session;
    with_runtimes_lock (fun () ->
        Hashtbl.replace runtimes session_id
          { stop_requested = false; stop_reason = None; finalizing = false });
    start_runtime_loop ~sw ~clock ~config ~session_id;
    Ok
      (`Assoc
        [
          ("session_id", `String session_id);
          ("status", `String "running");
          ("started_at", `Float now);
          ("planned_end_at", `Float session.planned_end_at);
          ("artifacts_dir", `String session.artifacts_dir);
        ])
  with exn -> Error (Printexc.to_string exn)

let status_session ~(config : Room.config) ~(session_id : string) : (Yojson.Safe.t, string) result =
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
          | None -> Error (Printf.sprintf "team session not found: %s" session_id))
      end else
        let response =
          if generate_report then (
            generate_and_mark_report ~config session;
            `Assoc
              [
                ("session_id", `String session_id);
                ("status", `String (Team_session_types.status_to_string session.status));
                ("report_generated", `Bool true);
              ])
          else
            `Assoc
              [
                ("session_id", `String session_id);
                ("status", `String (Team_session_types.status_to_string session.status));
              ]
        in
        Ok response

let generate_report ~(config : Room.config) ~(session_id : string)
    ~(force_regenerate : bool) : (Yojson.Safe.t, string) result =
  match Team_session_store.load_session config session_id with
  | None -> Error (Printf.sprintf "team session not found: %s" session_id)
  | Some session ->
      let report_json_exists = Room_utils.path_exists config (Team_session_store.report_json_path config session_id) in
      let report_md_exists = Room_utils.path_exists config (Team_session_store.report_md_path config session_id) in
      if (not force_regenerate) && session.generated_report && report_json_exists && report_md_exists then
        Ok
          (`Assoc
            [
              ("session_id", `String session_id);
              ("status", `String "ok");
              ("regenerated", `Bool false);
              ("markdown_path", `String (Team_session_store.report_md_path config session_id));
              ("json_path", `String (Team_session_store.report_json_path config session_id));
            ])
      else
        (match Team_session_report.generate config session with
        | Error e -> Error e
        | Ok (_json, markdown) ->
            ignore (Team_session_store.mark_report_generated config session_id);
            Ok
              (`Assoc
                [
                  ("session_id", `String session_id);
                  ("status", `String "ok");
                  ("regenerated", `Bool true);
                  ("summary", `String (if String.length markdown > 240 then String.sub markdown 0 240 ^ "..." else markdown));
                  ("markdown_path", `String (Team_session_store.report_md_path config session_id));
                  ("json_path", `String (Team_session_store.report_json_path config session_id));
                ]))

let recover_running_sessions ~sw ~(clock : _ Eio.Time.clock)
    ~(config : Room.config) : unit =
  let sessions = Team_session_store.list_sessions config in
  let now = Time_compat.now () in
  List.iter
    (fun (session : Team_session_types.session) ->
      if session.status = Team_session_types.Running && session.auto_resume then
        let already_running =
          with_runtimes_lock (fun () -> Hashtbl.mem runtimes session.session_id)
        in
        if not already_running then
          if now >= session.planned_end_at then
            ignore
              (finalize_session ~config ~session_id:session.session_id
                 ~final_status:Team_session_types.Completed
                 ~reason:"duration_elapsed_during_restart" ~generate_report:true)
          else begin
            with_runtimes_lock (fun () ->
                Hashtbl.replace runtimes session.session_id
                  { stop_requested = false; stop_reason = None; finalizing = false });
            Team_session_store.append_event config session.session_id
              ~event_type:"recovered_after_restart"
              ~detail:(`Assoc [
                ("remaining_sec", `Int (int_of_float (session.planned_end_at -. now)));
                ("ts_iso", `String (now_iso ()));
              ]);
            start_runtime_loop ~sw ~clock ~config ~session_id:session.session_id
          end)
    sessions
