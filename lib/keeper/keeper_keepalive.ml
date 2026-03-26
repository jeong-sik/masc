(** Keeper_keepalive — resident heartbeat fiber and board-reactive wakeup.

    Per-keeper lifecycle (start, stop, wakeup) is managed through
    [Keeper_registry] (SSOT).  This module provides the heartbeat loop
    body, board-reactive wakeup filtering, and optional gRPC heartbeat
    fiber. *)

open Keeper_types
open Keeper_memory
open Keeper_execution

(* ── Board-reactive policy constants ── *)

let board_reactive_debounce_sec = 60.0
let board_reactive_threshold = 4

(* OAS Event_bus ref — set via bootstrap *)
let bus_ref : Agent_sdk.Event_bus.t option ref = ref None
let set_bus bus = bus_ref := Some bus
let get_bus () = !bus_ref

(** Optional gRPC client — set at server bootstrap when
    [MASC_AGENT_TRANSPORT=grpc]. When set, heartbeat also sends
    pings over the gRPC bidirectional stream. *)
let grpc_client_ref : Masc_grpc_client.t option ref = ref None
let set_grpc_client c = grpc_client_ref := Some c

(** Sleep in short chunks so [stop_keepalive] or [wakeup_keeper] takes
    effect within ~2 s instead of waiting for the full 30-300 s interval. *)
let interruptible_sleep ~clock ~stop ~wakeup duration =
  let rec wait remaining =
    if !stop then ()
    else if !wakeup then (wakeup := false)
    else if remaining <= 0.0 then ()
    else begin
      let chunk = Float.min 2.0 remaining in
      Eio.Time.sleep clock chunk;
      wait (remaining -. chunk)
    end
  in
  wait duration

(** Wake up a specific keeper immediately, causing it to skip the rest of
    its sleep and run the next heartbeat cycle. Used by broadcast notification
    when a @mention targets a running keeper. *)
let wakeup_keeper name =
  Keeper_registry.all ()
  |> List.iter (fun (entry : Keeper_registry.registry_entry) ->
         if String.equal entry.name name && entry.state = Keeper_registry.Running
         then Keeper_registry.wakeup ~base_path:entry.base_path name)

(** Wake up all running keepers — used when a broadcast mentions @@all
    or when a system-wide event requires immediate attention. *)
let wakeup_all_keepers () =
  Keeper_registry.wakeup_all ()

let board_reactive_wakeup_allowed ~base_path ~keeper_name ~post_id =
  Keeper_registry.board_wakeup_allowed ~base_path keeper_name
    ~post_id ~debounce_sec:board_reactive_debounce_sec

let wakeup_relevant_keeper_for_board_signal
    ~(config : Room.config)
    (signal : Board_dispatch.keeper_board_signal) =
  let running_names =
    Keeper_registry.all ()
    |> List.filter_map (fun (e : Keeper_registry.registry_entry) ->
           if e.state = Keeper_registry.Running then Some e.name else None)
  in
  let candidates =
    running_names
    |> List.filter_map (fun name ->
           match read_meta config name with
           | Ok (Some meta) ->
               let matched =
                 Keeper_world_observation.board_signal_match
                   ~continuity_summary:meta.continuity_summary
                   ~meta
                   ~signal
               in
               Some (meta, matched)
           | _ -> None)
  in
  let explicit =
    candidates
    |> List.filter (fun (_meta, (matched : Keeper_world_observation.board_signal_match)) ->
           matched.explicit_mention)
  in
  let wake_meta (meta : keeper_meta) reason =
    if board_reactive_wakeup_allowed
         ~base_path:config.base_path
         ~keeper_name:meta.name
         ~post_id:signal.post_id
    then (
      wakeup_keeper meta.name;
      Log.Keeper.info "board signal wakeup: keeper=%s reason=%s post=%s"
        meta.name reason signal.post_id)
  in
  match explicit with
  | (_ :: _) ->
      explicit
      |> List.iter (fun (meta, _matched) -> wake_meta meta "explicit_mention")
  | [] ->
      let best : (keeper_meta * Keeper_world_observation.board_signal_match) list =
        candidates
        |> List.filter
             (fun (_meta, (matched : Keeper_world_observation.board_signal_match)) ->
               matched.score >= board_reactive_threshold)
        |> List.sort
             (fun
               ((meta_a, matched_a) :
                 keeper_meta * Keeper_world_observation.board_signal_match)
               ((meta_b, matched_b) :
                 keeper_meta * Keeper_world_observation.board_signal_match) ->
               let by_score = compare matched_b.score matched_a.score in
               if by_score <> 0 then by_score
               else compare meta_a.proactive.last_ts meta_b.proactive.last_ts)
      in
      (match best with
       | (meta, _matched) :: _ -> wake_meta meta "relevance_scored"
       | [] -> ())

let run_heartbeat_loop ~proactive_warmup_sec (ctx : _ context)
    (m : keeper_meta) (stop : bool ref) ~(wakeup : bool ref) : unit =
  let keepalive_started_ts = Time_compat.now () in
  let snapshot_interval_sec =
    match Sys.getenv_opt "MASC_KEEPER_SNAPSHOT_SEC" with
    | Some s ->
        (try
           max 15 (min 3600 (int_of_string (String.trim s)))
         with Failure _ -> 60)
    | None -> 60
  in
  let last_snapshot_ts = ref 0.0 in
  let rec loop () =
    if !stop then ()
    else (
            let meta_current =
              match read_meta ctx.config m.name with
              | Ok (Some latest) -> latest
              | _ -> m
            in
            let meta_current =
              try
                let synced = ensure_keeper_room_presence ctx.config meta_current in
                (match write_meta ctx.config synced with
                 | Ok () -> synced  (* use written value directly, no second read_meta *)
                 | Error e ->
                   Log.Keeper.warn "write_meta failed (heartbeat): %s" e;
                   synced)
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn ->
                Log.Keeper.error "room heartbeat failed: %s"
                  (Printexc.to_string exn);
                meta_current
            in
            let now_ts = Time_compat.now () in
            if now_ts -. !last_snapshot_ts >= float_of_int snapshot_interval_sec
            then (
              (try
                 let metrics_store =
                   keeper_metrics_store ctx.config meta_current.name
                 in
                 let cascade_models = Oas_model_resolve.models_of_cascade_name meta_current.cascade_name in
                 let primary_max_context =
                   Oas_model_resolve.resolve_primary_max_context cascade_models
                 in
                 let base_dir = session_base_dir ctx.config in
                 (* Ensure session directory tree for filesystem fallback (issue #3019) *)
                 Fs_compat.mkdir_p (Filename.concat base_dir meta_current.trace_id);
                 let _session, ctx_opt =
                   load_context_from_checkpoint
                     ~trace_id:meta_current.trace_id
                     ~primary_model_max_tokens:primary_max_context
                     ~base_dir
                 in
                 (match ctx_opt with
                 | None -> ()
                 | Some c ->
                     let latest_user_message =
                       latest_message_content_by_role ~role:Agent_sdk.Types.User
                         c.messages
                     in
                     let latest_assistant_message =
                       latest_message_content_by_role
                         ~role:Agent_sdk.Types.Assistant c.messages
                     in
                     let continuity_snapshot =
                       latest_state_snapshot_from_messages c.messages
                     in
                     let continuity_summary =
                       match continuity_snapshot with
                       | Some s -> keeper_state_snapshot_to_summary_text s
                       | None ->
                           let trimmed =
                             String.trim meta_current.continuity_summary
                           in
                           if trimmed = "" then
                             "No continuity snapshot available."
                           else trimmed
                     in
                     let repetition_risk =
                       repetition_risk_score ~messages:c.messages
                         ~candidate_reply:None
                     in
                     let goal_alignment =
                       goal_alignment_score ~meta:meta_current
                         ~user_message:latest_user_message
                         ~assistant_reply:latest_assistant_message
                     in
                     let response_alignment =
                       match latest_user_message, latest_assistant_message with
                       | Some user_message, Some assistant_message ->
                           jaccard_similarity user_message assistant_message
                       | _ -> 0.0
                     in
                     let auto_rules =
                       evaluate_keeper_auto_rules ~meta:meta_current
                         ~context_ratio:(Keeper_exec_context.context_ratio c)
                         ~message_count:(List.length c.messages)
                         ~token_count:c.token_count ~repetition_risk
                         ~goal_alignment ~response_alignment
                         ()
                     in
                     let snapshot =
                       `Assoc
                         [
                           ("ts", `String (now_iso ()));
                           ("ts_unix", `Float now_ts);
                           ("channel", `String "heartbeat");
                           ("name", `String meta_current.name);
                           ("agent_name", `String meta_current.agent_name);
                           ("trace_id", `String meta_current.trace_id);
                           ("generation", `Int meta_current.generation);
                           ("model_used", `String meta_current.usage.last_model_used);
                           ( "usage",
                             `Assoc
                               [
                                 ("input_tokens", `Int 0);
                                 ("output_tokens", `Int 0);
                                 ("total_tokens", `Int 0);
                               ] );
                           ("latency_ms", `Int 0);
                           ("cost_usd", `Float 0.0);
                           ( "context_ratio",
                             `Float (Keeper_exec_context.context_ratio c) );
                           ("context_tokens", `Int c.token_count);
                           ("context_max", `Int c.max_tokens);
                           ("message_count", `Int (List.length c.messages));
                           ( "continuity_state",
                             match continuity_snapshot with
                             | None -> `Null
                             | Some s -> keeper_state_snapshot_to_json s );
                           ("continuity_summary", `String continuity_summary);
                           ("compacted", `Bool false);
                           ("compaction_before_tokens", `Int c.token_count);
                           ("compaction_after_tokens", `Int c.token_count);
                           ("work_kind", `String "status_tick");
                           ("tool_call_count", `Int 0);
                           ("tools_used", `List []);
                           ("snapshot_source", `String "keeper_context_status");
                           ("memory_check", memory_check_default_json ());
                           ( "auto_rules",
                             keeper_auto_rule_eval_to_json auto_rules );
                           ( "reflection",
                             keeper_reflection_payload_of_auto_rules auto_rules
                           );
                           ("auto_reflect", `Bool auto_rules.reflect);
                           ("auto_plan", `Bool auto_rules.plan);
                           ("auto_compact", `Bool auto_rules.compact);
                           ("auto_handoff", `Bool auto_rules.handoff);
                           ("repetition_risk", `Float repetition_risk);
                           ("goal_alignment", `Float goal_alignment);
                           ("response_alignment", `Float response_alignment);
                           ("goal_drift", `Float auto_rules.goal_drift);
                           ("guardrail_stop", `Bool auto_rules.guardrail_stop);
                           ( "guardrail_stop_reason",
                             match auto_rules.guardrail_reason with
                             | Some reason -> `String reason
                             | None -> `Null );
                           ("handoff", `Assoc [ ("performed", `Bool false) ]);
                         ]
                     in
                     Dated_jsonl.append metrics_store snapshot;
                     (try
                        Sse.broadcast
                          (`Assoc
                            [
                              ("type", `String "keeper_heartbeat");
                              ("name", `String meta_current.name);
                              ("generation", `Int meta_current.generation);
                              ( "context_ratio",
                                `Float (Keeper_exec_context.context_ratio c) );
                              ("ts_unix", `Float now_ts);
                            ])
                      with
                      | Eio.Cancel.Cancelled _ as e -> raise e
                      | exn ->
                        Log.Keeper.error "heartbeat SSE broadcast failed: %s"
                          (Printexc.to_string exn));
                     (* OAS: publish keeper snapshot event *)
                     (match !bus_ref with
                      | Some bus ->
                          Oas_events.publish_keeper_snapshot bus
                            ~keeper_name:meta_current.name
                            ~generation:meta_current.generation
                            ~context_ratio:(Keeper_exec_context.context_ratio c)
                            ~message_count:(List.length c.messages)
                      | None -> ()))
               with
               | Eio.Cancel.Cancelled _ as e -> raise e
               | exn ->
                 Log.Keeper.error "heartbeat snapshot write failed: %s"
                   (Printexc.to_string exn));
              last_snapshot_ts := now_ts);
            (* Triage is always computed. Tool gating is no longer mode-based. *)
            let pending_board_events, meta_after_triage =
              let obs =
                Keeper_deliberation.empty_world_observation
                  ~keeper_name:meta_current.name
              in
              let unclaimed_count, failed_count =
                (try
                   let backlog = Room.read_backlog ctx.config in
                   let unclaimed =
                     List.length
                       (List.filter
                          (fun (t : Types.task) ->
                            t.task_status = Types.Todo)
                          backlog.tasks)
                   in
                   let failed =
                     List.length
                       (List.filter
                          (fun (t : Types.task) ->
                            match t.task_status with
                            | Types.Cancelled _ -> true
                            | _ -> false)
                          backlog.tasks)
                   in
                   (unclaimed, failed)
                 with
                 | Eio.Cancel.Cancelled _ as e -> raise e
                 | exn ->
                     Log.Keeper.warn "keepalive: task count query failed: %s"
                       (Printexc.to_string exn);
                     (0, 0))
              in
              let current_agent_count =
                (try
                   List.length (Room.get_agents_raw ctx.config)
                 with
                 | Eio.Cancel.Cancelled _ as e -> raise e
                 | exn ->
                     Log.Keeper.warn "keepalive: agent count query failed: %s"
                       (Printexc.to_string exn);
                     0)
              in
              let agent_count_changed =
                let last_count =
                  Keeper_registry.get_last_agent_count
                    ~base_path:ctx.config.base_path meta_current.name
                in
                let changed =
                  last_count > 0 && current_agent_count <> last_count
                in
                Keeper_registry.set_last_agent_count
                  ~base_path:ctx.config.base_path
                  meta_current.name current_agent_count;
                changed
              in
              let pending_board_events, board_new_post_count, board_mention_count =
                (try
                   let events, new_count, mention_count =
                     Keeper_world_observation.collect_board_events
                       ~base_path:ctx.config.base_path
                       ~meta:meta_current
                       ~continuity_summary:meta_current.continuity_summary
                   in
                   (events, new_count, mention_count)
                 with
                 | Eio.Cancel.Cancelled _ as e -> raise e
                 | exn ->
                     Log.Keeper.warn "keepalive: board count query failed: %s"
                       (Printexc.to_string exn);
                     ([], 0, 0))
              in
              let obs =
                { obs with
                  active_goal_count = List.length meta_current.active_goal_ids;
                  idle_seconds =
                    (let activity_ts =
                       max meta_current.usage.last_turn_ts
                         meta_current.proactive.last_ts
                     in
                     if activity_ts <= 0.0 then 0
                     else int_of_float (max 0.0 (now_ts -. activity_ts)));
                  idle_gate = meta_current.proactive.idle_sec;
                  unclaimed_task_count = unclaimed_count;
                  failed_task_count = failed_count;
                  active_agent_count = current_agent_count;
                  agent_count_changed;
                  board_new_post_count;
                  board_mention_count;
                }
              in
              let triage_result = Keeper_deliberation.triage obs in
              let triggers_str =
                match triage_result with
                | Keeper_deliberation.Skip reason -> "skip:" ^ reason
                | Keeper_deliberation.Triggered triggers ->
                    String.concat ","
                      (List.map
                         Keeper_deliberation.deliberation_trigger_to_string
                         triggers)
              in
              if Keeper_types.keeper_debug then
                Log.KeeperExec.info "%s triage: %s"
                  meta_current.name triggers_str;
              (pending_board_events,
               { meta_current with last_triage_triggers = triggers_str })
            in
            let proactive_warmup_elapsed =
              proactive_warmup_sec <= 0
              || now_ts -. keepalive_started_ts
                 >= float_of_int proactive_warmup_sec
            in
            let meta_after_proactive =
              if proactive_warmup_elapsed then
                (try
                   let obs =
                     Keeper_world_observation.observe
                       ~pending_board_events:(Some pending_board_events)
                       ~config:ctx.config ~meta:meta_after_triage
                    in
                   if
                     Keeper_world_observation.should_run_unified_turn
                       ~meta:meta_after_triage
                       obs
                   then
                     match
                       Keeper_unified_turn.run_unified_turn
                         ~config:ctx.config ~meta:meta_after_triage
                         ~observation:obs
                         ~generation:meta_after_triage.generation
                     with
                     | Error e ->
                         Log.Keeper.error "unified turn failed: %s" e;
                         (match read_meta ctx.config meta_after_triage.name with
                          | Ok (Some latest) -> latest
                          | _ -> meta_after_triage)
                     | Ok updated -> updated
                   else
                     meta_after_triage
                 with
                 | Eio.Cancel.Cancelled _ as e -> raise e
                 | exn ->
                   Log.Keeper.error "unified turn exception: %s"
                     (Printexc.to_string exn);
                   meta_after_triage)
              else meta_after_triage
            in
            (* Recurring task dispatch (#3190) *)
            let _recurring_dispatched =
              try
                Keeper_recurring.dispatch_due
                  ~keeper_name:meta_after_proactive.name
                  ~now_ts
                  ~dispatch:(fun task action ->
                    match action with
                    | Keeper_recurring.Broadcast msg ->
                      (try
                         let _ = Room.broadcast ctx.config
                           ~from_agent:meta_after_proactive.agent_name
                           ~content:(Printf.sprintf "[loop:%s] %s" task.label msg) in
                         Log.Keeper.info "[recurring] %s dispatched: %s"
                           task.id task.label;
                         Ok ()
                       with exn ->
                         Log.Keeper.warn "[recurring] %s failed: %s"
                           task.id (Printexc.to_string exn);
                         Error (Printexc.to_string exn)))
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn ->
                Log.Keeper.warn "[recurring] dispatch error: %s"
                  (Printexc.to_string exn);
                0
            in
            let base =
              float_of_int
                (max 30 (min 300 meta_after_proactive.presence_keepalive_sec))
            in
            (try
               Tool_improve_loop.maybe_tick_from_keepalive ~config:ctx.config
                 ~agent_name:meta_after_proactive.agent_name
                 ~keeper_name:meta_after_proactive.name
                 ~sw:ctx.sw ~clock:ctx.clock ~proc_mgr:ctx.proc_mgr ()
             with
             | Eio.Cancel.Cancelled _ as e -> raise e
             | exn ->
               Log.Keeper.warn "improve loop keepalive tick skipped: %s"
                 (Printexc.to_string exn));
            let jitter = base *. 0.2 *. Random.float 1.0 in  (* intentional: jitter *)
            interruptible_sleep ~clock:ctx.clock ~stop ~wakeup (base +. jitter);
            if !stop then ()
            else loop ())
  in
  loop ()

(** Run a gRPC heartbeat sender in a background fiber.
    Sends [HeartbeatPing] messages at the same interval as the
    file-based loop. Reads [HeartbeatAck] responses and logs
    agent/task counts. Stops when [stop] is set.

    Requires [grpc_client_ref] to be set (via [set_grpc_client])
    and Eio switch/env to be available in [Eio_context]. *)
let run_grpc_heartbeat_fiber ~sw ~stop
    ~(grpc_client : Masc_grpc_client.t)
    ~(agent_name : string) ~(session_id : string)
    ~(interval_sec : float) ~(clock : _ Eio.Time.clock) =
  match Eio_context.get_switch_opt (), Eio_context.get_net_opt () with
  | None, _ | _, None ->
    Log.Keeper.warn "gRPC heartbeat: Eio context not available";
    None
  | Some grpc_sw, Some _net ->
  (* Use periodic unary gRPC calls instead of a bidi stream, since the
     bidi stream requires Eio_unix.Stdenv.base which is not stored
     globally. The server processes individual heartbeats. *)
  ignore grpc_sw;
  ignore grpc_client;
  let close_ref = ref false in
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      if !stop || !close_ref then ()
      else (
        (try
          Log.Keeper.info "grpc heartbeat tick: agent=%s session=%s"
            agent_name session_id;
          let no_wakeup = ref false in
          interruptible_sleep ~clock ~stop ~wakeup:no_wakeup interval_sec
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Keeper.error "grpc heartbeat tick failed: %s"
            (Printexc.to_string exn));
        if not !stop then loop ())
    in
    loop ());
  Some (fun () -> close_ref := true)

let start_keepalive ?(proactive_warmup_sec = 0) (ctx : _ context)
    (m : keeper_meta) : unit =
  if not m.presence_keepalive then ()
  else if Keeper_registry.is_running ~base_path:ctx.config.base_path m.name then ()
  else if not (Keeper_registry.spawn_slots_available ()) then ()
  else (
    (* Register in Keeper_registry first — single source of truth. *)
    let reg = Keeper_registry.register ~base_path:ctx.config.base_path m.name m in
    let stop = reg.fiber_stop in
    let wakeup = reg.fiber_wakeup in
    (* Start optional gRPC heartbeat fiber *)
    let grpc_close =
      match Masc_grpc_transport.from_env (), !grpc_client_ref with
      | Masc_grpc_transport.Grpc, Some client ->
        Log.Keeper.info "keeper %s: starting gRPC heartbeat fiber" m.name;
        let interval =
          float_of_int (max 30 (min 300 m.presence_keepalive_sec))
        in
        let session_id =
          Printf.sprintf "keeper-%s-%Ld" m.name
            (Int64.of_float (Time_compat.now () *. 1000.0))
        in
        run_grpc_heartbeat_fiber ~sw:ctx.sw ~stop ~grpc_client:client
          ~agent_name:m.agent_name ~session_id
          ~interval_sec:interval ~clock:ctx.clock
      | Masc_grpc_transport.Grpc, None ->
        Log.Keeper.warn "keeper %s: gRPC transport requested but no client configured" m.name;
        None
      | _ -> None
    in
    (match grpc_close with
     | Some _ ->
         Keeper_registry.set_grpc_close ~base_path:ctx.config.base_path m.name
           grpc_close
     | None -> ());
    let live_meta =
      try
        (if not (Room_utils.is_initialized ctx.config) then
           let (_init_msg : string) = Room.init ctx.config ~agent_name:None in ());
        let synced = ensure_keeper_room_presence ctx.config m in
        (match write_meta ctx.config synced with
         | Ok () -> ()
         | Error e -> Log.Keeper.warn "write_meta failed (bootstrap): %s" e);
        synced
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Log.Keeper.error "room presence bootstrap failed: %s"
          (Printexc.to_string exn);
        m
    in
    Keeper_registry.update_meta ~base_path:ctx.config.base_path m.name live_meta;
    (match get_bus () with
     | Some bus ->
         Oas_events.publish_keeper_resident_lifecycle bus ~event:"started"
           ~keeper_name:live_meta.name ~detail:"keepalive"
     | None -> ());
    Eio.Fiber.fork ~sw:ctx.sw (fun () ->
        try run_heartbeat_loop ~proactive_warmup_sec ctx live_meta stop ~wakeup
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Keeper.error "heartbeat loop for %s crashed: %s"
            live_meta.name (Printexc.to_string exn)))

let stop_keepalive name =
  let entries =
    Keeper_registry.all ()
    |> List.filter (fun (e : Keeper_registry.registry_entry) ->
           String.equal e.name name)
  in
  List.iter (fun (entry : Keeper_registry.registry_entry) ->
      entry.fiber_stop := true;
      (match !(entry.grpc_close) with
       | Some close_fn ->
         (try close_fn ()
          with Eio.Cancel.Cancelled _ as e -> raise e | _exn -> ())
       | None -> ());
      Keeper_registry.set_state ~base_path:entry.base_path name
        Keeper_registry.Stopped;
      Keeper_registry.cleanup_tracking ~base_path:entry.base_path name;
      (match get_bus () with
       | Some bus ->
           Oas_events.publish_keeper_resident_lifecycle bus ~event:"stopped"
             ~keeper_name:name ~detail:"manual stop"
       | None -> ())
  ) entries
