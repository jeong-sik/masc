(** Keeper_keepalive — keeper heartbeat fiber and board-reactive wakeup.

    Per-keeper lifecycle (start, stop, wakeup) is managed through
    [Keeper_registry] (SSOT).  This module provides the heartbeat loop
    body, board-reactive wakeup filtering, and optional gRPC heartbeat
    fiber. *)

open Keeper_types
open Keeper_memory
open Keeper_execution

let keepalive_interval_sec = Env_config.KeeperKeepalive.interval_sec

(* ── Board-reactive policy constants ── *)

let board_reactive_debounce_sec = Env_config.KeeperKeepalive.board_debounce_sec

(* OAS Event_bus ref — set via bootstrap *)
let bus_ref : Agent_sdk.Event_bus.t option ref = ref None
let set_bus bus = bus_ref := Some bus
let get_bus () = !bus_ref

(** Optional gRPC client + env — set at server bootstrap when
    [MASC_AGENT_TRANSPORT=grpc]. When set, heartbeat sends
    status pings over gRPC unary RPC. *)
let grpc_client_ref : Masc_grpc_client.t option ref = ref None
let grpc_env_ref : Eio_unix.Stdenv.base option ref = ref None
let set_grpc_client ?(env : Eio_unix.Stdenv.base option) c =
  grpc_client_ref := Some c;
  grpc_env_ref := env

(** Sleep in short chunks so [stop_keepalive] or [wakeup_keeper] takes
    effect within ~chunk_sec instead of waiting for the full interval. *)
let interruptible_sleep ~clock ~stop ~wakeup duration =
  let chunk_sec = Env_config.KeeperKeepalive.sleep_chunk_sec in
  let rec wait remaining =
    if Atomic.get stop then ()
    else if Atomic.compare_and_set wakeup true false then ()
    else if remaining <= 0.0 then ()
    else begin
      let chunk = Float.min chunk_sec remaining in
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
  | [] -> ()

let max_consecutive_heartbeat_failures =
  Env_config.KeeperKeepalive.max_consecutive_failures

let max_consecutive_turn_failures =
  Env_config.KeeperKeepalive.max_consecutive_turn_failures

(* Per-stage timing accumulator for Phase 0 profiling.
   In-memory ring of last 100 cycles. Flushed as aggregate at snapshot cadence.
   No additional file I/O — appended to existing snapshot JSON. *)
type stage_timing = {
  presence_ms : float;
  snapshot_ms : float;
  board_ms : float;
  turn_ms : float;
  recurring_ms : float;
  improve_ms : float;
}

let stage_timing_ring_size = Env_config.KeeperProactive.stage_timing_ring_size

let percentile arr p =
  let n = Array.length arr in
  if n = 0 then 0.0
  else
    let sorted = Array.copy arr in
    Array.sort Float.compare sorted;
    let idx = Float.to_int (Float.round (float_of_int (n - 1) *. p)) in
    sorted.(min idx (n - 1))

let stage_timing_to_json ~ring ~count =
  let n = min count stage_timing_ring_size in
  if n = 0 then `Null
  else
    let extract field =
      let arr = Array.init n (fun i -> field ring.(i)) in
      `Assoc [
        ("p50", `Float (percentile arr 0.5));
        ("p95", `Float (percentile arr 0.95));
        ("max", `Float (percentile arr 1.0));
        ("samples", `Int n);
      ]
    in
    `Assoc [
      ("presence", extract (fun t -> t.presence_ms));
      ("snapshot", extract (fun t -> t.snapshot_ms));
      ("board", extract (fun t -> t.board_ms));
      ("turn", extract (fun t -> t.turn_ms));
      ("recurring", extract (fun t -> t.recurring_ms));
      ("improve", extract (fun t -> t.improve_ms));
    ]

let run_heartbeat_loop ~proactive_warmup_sec (ctx : _ context)
    (m : keeper_meta) (stop : bool Atomic.t) ~(wakeup : bool Atomic.t) : unit =
  let keepalive_started_ts = Time_compat.now () in
  let snapshot_interval_sec = Env_config.KeeperRuntime.snapshot_sec in
  let last_snapshot_ts = ref 0.0 in
  let consecutive_failures = ref 0 in
  (* Phase 0: per-stage timing ring buffer *)
  let timing_ring = Array.make stage_timing_ring_size
    { presence_ms = 0.0; snapshot_ms = 0.0; board_ms = 0.0;
      turn_ms = 0.0; recurring_ms = 0.0; improve_ms = 0.0 } in
  let timing_cursor = ref 0 in
  let timing_filled = ref 0 in
  (* Phase 1: work-as-heartbeat freshness tracking.
     Updated ONLY on Room.heartbeat_in_room success after turn. *)
  let last_successful_heartbeat_ts = ref 0.0 in
  let work_as_hb = Env_config.WorkAsHeartbeat.enabled in
  let max_silence = Env_config.WorkAsHeartbeat.max_silence_sec in
  (* Phase 2: smart heartbeat — adaptive scheduling via Heartbeat_smart *)
  let smart_hb_enabled = Env_config.SmartHeartbeat.enabled in
  let smart_hb_config = Heartbeat_smart.default_config in
  let last_heartbeat_cycle_ts = ref 0.0 in
  let rec loop () =
    if Atomic.get stop then ()
    else (
            (* Phase 0: timing markers *)
            let t_presence_start = Time_compat.now () in
            let meta_current =
              match read_meta ctx.config m.name with
              | Ok (Some latest) -> latest
              | _ -> m
            in
            (* Phase 2: smart heartbeat — skip cycle when busy or deeply idle *)
            let smart_hb_decision =
              if smart_hb_enabled then
                let agent_status =
                  if meta_current.paused then Types.Inactive
                  else match meta_current.current_task_id with
                    | Some _ -> Types.Busy
                    | None -> Types.Active
                in
                Heartbeat_smart.should_emit
                  ~config:smart_hb_config
                  ~agent_status
                  ~last_activity:!last_successful_heartbeat_ts
                  ~last_heartbeat:!last_heartbeat_cycle_ts
              else
                Heartbeat_smart.Emit
            in
            (match smart_hb_decision with
             | Heartbeat_smart.Skip_busy ->
               Log.Keeper.debug "smart heartbeat: skip (busy, task=%s)"
                 (Option.value ~default:"?" meta_current.current_task_id);
               let base = Heartbeat_smart.effective_interval
                 ~config:smart_hb_config
                 ~last_activity:!last_successful_heartbeat_ts in
               let jitter = base *. 0.2 *. Random.float 1.0 in
               interruptible_sleep ~clock:ctx.clock ~stop ~wakeup (base +. jitter);
               if Atomic.get stop then () else loop ()
             | Heartbeat_smart.Skip_idle next_time ->
               let wait = Float.max 1.0 (next_time -. Time_compat.now ()) in
               Log.Keeper.debug "smart heartbeat: skip (idle, next in %.1fs)" wait;
               let jitter = wait *. 0.1 *. Random.float 1.0 in
               interruptible_sleep ~clock:ctx.clock ~stop ~wakeup (wait +. jitter);
               if Atomic.get stop then () else loop ()
             | Heartbeat_smart.Emit ->
               last_heartbeat_cycle_ts := Time_compat.now ());
            (* Phase 1: skip presence sync when recent room heartbeat proves freshness *)
            let presence_fresh =
              work_as_hb
              && t_presence_start -. !last_successful_heartbeat_ts < max_silence
            in
            let meta_current =
              if presence_fresh then (
                Log.Keeper.debug "presence sync skipped: fresh heartbeat %.0fs ago"
                  (t_presence_start -. !last_successful_heartbeat_ts);
                meta_current)
              else
                try
                  let synced = ensure_keeper_room_presence ctx.config meta_current in
                  if synced.joined_room_ids = [] then (
                    incr consecutive_failures;
                    Log.Keeper.warn "room presence returned empty rooms (%d/%d)"
                      !consecutive_failures max_consecutive_heartbeat_failures)
                  else (
                    consecutive_failures := 0;
                    last_successful_heartbeat_ts := Time_compat.now ());
                  (match write_meta ctx.config synced with
                   | Ok () -> synced
                   | Error e ->
                     Log.Keeper.warn "write_meta failed (heartbeat): %s" e;
                     synced)
                with
                | Eio.Cancel.Cancelled _ as e -> raise e
                | exn ->
                  incr consecutive_failures;
                  Log.Keeper.error "room heartbeat failed (%d/%d): %s"
                    !consecutive_failures max_consecutive_heartbeat_failures
                    (Printexc.to_string exn);
                  meta_current
            in
            (* Phase 2: structured exception instead of silent stop *)
            if !consecutive_failures >= max_consecutive_heartbeat_failures then
              raise (Keeper_registry.Keeper_heartbeat_failure {
                reason = Keeper_registry.Heartbeat_consecutive_failures !consecutive_failures;
                keeper_name = m.name;
              });
            let t_presence_end = Time_compat.now () in
            let now_ts = t_presence_end in
            let t_snapshot_start = now_ts in
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
                 ignore (Keeper_fs.ensure_dir (Filename.concat base_dir meta_current.trace_id));
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
                           ("stage_timing",
                             stage_timing_to_json ~ring:timing_ring ~count:!timing_filled);
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
                      | None -> ());
                     (* Flush tool usage stats to disk for persistence *)
                     (try
                        Keeper_registry.flush_tool_usage
                          ~base_path:ctx.config.base_path
                          meta_current.name
                      with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ()))
               with
               | Eio.Cancel.Cancelled _ as e -> raise e
               | exn ->
                 Log.Keeper.error "heartbeat snapshot write failed: %s"
                   (Printexc.to_string exn));
              last_snapshot_ts := now_ts);
            let t_snapshot_end = Time_compat.now () in
            let t_board_start = t_snapshot_end in
            let pending_board_events, meta_after_triage =
              let pending_board_events =
                (try
                   let events, _new_count, _mention_count =
                     Keeper_world_observation.collect_board_events
                       ~base_path:ctx.config.base_path
                       ~meta:meta_current
                       ~continuity_summary:meta_current.continuity_summary
                   in
                   events
                 with
                 | Eio.Cancel.Cancelled _ as e -> raise e
                 | exn ->
                     Log.Keeper.warn "keepalive: board count query failed: %s"
                       (Printexc.to_string exn);
                     [])
              in
              (pending_board_events, meta_current)
            in
            let t_board_end = Time_compat.now () in
            let t_turn_start = t_board_end in
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
            (* Turn failure threshold: registry tracks count (via unified_turn),
               keepalive raises to terminate the fiber for supervisor restart. *)
            let turn_fail_count =
              Keeper_registry.get_turn_failures
                ~base_path:ctx.config.base_path m.name in
            if turn_fail_count >= max_consecutive_turn_failures then
              raise (Keeper_registry.Keeper_heartbeat_failure {
                reason = Keeper_registry.Turn_consecutive_failures turn_fail_count;
                keeper_name = m.name;
              });
            (* Phase 1: work-as-heartbeat — renew point (b).
               After turn, call Room.heartbeat_in_room to prove room I/O health.
               On success: refresh freshness lease + reset consecutive_failures.
               On failure: leave timestamp unchanged → presence sync resumes next cycle. *)
            (if work_as_hb && proactive_warmup_elapsed then
               let hb_ok = List.exists (fun room_id ->
                 try
                   ignore
                     (Room.heartbeat_in_room ctx.config ~room_id
                        ~agent_name:meta_after_proactive.agent_name);
                   true
                 with
                 | Eio.Cancel.Cancelled _ as e -> raise e
                 | exn ->
                     Log.Keeper.debug "heartbeat_in_room failed for %s: %s"
                       meta_after_proactive.name (Printexc.to_string exn);
                     false
               ) meta_after_proactive.joined_room_ids in
               if hb_ok then (
                 last_successful_heartbeat_ts := Time_compat.now ();
                 consecutive_failures := 0));
            let t_turn_end = Time_compat.now () in
            let t_recurring_start = t_turn_end in
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
            let t_recurring_end = Time_compat.now () in
            let t_improve_start = t_recurring_end in
            let base =
              if smart_hb_enabled then
                Heartbeat_smart.effective_interval
                  ~config:smart_hb_config
                  ~last_activity:!last_successful_heartbeat_ts
              else
                float_of_int keepalive_interval_sec
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
            let t_improve_end = Time_compat.now () in
            (* Phase 0: push stage timing to ring buffer *)
            let timing = {
              presence_ms = (t_presence_end -. t_presence_start) *. 1000.0;
              snapshot_ms = (t_snapshot_end -. t_snapshot_start) *. 1000.0;
              board_ms = (t_board_end -. t_board_start) *. 1000.0;
              turn_ms = (t_turn_end -. t_turn_start) *. 1000.0;
              recurring_ms = (t_recurring_end -. t_recurring_start) *. 1000.0;
              improve_ms = (t_improve_end -. t_improve_start) *. 1000.0;
            } in
            timing_ring.(!timing_cursor) <- timing;
            timing_cursor := (!timing_cursor + 1) mod stage_timing_ring_size;
            if !timing_filled < stage_timing_ring_size then incr timing_filled;
            let jitter = base *. Env_config.KeeperKeepalive.jitter_factor *. Random.float 1.0 in
            interruptible_sleep ~clock:ctx.clock ~stop ~wakeup (base +. jitter);
            if Atomic.get stop then ()
            else loop ())
  in
  loop ()

(** Process a single directive received from a gRPC HeartbeatAck.
    Directives are string commands: "pause", "resume", "wakeup",
    "claim:<task_id>". Unknown directives are logged and ignored. *)
let process_directive ~agent_name directive =
  match directive with
  | "pause" ->
    Log.Keeper.info "directive: pausing keeper %s" agent_name;
    (match Keeper_registry.find_by_agent_name agent_name with
     | Some entry ->
       Keeper_registry.update_meta ~base_path:entry.base_path entry.name
         { entry.meta with paused = true }
     | None ->
       Log.Keeper.warn "directive pause: agent %s not in registry" agent_name)
  | "resume" ->
    Log.Keeper.info "directive: resuming keeper %s" agent_name;
    (match Keeper_registry.find_by_agent_name agent_name with
     | Some entry ->
       Keeper_registry.update_meta ~base_path:entry.base_path entry.name
         { entry.meta with paused = false }
     | None ->
       Log.Keeper.warn "directive resume: agent %s not in registry" agent_name)
  | "wakeup" ->
    Log.Keeper.debug "directive: waking up %s" agent_name;
    (match Keeper_registry.find_by_agent_name agent_name with
     | Some entry -> wakeup_keeper entry.name
     | None ->
       Log.Keeper.warn "directive wakeup: agent %s not in registry" agent_name)
  | s when String.length s > 6 && String.sub s 0 6 = "claim:" ->
    let task_id = String.sub s 6 (String.length s - 6) in
    Log.Keeper.info "directive: server assigned task %s to %s" task_id agent_name;
    (match Keeper_registry.find_by_agent_name agent_name with
     | Some entry ->
       Keeper_registry.update_meta ~base_path:entry.base_path entry.name
         { entry.meta with current_task_id = Some task_id };
       wakeup_keeper entry.name
     | None ->
       Log.Keeper.warn "directive claim: agent %s not in registry" agent_name)
  | unknown ->
    Log.Keeper.warn "unknown gRPC directive for %s: %s" agent_name unknown

(** Run a gRPC heartbeat sender in a background fiber.
    Opens a bidirectional [Heartbeat] stream and sends [HeartbeatPing]
    messages at the configured interval. Reads [HeartbeatAck] responses,
    logs agent/task counts, and dispatches directives. Reconnects on
    stream failure up to 5 times. Stops when [stop] is set.

    Requires [grpc_client_ref] to be set (via [set_grpc_client])
    and Eio switch/env to be available in [Eio_context]. *)
let max_reconnect_attempts = Env_config.KeeperGrpc.max_reconnect_attempts
let reconnect_backoff_sec = Env_config.KeeperGrpc.reconnect_backoff_sec

let run_grpc_heartbeat_fiber ~sw ~stop
    ~(grpc_client : Masc_grpc_client.t)
    ~(agent_name : string) ~(session_id : string)
    ~(interval_sec : float) ~(clock : _ Eio.Time.clock) =
  match Eio_context.get_switch_opt (), !grpc_env_ref with
  | None, _ | _, None ->
    Log.Keeper.warn "gRPC heartbeat: Eio context or env not available";
    None
  | Some grpc_sw, Some env ->
  let close_ref = ref false in
  Eio.Fiber.fork ~sw (fun () ->
    let make_ping () =
      let current_task_id =
        match Keeper_registry.find_by_agent_name agent_name with
        | Some e -> Option.value ~default:"" e.meta.current_task_id
        | None -> ""
      in
      Masc_grpc_types.HeartbeatPing.{
        agent_name;
        session_id;
        timestamp_ms = Int64.of_float (Time_compat.now () *. 1000.0);
        current_task_id;
      }
    in
    (* Inner loop: send ping → recv ack → sleep → repeat on one stream *)
    let run_stream send recv =
      let rec tick () =
        if Atomic.get stop || !close_ref then ()
        else (
          (try
            send (make_ping ());
            (match recv () with
             | Ok (ack : Masc_grpc_types.HeartbeatAck.t) ->
               Log.Keeper.debug
                 "gRPC bidi heartbeat: agent=%s agents=%d tasks=%d directives=%d"
                 agent_name ack.active_agent_count ack.pending_task_count
                 (List.length ack.directives);
               List.iter (process_directive ~agent_name) ack.directives
             | Error err ->
               Log.Keeper.warn "gRPC heartbeat recv: %s" err)
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | End_of_file -> raise End_of_file
          | exn ->
            Log.Keeper.error "gRPC heartbeat tick error: %s"
              (Printexc.to_string exn));
          if not (Atomic.get stop || !close_ref) then (
            let no_wakeup = Atomic.make false in
            interruptible_sleep ~clock ~stop ~wakeup:no_wakeup interval_sec;
            tick ()))
      in
      tick ()
    in
    (* Outer loop: reconnect on stream failure *)
    let rec connect_loop attempts =
      if Atomic.get stop || !close_ref then ()
      else if attempts >= max_reconnect_attempts then
        Log.Keeper.error
          "gRPC heartbeat: exceeded %d reconnect attempts for %s, stopping"
          max_reconnect_attempts agent_name
      else (
        let send, recv, close_stream =
          Masc_grpc_client.heartbeat_stream grpc_client ~sw:grpc_sw ~env
        in
        (try run_stream send recv
         with
         | Eio.Cancel.Cancelled _ as e -> close_stream (); raise e
         | End_of_file ->
           Log.Keeper.warn
             "gRPC heartbeat stream closed for %s (attempt %d/%d)"
             agent_name (attempts + 1) max_reconnect_attempts;
           close_stream ()
         | exn ->
           Log.Keeper.warn
             "gRPC heartbeat stream error for %s: %s (attempt %d/%d)"
             agent_name (Printexc.to_string exn)
             (attempts + 1) max_reconnect_attempts;
           close_stream ());
        if not (Atomic.get stop || !close_ref) then (
          Eio.Time.sleep clock reconnect_backoff_sec;
          connect_loop (attempts + 1)))
    in
    connect_loop 0);
  Some (fun () -> close_ref := true)

let start_keepalive ?(proactive_warmup_sec = 0) (ctx : _ context)
    (m : keeper_meta) : unit =
  if Keeper_registry.is_running ~base_path:ctx.config.base_path m.name then
    Log.Keeper.info "start_keepalive: skipped %s (already running)" m.name
  else if not (Keeper_registry.spawn_slots_available ()) then
    Log.Keeper.info "start_keepalive: skipped %s (no spawn slots)" m.name
  else (
    (* Register in Keeper_registry first — single source of truth. *)
    let reg = Keeper_registry.register ~base_path:ctx.config.base_path m.name m in
    (* Restore persisted tool usage stats from previous session *)
    Keeper_registry.restore_tool_usage ~base_path:ctx.config.base_path m.name;
    let stop = reg.fiber_stop in
    let wakeup = reg.fiber_wakeup in
    (* Start optional gRPC heartbeat fiber *)
    let grpc_close =
      match Masc_grpc_transport.from_env (), !grpc_client_ref with
      | Masc_grpc_transport.Grpc, Some client ->
        Log.Keeper.info "keeper %s: starting gRPC heartbeat fiber" m.name;
        let interval = float_of_int keepalive_interval_sec in
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
         Oas_events.publish_keeper_lifecycle bus ~event:"started"
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
      Atomic.set entry.fiber_stop true;
      (match Atomic.get entry.grpc_close with
       | Some close_fn ->
         (try close_fn ()
          with Eio.Cancel.Cancelled _ as e -> raise e | _exn -> ())
       | None -> ());
      Keeper_registry.set_state ~base_path:entry.base_path name
        Keeper_registry.Stopped;
      Keeper_registry.cleanup_tracking ~base_path:entry.base_path name;
      (match get_bus () with
       | Some bus ->
           Oas_events.publish_keeper_lifecycle bus ~event:"stopped"
             ~keeper_name:name ~detail:"manual stop"
       | None -> ())
  ) entries
