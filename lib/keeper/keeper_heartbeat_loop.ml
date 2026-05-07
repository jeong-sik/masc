(* keeper_heartbeat_loop — the main heartbeat loop body and its helpers:
   presence sync, board event collection, in-turn liveness pulse,
   unified turn dispatch, smart heartbeat gate, stage timing recording,
   and [run_heartbeat_loop].

   Extracted from keeper_keepalive.ml. *)

open Keeper_types
open Keeper_memory
open Keeper_execution
open Keeper_keepalive_signal

let effective_keepalive_meta
    ~base_path
    ~(fallback : keeper_meta)
    ~(disk_meta_opt : keeper_meta option) : keeper_meta =
  match disk_meta_opt with
  | Some latest -> latest
  | None -> (
      match Keeper_registry.get ~base_path fallback.name with
      | Some entry -> entry.meta
      | None -> fallback)

let repair_identity_drift_for_keepalive ~(ctx : _ context) (meta : keeper_meta) :
    keeper_meta option =
  let expected_agent_name = keeper_agent_name meta.name in
  if String.equal expected_agent_name meta.agent_name then
    Some meta
  else
    let previous_trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
    let new_trace_id_raw = Keeper_identity.generate_trace_id () in
    match Keeper_id.Trace_id.of_string new_trace_id_raw with
    | Error err ->
        Log.Keeper.error
          "keepalive identity repair failed for %s: invalid trace_id %s (%s)"
          meta.name new_trace_id_raw err;
        Prometheus.inc_counter
          Prometheus.metric_keeper_heartbeat_failures
          ~labels:[("keeper", meta.name); ("phase", "identity_repair")]
          ();
        None
    | Ok new_trace_id ->
        let base_dir = session_base_dir ctx.config in
        let _session =
          Keeper_exec_context.create_session ~session_id:new_trace_id_raw
            ~base_dir
        in
        let repaired =
          {
            meta with
            agent_name = expected_agent_name;
            updated_at = now_iso ();
            runtime =
              {
                meta.runtime with
                trace_id = new_trace_id;
                trace_history =
                  Json_util.dedupe_keep_order
                    (previous_trace_id :: meta.runtime.trace_history);
                generation = meta.runtime.generation + 1;
              };
          }
        in
        (match write_meta ~force:true ctx.config repaired with
         | Ok () ->
             Log.Keeper.warn
               "keepalive repaired identity drift for %s: %s -> %s"
               meta.name meta.agent_name expected_agent_name;
             Some repaired
         | Error err ->
             Prometheus.inc_counter
               Prometheus.metric_keeper_write_meta_failures
               ~labels:[ ("keeper", meta.name); ("phase", "identity_repair") ]
               ();
             Log.Keeper.error
               "keepalive identity repair failed for %s: write_meta failed: %s"
               meta.name err;
             None)

let keeper_agent_status (meta : keeper_meta) =
  if meta.paused
  then Masc_domain.Inactive
  else (
    match meta.current_task_id with
    | Some _ -> Masc_domain.Busy
    | None -> Masc_domain.Active)
;;

(** Reset stale turn failures so the keeper can exit Failing phase.
    Called unconditionally after presence sync (whether I/O was skipped or not).
    If the underlying issue persists, the next turn will re-fail.
    Manual reconcile blocker logic removed — see plan:
    enchanted-strolling-bonbon. *)
let maybe_recover_from_failing ~(ctx : _ context) ~(meta : keeper_meta) =
  let stale_turn_failures =
    Keeper_registry.get_turn_failures
      ~base_path:ctx.config.base_path meta.name
  in
  if stale_turn_failures > 0 then begin
    Keeper_registry.reset_turn_failures
      ~base_path:ctx.config.base_path meta.name;
    Keeper_registry.dispatch_event_unit
      ~base_path:ctx.config.base_path meta.name
      Keeper_state_machine.Heartbeat_ok;
    Keeper_keepalive_signal.dispatch_keepalive_event ~ctx ~keeper_name:meta.name
      Keeper_state_machine.Turn_succeeded;
    Log.Keeper.info
      "heartbeat recovery: reset %d stale turn failures for %s"
      stale_turn_failures meta.name
  end

let sync_keeper_presence
      ~(ctx : _ context)
      ~(meta_current : keeper_meta)
      ~(t_presence_start : float)
      ~(consecutive_failures : int ref)
      ~(last_successful_heartbeat_ts : float ref)
      ~(work_as_hb : unit -> bool)
      ~(max_silence : unit -> float)
  : keeper_meta
  =
  let presence_fresh =
    work_as_hb () && t_presence_start -. !last_successful_heartbeat_ts < max_silence ()
  in
  if presence_fresh
  then (
    Log.Keeper.debug
      "presence sync skipped: fresh heartbeat %.0fs ago"
      (t_presence_start -. !last_successful_heartbeat_ts);
    maybe_recover_from_failing ~ctx ~meta:meta_current;
    meta_current)
  else (
    try
      let synced = ensure_keeper_room_presence ctx.config meta_current in
      if synced.joined_room_ids = []
      then (
        incr consecutive_failures;
        (* RFC-0001 Gate A: record failure streak *)
        Agent_stress.record {
          agent_name = meta_current.name;
          room_id = (match meta_current.joined_room_ids with r :: _ -> r | [] -> "");
          kind = Failure_streak !consecutive_failures;
          timestamp = Unix.gettimeofday ();
        };
        Log.Keeper.warn
          "room presence returned empty rooms (%d/%d)"
          !consecutive_failures
          (Keeper_heartbeat_snapshot.max_consecutive_heartbeat_failures ());
        (* RFC-0002: dispatch heartbeat failure *)
        Prometheus.inc_counter Prometheus.metric_keeper_heartbeat_failures
          ~labels:[("keeper", meta_current.name)] ();
        Keeper_registry.dispatch_event_unit
          ~base_path:ctx.config.base_path meta_current.name
          (Keeper_state_machine.Heartbeat_failed {
            consecutive = !consecutive_failures;
            max_allowed = Keeper_heartbeat_snapshot.max_consecutive_heartbeat_failures ();
          }))
      else (
        consecutive_failures := 0;
        last_successful_heartbeat_ts := Time_compat.now ();
        (* RFC-0002: dispatch heartbeat success *)
        Keeper_registry.dispatch_event_unit
          ~base_path:ctx.config.base_path meta_current.name
          Keeper_state_machine.Heartbeat_ok;
        Prometheus.inc_counter Prometheus.metric_keeper_heartbeat_successes
          ~labels:[("keeper", meta_current.name)] ();
        maybe_recover_from_failing ~ctx ~meta:meta_current);
      match write_meta ctx.config synced with
      | Ok () -> synced
      | Error e ->
        Prometheus.inc_counter Prometheus.metric_keeper_write_meta_failures
          ~labels:[("keeper", synced.name); ("phase", "heartbeat")] ();
        Log.Keeper.warn "write_meta failed (heartbeat): %s" e;
        synced
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      incr consecutive_failures;
      Prometheus.inc_counter
        Prometheus.metric_keeper_room_heartbeat_failures
        ~labels:[("keeper", meta_current.name)]
        ();
      Log.Keeper.error
        "room heartbeat failed (%d/%d): %s"
        !consecutive_failures
        (Keeper_heartbeat_snapshot.max_consecutive_heartbeat_failures ())
        (Printexc.to_string exn);
      (* RFC-0002: dispatch heartbeat failure *)
      Keeper_registry.dispatch_event_unit
        ~base_path:ctx.config.base_path meta_current.name
        (Keeper_state_machine.Heartbeat_failed {
          consecutive = !consecutive_failures;
          max_allowed = Keeper_heartbeat_snapshot.max_consecutive_heartbeat_failures ();
        });
      meta_current)
;;

let collect_keepalive_board_events
      ~(ctx : _ context)
      ~(meta_current : keeper_meta)
      ~(proactive_warmup_elapsed : bool)
  =
  if not proactive_warmup_elapsed
  then [], meta_current
  else (
    let pending_board_events =
      try
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
        Log.Keeper.warn "keepalive: board count query failed: %s" (Printexc.to_string exn);
        Prometheus.inc_counter
          Prometheus.metric_keeper_heartbeat_failures
          ~labels:[("keeper", meta_current.name); ("phase", "board_count_query")]
          ();
        []
    in
    pending_board_events, meta_current)
;;

let in_turn_liveness_pulse_interval_sec () =
  max 5.0 (min 30.0 (float_of_int (Keeper_heartbeat_snapshot.keepalive_interval_sec ())))
;;

let with_in_turn_liveness_pulse_for_test ~sw:_sw ~clock ~interval_sec ~tick f =
  let interval_sec = max 0.001 interval_sec in
  Eio.Switch.run (fun pulse_sw ->
    let pulse_stop = Atomic.make false in
    Eio.Switch.on_release pulse_sw (fun () -> Atomic.set pulse_stop true);
    Eio.Fiber.fork ~sw:pulse_sw (fun () ->
      let rec loop () =
        Eio.Time.sleep clock interval_sec;
        if not (Atomic.get pulse_stop) then (
          (try tick ()
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
               Log.Keeper.warn "in-turn liveness pulse failed: %s"
                 (Printexc.to_string exn);
               Prometheus.inc_counter
                 Prometheus.metric_keeper_heartbeat_failures
                 ~labels:[("keeper", "liveness_pulse"); ("phase", "pulse_tick")]
                 ());
          loop ())
      in
      loop ());
    f ())
;;

let emit_in_turn_liveness_pulse ~(ctx : _ context) ~(meta : keeper_meta) =
  match Keeper_registry.get ~base_path:ctx.config.base_path meta.name with
  | Some entry when Option.is_some entry.current_turn_observation ->
      (try
         ignore (Coord.heartbeat ctx.config ~agent_name:meta.agent_name)
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
           Log.Keeper.warn "in-turn heartbeat failed for %s: %s"
             meta.name (Printexc.to_string exn);
           Prometheus.inc_counter
             Prometheus.metric_keeper_heartbeat_failures
             ~labels:[("keeper", meta.name); ("phase", "in_turn_heartbeat")]
             ());
      let now_ts = Time_compat.now () in
      (try
         let json =
           `Assoc
             [ "type", `String "keeper_heartbeat"
             ; "name", `String meta.name
             ; "generation", `Int meta.runtime.generation
             ; "ts_unix", `Float now_ts
             ; "phase", `String "turn_running"
             ; "in_turn", `Bool true
             ]
         in
         Sse.broadcast json;
         Sse.broadcast_presence json
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
           Prometheus.inc_counter
             Prometheus.metric_keeper_sse_broadcast_failures
             ~labels:[("keeper", meta.name)]
             ();
           Log.Keeper.error "in-turn heartbeat SSE broadcast failed: %s"
             (Printexc.to_string exn))
  | _ -> ()
;;

let with_in_turn_liveness_pulse
      ~(ctx : _ context)
      ~(meta : keeper_meta)
      ~(stop : bool Atomic.t)
      f
  =
  with_in_turn_liveness_pulse_for_test
    ~sw:ctx.sw
    ~clock:ctx.clock
    ~interval_sec:(in_turn_liveness_pulse_interval_sec ())
    ~tick:(fun () ->
      if not (Atomic.get stop) then emit_in_turn_liveness_pulse ~ctx ~meta)
    f
;;

type semaphore_wait_observation_kind =
  | Semaphore_wait_pending
  | Semaphore_wait_timeout

let semaphore_wait_observation_reasons ?phase_label ~kind ~channel () =
  let kind_reason =
    match kind with
    | Semaphore_wait_pending -> "semaphore_wait_pending"
    | Semaphore_wait_timeout -> "semaphore_wait_timeout"
  in
  let wait_reason =
    match phase_label with
    | Some phase -> "phase_" ^ phase
    | None -> "peers_holding_slot"
  in
  [
    kind_reason;
    wait_reason;
    "channel_" ^ Keeper_world_observation.channel_to_string channel;
  ]

let record_semaphore_wait_observation
    ?phase_label
    ~base_path
    ~keeper_name
    ~channel
    ~kind
    () =
  Keeper_registry.record_skip_reasons
    ~base_path
    keeper_name
    ~reasons:
      (semaphore_wait_observation_reasons ?phase_label ~kind ~channel ())

let oas_timeout_budget_observation_reasons =
  [
    "provider_runtime_error";
    "oas_timeout_budget";
    "keeper_turn_retry_backoff";
  ]

let record_oas_timeout_budget_observation ~base_path ~keeper_name =
  Keeper_registry.record_skip_reasons
    ~base_path
    keeper_name
    ~reasons:oas_timeout_budget_observation_reasons;
  Keeper_registry.touch_last_turn_ts ~base_path keeper_name

let clear_oas_timeout_budget_failure_reason ~base_path ~keeper_name =
  match Keeper_registry.get ~base_path keeper_name with
  | Some { Keeper_registry.last_failure_reason =
             Some (Keeper_registry.Oas_timeout_budget_loop _); _ } ->
      Keeper_registry.set_failure_reason ~base_path keeper_name None
  | _ -> ()

let prior_oas_timeout_budget_strikes ~base_path ~keeper_name =
  match Keeper_registry.get ~base_path keeper_name with
  | Some { Keeper_registry.last_failure_reason =
             Some (Keeper_registry.Oas_timeout_budget_loop { count }); _ } ->
      count
  | _ -> 0

let is_oas_timeout_budget_error (err : Agent_sdk.Error.sdk_error) =
  match Oas_worker_named.classify_masc_internal_error err with
  | Some (Oas_worker_named.Oas_timeout_budget _) -> true
  | _ -> false

let persist_message_cursor_updates ~config (meta : keeper_meta) updates =
  let updated = Keeper_world_observation.apply_message_cursor_updates meta updates in
  if updates = [] then updated
  else
    let merge ~latest ~caller:_ =
      Keeper_world_observation.apply_message_cursor_updates latest updates
    in
    match write_meta_with_merge ~merge config updated with
    | Ok () -> (
        match read_meta config updated.name with
        | Ok (Some latest) -> latest
        | Ok None ->
            Prometheus.inc_counter Prometheus.metric_keeper_meta_read_failures
              ~labels:[("keeper", updated.name); ("site", "cursor_update_none_after_write")]
              ();
            Log.Keeper.warn
              "read_meta returned None after message cursor update write for %s"
              updated.name;
            { updated with meta_version = updated.meta_version + 1 }
        | Error e ->
            Prometheus.inc_counter Prometheus.metric_keeper_meta_read_failures
              ~labels:[("keeper", updated.name); ("site", "cursor_update_read_after_write")]
              ();
            Log.Keeper.warn
              "read_meta failed after message cursor update write for %s: %s"
              updated.name e;
            { updated with meta_version = updated.meta_version + 1 })
    | Error e ->
        Prometheus.inc_counter Prometheus.metric_keeper_write_meta_failures
          ~labels:[("keeper", updated.name); ("phase", "cursor_update")]
          ();
        Log.Keeper.warn "write_meta failed (message cursor update): %s" e;
        updated

let run_keepalive_unified_turn
      ~(ctx : _ context)
      ~(meta_after_triage : keeper_meta)
      ~pending_board_events
      ~(stop : bool Atomic.t)
      ~(proactive_warmup_elapsed : bool)
      ~(shared_context : Agent_sdk.Context.t)
  : keeper_meta
  =
  if not proactive_warmup_elapsed
  then meta_after_triage
  else (
    try
      (* RFC-0020 §3 Rule 4 — drain at most one Event Layer stimulus
         per turn. The stimulus payload is observed for telemetry
         only (consumer-side wiring lives in a follow-up). The
         dequeue itself pins the [Conservation] invariant from
         [KeeperEventQueue.tla] (dequeued_total <= enqueued_total)
         in production, and the [TickQueueOverride] action becomes
         a real runtime transition: a stimulus that triggered the
         heartbeat override (PR-C2 #12412) is now actually consumed
         here. *)
      let queued_board_event =
        match
          Keeper_registry.dequeue_event
            ~base_path:ctx.config.base_path
            meta_after_triage.name
        with
        | None -> None
        | Some stim ->
            let urgency_str =
              match stim.urgency with
              | Keeper_event_queue.Immediate -> "immediate"
              | Keeper_event_queue.Normal -> "normal"
              | Keeper_event_queue.Low -> "low"
            in
            let class_str =
              match Keeper_event_queue.classify stim with
              | Board_signal -> "board_signal"
              | Bootstrap -> "bootstrap"
              | Alive_but_stuck_recovery -> "alive_but_stuck_recovery"
              | Unsupported _ -> "unsupported"
            in
            Prometheus.inc_counter
              Prometheus.metric_keeper_stimulus_consumed
              ~labels:[("keeper", meta_after_triage.name); ("class", class_str)] ();
            Log.Keeper.info
              "turn entry: consumed stimulus stimulus_id=%s urgency=%s class=%s payload_len=%d (keeper=%s)"
              stim.post_id urgency_str class_str
              (String.length stim.payload)
              meta_after_triage.name;
            (match Keeper_event_queue.classify stim with
             | Board_signal ->
                 Keeper_world_observation.pending_board_event_of_stimulus
                   ~continuity_summary:meta_after_triage.continuity_summary
                   ~meta:meta_after_triage stim
             | Bootstrap ->
                 Log.Keeper.info
                   "turn entry: bootstrap stimulus consumed (keeper=%s)"
                   meta_after_triage.name;
                 None
             | Alive_but_stuck_recovery ->
                 (* PR #13123 review: the supervisor already emits a
                    [Log.Keeper.warn] when it detects + enqueues this
                    recovery stimulus.  Logging another warn on the
                    consumer side doubled the alert volume for the
                    same event.  Demote to [info]: this is just a
                    confirmation that the wakeup arrived, not a new
                    signal worth alerting on. *)
                 Log.Keeper.info
                   "turn entry: alive-but-stuck recovery stimulus consumed post_id=%s (keeper=%s)"
                   stim.post_id meta_after_triage.name;
                 None
             | Unsupported prefix ->
                 Prometheus.inc_counter
                   Prometheus.metric_keeper_unsupported_stimulus
                   ~labels:[("keeper", meta_after_triage.name)] ();
                 Log.Keeper.warn
                   "turn entry: unsupported stimulus consumed prefix=%S post_id=%s (keeper=%s) — wake→no_signal gap #12684"
                   prefix stim.post_id meta_after_triage.name;
                 None)
      in
      let pending_board_events =
        match queued_board_event with
        | None -> pending_board_events
        | Some event
          when List.exists
                 (fun existing -> String.equal existing.Keeper_world_observation.post_id event.post_id)
                 pending_board_events ->
            pending_board_events
        | Some event ->
            Log.Keeper.info
              "turn entry: promoted queued board stimulus post_id=%s keeper=%s"
              event.Keeper_world_observation.post_id
              meta_after_triage.name;
            event :: pending_board_events
      in
      let obs =
        let allowed_tool_names =
          Keeper_tool_policy.keeper_allowed_tool_names meta_after_triage
        in
        Keeper_world_observation.observe
          ~allowed_tool_names:(Some allowed_tool_names)
          ~pending_board_events:(Some pending_board_events)
          ~config:ctx.config
          ~meta:meta_after_triage
      in
      let turn_decision =
        Keeper_world_observation.keeper_cycle_decision
          ~meta:meta_after_triage
          obs
      in
      (* Manual reconcile blocker check removed — keepers no longer get
         stuck behind sticky blockers. Failed turns record evidence via
         Keeper_registry; recovery is autonomous (next turn's observation)
         or operator-driven (board/keeper_chat), not blocker-driven. *)
      let should_run_turn =
        (not (Atomic.get stop))
        && turn_decision.should_run
      in
      let meta_after_cursor_persist =
        persist_message_cursor_updates ~config:ctx.config meta_after_triage
          obs.message_cursor_updates
      in
      let format_opt_int = function
        | Some value -> string_of_int value
        | None -> "-"
      in
      let verdict_strs = Keeper_world_observation.verdict_reasons_to_strings turn_decision.verdict in
      let channel_str = Keeper_world_observation.channel_to_string turn_decision.channel in
      if not should_run_turn then (
        (* #10008 fm3: emit per-reason skip counter so operators can
           see why proactive scheduler never fires for a given keeper.
           scholar/executor stayed at [proactive_count_total=0,
           last_proactive_ts=0.0] for 45+ min despite
           proactive_enabled=true — the info log alone buried the
           reason across many lines.  Labelled counter lets Grafana
           split [no_signal] vs [cooldown_pending] vs
           [scheduled_autonomous_disabled] so the bootstrap problem
           ("need signals to fire, need to fire to generate signals")
           is visible fleet-wide. *)
        List.iter (fun reason_str ->
          Prometheus.inc_counter
            Keeper_heartbeat_snapshot.proactive_skip_reason_metric
            ~labels:[
              ("keeper", meta_after_triage.name);
              ("reason", reason_str);
            ] ())
          verdict_strs;
        (* #10940 follow-up — Prometheus counters aggregate skip reasons
           across time, but operators need to see *which* reasons were
           live just before a stale-watchdog [idle_stale=true]
           termination.  Stamping the registry on every skip lets
           [Keeper_stale_watchdog] surface the most recent reasons in
           the kill warn line, distinguishing deliberate-skip dead
           paths from genuinely stuck fibers. *)
        Keeper_registry.record_skip_reasons
          ~base_path:ctx.config.base_path
          meta_after_triage.name
          ~reasons:verdict_strs;
        let paused_info =
          if meta_after_triage.paused
          then
            let blocker_str =
              let trimmed =
                String.trim meta_after_triage.runtime.last_blocker
              in
              if String.equal trimmed "" then "unknown" else trimmed
            in
            let paused_since_sec =
              match
                Coord_resilience.Time.parse_iso8601_opt
                  meta_after_triage.updated_at
              with
              | Some ts ->
                int_of_float (max 0.0 (Time_compat.now () -. ts))
              | None -> -1
            in
            Printf.sprintf " blocker=%s paused_since=%ds"
              blocker_str paused_since_sec
          else ""
        in
        let log_not_scheduled =
          match turn_decision.verdict with
          | Keeper_world_observation.Skip
              { reasons =
                  (Keeper_world_observation.Scheduled_autonomous_disabled, [])
              } ->
            Log.Keeper.debug
          | _ -> Log.Keeper.info
        in
        log_not_scheduled
          "keepalive turn not scheduled for %s: should_run=%b channel=%s \
           reasons=[%s] idle=%ds since_last=%s idle_gate=%s cooldown=%s \
           task_cooldown=%s%s"
          meta_after_triage.name turn_decision.should_run channel_str
          (String.concat "," verdict_strs)
          obs.idle_seconds
          (Keeper_keepalive_signal.format_since_last_scheduled_autonomous
             turn_decision.since_last_scheduled_autonomous)
          (format_opt_int turn_decision.idle_gate_sec)
          (format_opt_int turn_decision.effective_cooldown)
          (format_opt_int turn_decision.task_reactive_cooldown)
          paused_info);
      if should_run_turn
      then
        Log.Keeper.info
          "keepalive turn scheduled for %s: channel=%s reasons=%s"
          meta_after_triage.name channel_str
          (String.concat "," verdict_strs);
      let tool_usage_entries =
        Keeper_registry.tool_usage_of
          ~base_path:ctx.config.base_path meta_after_triage.name
      in
      let available_tools =
        Keeper_tool_policy.keeper_allowed_tool_names meta_after_triage
      in
      let tool_diversity_summary =
        let stats =
          Keeper_tool_diversity.stats_of_registry_entries tool_usage_entries
        in
        Keeper_tool_diversity.compute_diversity ~available_tools stats
      in
      Keeper_tool_diversity.record_underused_tool_metrics
        ~keeper_name:meta_after_triage.name ~available_tools
        tool_diversity_summary;
      (* Phase A2: record decision in audit trail (skip all work when disabled) *)
      if Keeper_decision_audit.audit_enabled () then begin
        let audit_wall_clock = Time_compat.now () in
        let tool_diversity_entropy =
          if tool_usage_entries = [] then None
          else Some tool_diversity_summary.normalized_entropy
        in
        Keeper_decision_audit.append
          ~keeper_name:meta_after_triage.name
          (Keeper_decision_audit.make
             ~cycle_id:(Printf.sprintf "cycle-%s-%Ld"
                meta_after_triage.name
                (Int64.of_float (audit_wall_clock *. 1000.0)))
             ~keeper_name:meta_after_triage.name
             ~generation:meta_after_triage.runtime.generation
             ~heartbeat_verdict:Heartbeat_smart.Emit
             ~turn_verdict:turn_decision.verdict
             ~wall_clock:audit_wall_clock
             ?tool_diversity_entropy ());
        Keeper_decision_audit.flush_if_needed
          ~base_path:ctx.config.base_path
          ~keeper_name:meta_after_triage.name
      end;
      if Atomic.get stop
      then meta_after_cursor_persist
      else if should_run_turn
      then (
        (* Admission wait happens before [mark_turn_started], so the stale
           watchdog would otherwise see an idle keeper while the fiber is
           legitimately blocked behind turn-capacity backpressure. *)
        record_semaphore_wait_observation
          ~base_path:ctx.config.base_path
          ~keeper_name:meta_after_triage.name
          ~channel:turn_decision.channel
          ~kind:Semaphore_wait_pending
          ();
        (* RFC-0026 PR-E-1.6+1.7 shadow: ask the new admission router
           what it WOULD have decided, increment the shadow outcome
           counter, then fall through to the existing semaphore path
           unchanged.

           [init_once_from_base_path] populates the registry from
           [<base_path>/.masc/config/cascade.json] [admission.*]
           sub-tables on first call.  When the JSON has no admission
           blocks the registry stays empty and [observe] returns
           [Legacy_path] always — counter increment still proves the
           call site is alive.  When admission blocks are present,
           the counter starts emitting the [dispatch]/[wait]/[surface]
           label distribution that PR-E-1.8 will act on. *)
        Keeper_admission_runtime.init_once_from_base_path
          ~base_path:ctx.config.base_path;
        let (_ : Keeper_admission_glue.outcome) =
          Keeper_admission_runtime.observe
            ~keeper_id:meta_after_triage.name
        in
        match
          Keeper_turn_slot.with_keeper_turn_slot_control
            ~cascade_profile:meta_after_triage.cascade_name
            ~keeper_name:meta_after_triage.name
            ~channel:turn_decision.channel (fun ~semaphore_wait_ms ~slot_control ->
            match
              with_in_turn_liveness_pulse ~ctx ~meta:meta_after_cursor_persist ~stop
                (fun () ->
                  Keeper_unified_turn.run_keeper_cycle
                    ~config:ctx.config
                    ~meta:meta_after_cursor_persist
                    ~observation:obs
                    ~generation:meta_after_cursor_persist.runtime.generation
                    ~channel:turn_decision.channel
                    ~semaphore_wait_ms:semaphore_wait_ms
                    ~turn_slot_control:slot_control
                    ~shared_context
                    ())
            with
            | Error err ->
              let e_str = Agent_sdk.Error.to_string err in
              (* The inner [run_keeper_cycle] already emits a detailed ERROR
                 ("keeper cycle FAILED cascade=... max_context=... error=...")
                 for every Error path, so re-logging at ERROR here duplicates
                 the line for the same event. Keep a debug trace for local
                 readers; escalate to ERROR only on the fatal-environment
                 branch, which is the real signal this layer owns. *)
              Log.Keeper.debug "%s: keeper cycle failed: %s"
                meta_after_cursor_persist.name e_str;
              if String_util.contains_substring e_str "Eio switch not available"
                 || String_util.contains_substring e_str "Eio net not available"
              then begin
                Log.Keeper.error
                  "%s: fatal environment error — promoting to Keeper_fiber_crash: %s"
                  meta_after_cursor_persist.name e_str;
                Prometheus.inc_counter
                  Prometheus.metric_keeper_heartbeat_failures
                  ~labels:[("keeper", meta_after_cursor_persist.name); ("phase", "fatal_environment")]
                  ();
                Keeper_registry.set_failure_reason
                  ~base_path:ctx.config.base_path meta_after_cursor_persist.name
                  (Some (Keeper_registry.Exception
                    (Printf.sprintf "fatal environment error: %s" e_str)));
                raise Keeper_registry.Keeper_fiber_crash
              end;
              (* PR-M (Leak 9): N-strike promotion for repeated
                 [oas_timeout_budget]. See the comment block above
                 [consecutive_budget_exhaustions] for why a single
                 strike must not trip the crash but
                 [oas_timeout_budget_strike_limit] in a row should —
                 same-fiber retry has the same context budget, so a
                 budget exhaustion is unrecoverable in place and only
                 [sweep_and_recover] can clear it. *)
              if is_oas_timeout_budget_error err
              then begin
                let keeper_name = meta_after_cursor_persist.name in
                let prior_strikes =
                  prior_oas_timeout_budget_strikes
                    ~base_path:ctx.config.base_path
                    ~keeper_name
                in
                let strikes =
                  Keeper_turn_slot.bump_budget_exhaustion_seeded
                    ~keeper_name
                    ~prior_strikes
                in
                Keeper_registry.set_failure_reason
                  ~base_path:ctx.config.base_path keeper_name
                  (Some (Keeper_registry.Oas_timeout_budget_loop
                           { count = strikes }));
                record_oas_timeout_budget_observation
                  ~base_path:ctx.config.base_path
                  ~keeper_name;
                if strikes >= Keeper_turn_slot.oas_timeout_budget_strike_limit then begin
                  Log.Keeper.error
                    "%s: %d consecutive oas_timeout_budget strikes \
                     (>= %d) — promoting to Keeper_fiber_crash for \
                     supervisor auto-pause"
                    keeper_name strikes Keeper_turn_slot.oas_timeout_budget_strike_limit;
                  Prometheus.inc_counter
                    Prometheus.metric_keeper_oas_timeout_budget_strike
                    ~labels:[
                      ("keeper", keeper_name);
                      ("outcome", "promote");
                    ] ();
                  Keeper_turn_slot.reset_budget_exhaustion ~keeper_name;
                  raise Keeper_registry.Keeper_fiber_crash
                end else begin
                  Log.Keeper.warn
                    "%s: oas_timeout_budget strike %d/%d \
                     (next strike will trigger fiber crash + auto-pause)"
                    keeper_name strikes Keeper_turn_slot.oas_timeout_budget_strike_limit;
                  Prometheus.inc_counter
                    Prometheus.metric_keeper_oas_timeout_budget_strike
                    ~labels:[
                      ("keeper", keeper_name);
                      ("outcome", "warn");
                    ] ()
                end
              end;
              (match read_meta ctx.config meta_after_cursor_persist.name with
               | Ok (Some latest) -> latest
               | Ok None ->
                 Log.Keeper.error "keeper:%s read_meta returned None after turn failure, using stale meta"
                   meta_after_cursor_persist.name;
                 Prometheus.inc_counter
                   Prometheus.metric_keeper_meta_read_failures
                   ~labels:[("keeper", meta_after_cursor_persist.name); ("site", "none_after_failure")]
                   ();
                 meta_after_cursor_persist
               | Error e ->
                 Log.Keeper.error "keeper:%s read_meta failed after turn failure (%s), using stale meta"
                   meta_after_cursor_persist.name e;
                 Prometheus.inc_counter
                   Prometheus.metric_keeper_meta_read_failures
                   ~labels:[("keeper", meta_after_cursor_persist.name); ("site", "error_after_failure")]
                   ();
                 meta_after_cursor_persist)
            | Ok updated ->
              (* PR-M: success clears the strike counter so a single
                 transient budget exhaustion does not trickle into the
                 next 4h-window's strike limit. *)
              Keeper_turn_slot.reset_budget_exhaustion ~keeper_name:meta_after_cursor_persist.name;
              clear_oas_timeout_budget_failure_reason
                ~base_path:ctx.config.base_path
                ~keeper_name:meta_after_cursor_persist.name;
              updated)
        with
        | Ok meta -> meta
        | Error (`Semaphore_wait_timeout timeout) ->
          (* Slot/queue wait exceeded the cap — not a keeper failure. Skip this
             cycle and let the next heartbeat retry. Failure counters
             intentionally NOT ticked (this is starvation, not crash); but
             [last_blocker_class] IS updated so the dashboard surfaces the
             stuck reason — without it the keeper appears as
             [outcome=never_started, blocker_class=null] and operators see
             "alive but invisible" (2026-05-05 fleet stuck diagnosis
             evidence). *)
          let phase_label =
            Keeper_turn_slot.semaphore_wait_phase_to_string
              timeout.timeout_phase
          in
          record_semaphore_wait_observation
            ~base_path:ctx.config.base_path
            ~keeper_name:meta_after_triage.name
            ~channel:turn_decision.channel
            ~phase_label
            ~kind:Semaphore_wait_timeout
            ();
          let queue_ahead_text =
            match timeout.timeout_queue_ahead with
            | None -> ""
            | Some ahead -> Printf.sprintf " queue_ahead=%d" ahead
          in
          let holder_text =
            match timeout.timeout_holders with
            | [] -> "none"
            | holders ->
              holders
              |> List.map (fun (name, age) ->
                   Printf.sprintf "%s/%.0fs" name age)
              |> String.concat ", "
          in
          (* #13099 review: [last_blocker] gets capped to 200 chars by
             [cap_blocker] on meta load (narrative budget for dashboards),
             so the longer holder snapshot would be ellipsized after a
             restart and lose the diagnostic value.  Split into two
             strings:
             - [persisted_blocker]: short narrative the dashboards see
               and that survives the cap;
             - [log_diagnostic]: the full holder snapshot, emitted via
               Log.Keeper.warn (uncapped) so operators tailing logs can
               still attribute the starvation to specific peers.  *)
          let persisted_blocker =
            Printf.sprintf
              "skipped: semaphore wait > %.0fs phase=%s \
               (cascade=%s%s queue_depth=%d autonomous_available=%d \
               reactive_available=%d turn_available=%d)"
              timeout.timeout_wait_sec
              phase_label
              meta_after_triage.cascade_name
              queue_ahead_text
              timeout.timeout_queue_depth
              timeout.timeout_autonomous_available
              timeout.timeout_reactive_available
              timeout.timeout_turn_available
          in
          let log_diagnostic =
            Printf.sprintf "%s holders=[%s]" persisted_blocker holder_text
          in
          let blocker_class =
            match timeout.timeout_phase with
            | Keeper_turn_slot.Autonomous_queue_head
            | Keeper_turn_slot.Autonomous_slot ->
              Keeper_types.Autonomous_slot_wait_timeout
            | Keeper_turn_slot.Reactive_slot
            | Keeper_turn_slot.Turn_slot ->
              Keeper_types.Turn_timeout_after_queue_wait
          in
          Log.Keeper.warn
            "%s: skipping turn (%s)"
            meta_after_triage.name log_diagnostic;
          Prometheus.inc_counter
            Prometheus.metric_keeper_semaphore_wait_timeout
            ~labels:[("keeper", meta_after_triage.name); ("channel", (Keeper_world_observation.channel_to_string turn_decision.channel))]
            ();
          Keeper_types.map_runtime
            (fun rt ->
              { rt with
                last_blocker = persisted_blocker;
                last_blocker_class = Some blocker_class;
              })
            meta_after_triage)
      else if obs.message_cursor_updates <> [] then
        meta_after_cursor_persist
      else
        meta_after_triage
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | Keeper_registry.Keeper_fiber_crash as e -> raise e
    | exn ->
      Prometheus.inc_counter
        Prometheus.metric_keeper_cycle_exceptions
        ~labels:[("keeper", meta_after_triage.name)]
        ();
      let backtrace = Printexc.get_backtrace () in
      Log.Keeper.error "%s: keeper cycle exception: %s%s"
        meta_after_triage.name
        (Printexc.to_string exn)
        (if String.equal backtrace "" then "" else "\n" ^ backtrace);
      meta_after_triage)
;;

let refresh_work_as_heartbeat
      ~(ctx : _ context)
      ~(meta_after_proactive : keeper_meta)
      ~(proactive_warmup_elapsed : bool)
      ~(work_as_hb : unit -> bool)
      ~(last_successful_heartbeat_ts : float ref)
      ~(consecutive_failures : int ref)
  : unit
  =
  if work_as_hb () && proactive_warmup_elapsed
  then (
    let hb_ok =
      List.exists
        (fun _room_id ->
           try
             ignore
               (Coord.heartbeat
                  ctx.config
                  ~agent_name:meta_after_proactive.agent_name);
             true
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
             Log.Keeper.debug
               "heartbeat failed for %s: %s"
               meta_after_proactive.name
               (Printexc.to_string exn);
             false)
        meta_after_proactive.joined_room_ids
    in
    if hb_ok
    then (
      last_successful_heartbeat_ts := Time_compat.now ();
      consecutive_failures := 0))
;;

let dispatch_recurring_keepalive
      ~(ctx : _ context)
      ~(meta_after_proactive : keeper_meta)
      ~(now_ts : float)
  : int
  =
  (* Recover from transient broadcast failures that previously
     auto-disabled tasks via [dispatch_due]'s [max_failures] guard.
     Without this call the keeper's heartbeat broadcasts stay silent
     for the lifetime of the process, eventually triggering stale-kill
     cascades.  See lib/keeper/keeper_recurring.ml for the cooldown rule. *)
  let _reenabled =
    Keeper_recurring.reenable_due_tasks
      ~keeper_name:meta_after_proactive.name
      ~now_ts
  in
  try
    Keeper_recurring.dispatch_due
      ~keeper_name:meta_after_proactive.name
      ~now_ts
      ~dispatch:(fun task action ->
        match action with
        | Keeper_recurring.Broadcast msg ->
          (try
             let _ =
               Coord.broadcast
                 ctx.config
                 ~from_agent:meta_after_proactive.agent_name
                 ~content:(Printf.sprintf "[loop:%s] %s" task.label msg)
             in
             Log.Keeper.info "[recurring] %s dispatched: %s" task.id task.label;
             Ok ()
           with
           | exn ->
             Log.Keeper.warn "[recurring] %s failed: %s" task.id (Printexc.to_string exn);
             Prometheus.inc_counter
               Prometheus.metric_keeper_recurring_failures
               ~labels:[("task", task.id); ("phase", "task_execution")]
               ();
             Error (Printexc.to_string exn)))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.warn "[recurring] dispatch error: %s" (Printexc.to_string exn);
    Prometheus.inc_counter
      Prometheus.metric_keeper_recurring_failures
      ~labels:[("task", "dispatch"); ("phase", "dispatch_error")]
      ();
    0
;;

(** Whether a smart-heartbeat decision should allow the keepalive
    cycle to continue evaluating turns.

    Pure for testability. The full [run_smart_heartbeat_gate] layers
    side-effects (sleep, cycle-timestamp update) on top of this
    decision. Regression guard for the "claim-holding keeper
    starvation" bug: [Skip_busy] must NOT gate cycle execution,
    otherwise any keeper with [current_task_id=Some _] is blocked
    from ever running a turn (discovered 2026-04-25 — 8/14 keepers
    frozen with claimed tasks). *)
let smart_heartbeat_cycle_continues (d : Heartbeat_smart.decision) : bool =
  match d with
  | Heartbeat_smart.Skip_busy | Heartbeat_smart.Emit -> true
  | Heartbeat_smart.Skip_idle _ -> false
;;

let cycle_continues_after_wake
      (d : Heartbeat_smart.decision)
      (outcome : Keeper_keepalive_signal.sleep_outcome) : bool =
  match d, outcome with
  | Heartbeat_smart.Skip_idle _, Keeper_keepalive_signal.Woken -> true
  | _, _ -> smart_heartbeat_cycle_continues d
;;

let run_smart_heartbeat_gate
      ~(config : Coord.config)
      ~(clock : _ Eio.Time.clock)
      ~(stop : bool Atomic.t)
      ~(wakeup : bool Atomic.t)
      ~(meta_current : keeper_meta)
      ~(smart_hb_enabled : unit -> bool)
      ~(smart_hb_config : Heartbeat_smart.config)
      ~(last_successful_heartbeat_ts : float ref)
      ~(last_heartbeat_cycle_ts : float ref)
  : bool
  =
  let smart_hb_decision =
    if smart_hb_enabled ()
    then (
      let agent_status = keeper_agent_status meta_current in
      Heartbeat_smart.should_emit
        ~config:smart_hb_config
        ~agent_status
        ~last_activity:!last_successful_heartbeat_ts
        ~last_heartbeat:!last_heartbeat_cycle_ts)
    else Heartbeat_smart.Emit
  in
  (* RFC-0020 Rule 2: the Event Layer queue overrides the Smart Heartbeat
     policy. When the queue holds an unprocessed stimulus, force [Emit]
     regardless of the busy/idle decision so the next cycle consumes the
     stimulus on time. Pinned by KeeperEventQueue.tla
     QueueNeverStarvedBySkip invariant. *)
  let smart_hb_decision =
    if Heartbeat_smart.should_emit_now smart_hb_decision
    then smart_hb_decision
    else (
      let queue =
        Keeper_registry.event_queue_snapshot
          ~base_path:config.base_path meta_current.name
      in
      if not (Keeper_event_queue.is_empty queue) then (
        Prometheus.inc_counter
          Prometheus.metric_keeper_event_queue_override
          ~labels:[ ("keeper", meta_current.name); ("reason", "event_queue") ]
          ();
        Heartbeat_smart.Emit)
      else
        (* Skip_busy already continues the cycle (no idle sleep), so
           probing the world-observation signal here would be redundant
           backlog/board I/O.  The durable-signal probe only matters when
           the gate would otherwise sleep on Skip_idle. *)
        match smart_hb_decision with
        | Heartbeat_smart.Skip_idle _ ->
          let allowed_tool_names =
            Keeper_tool_policy.keeper_allowed_tool_names meta_current
          in
          if
            Keeper_world_observation.durable_signal_present
              ~allowed_tool_names:(Some allowed_tool_names)
              ~pending_board_events:None
              ~config
              ~meta:meta_current
          then (
            Prometheus.inc_counter
              Prometheus.metric_keeper_event_queue_override
              ~labels:
                [ ("keeper", meta_current.name)
                ; ("reason", "durable_state")
                ]
              ();
            Log.Keeper.info
              "smart heartbeat: durable signal present - cycle resumed before stale watchdog";
            Heartbeat_smart.Emit)
          else smart_hb_decision
        | Heartbeat_smart.Skip_busy | Heartbeat_smart.Emit -> smart_hb_decision)
  in
  (* Run side-effects (idle sleep, cycle-timestamp update) per the
     decision, then delegate the gate answer to [cycle_continues_after_wake]
     so the [Skip_idle + Woken] case can promote to [true] (closing the
     [MissedWakeup] gap in KeeperHeartbeat.tla — sibling of #10078). The
     pure helpers stay testable without an Eio runtime. *)
  let sleep_outcome =
    match smart_hb_decision with
    | Heartbeat_smart.Skip_busy ->
      Log.Keeper.debug
        "smart heartbeat: busy (task=%s) — cycle continues, broadcast may be debounced"
        (match meta_current.current_task_id with Some t -> Keeper_id.Task_id.to_string t | None -> "?");
      last_heartbeat_cycle_ts := Time_compat.now ();
      Keeper_keepalive_signal.Timeout
    | Heartbeat_smart.Skip_idle next_time ->
      let wait = Float.max 1.0 (next_time -. Time_compat.now ()) in
      Log.Keeper.debug "smart heartbeat: skip (idle, next in %.1fs)" wait;
      let jitter = wait *. 0.1 *. Random.float 1.0 in
      let outcome =
        Keeper_keepalive_signal.interruptible_sleep
          ~clock ~stop ~wakeup (wait +. jitter)
      in
      (match outcome with
       | Keeper_keepalive_signal.Woken ->
         (* External wakeup arrived during idle backoff: the keeper is
            no longer idle. Stamp the cycle timestamp so the next
            [should_emit] does not immediately re-classify as Skip_idle,
            and let the cycle proceed (presence/board/turn dispatch).
            Spec: KeeperHeartbeat.tla HeartbeatTick — turn_state must
            transition to "running". Prometheus counter is the operator-
            visible positive signal for the #12271 fix path. *)
         Log.Keeper.info
           "smart heartbeat: idle wake — cycle resumed (post=consumed)";
         last_heartbeat_cycle_ts := Time_compat.now ();
         Prometheus.inc_counter
           Prometheus.metric_keeper_skip_idle_wake_resumed
           ~labels:[ ("keeper", meta_current.name) ]
           ()
       | Keeper_keepalive_signal.Stopped | Keeper_keepalive_signal.Timeout -> ());
      outcome
    | Heartbeat_smart.Emit ->
      last_heartbeat_cycle_ts := Time_compat.now ();
      Keeper_keepalive_signal.Timeout
  in
  cycle_continues_after_wake smart_hb_decision sleep_outcome
;;

let maybe_write_heartbeat_snapshot
      ~(ctx : _ context)
      ~(meta_current : keeper_meta)
      ~(now_ts : float)
      ~(consecutive_hb_failures : int)
      ~(last_snapshot_ts : float ref)
      ~(snapshot_interval_sec : int)
      ~(timing_ring : Keeper_keepalive_signal.stage_timing array)
      ~(timing_filled : int)
  : unit
  =
  if now_ts -. !last_snapshot_ts >= float_of_int snapshot_interval_sec
  then (
    (try
       Keeper_heartbeat_snapshot.write_heartbeat_snapshot
         ~ctx
         ~meta_current
         ~now_ts
         ~consecutive_hb_failures
         ~timing_ring
         ~timing_filled
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Prometheus.inc_counter
         Prometheus.metric_keeper_snapshot_write_failures
         ~labels:[("keeper", meta_current.name)]
         ();
       Log.Keeper.error "heartbeat snapshot write failed: %s" (Printexc.to_string exn));
    last_snapshot_ts := now_ts)
;;

let record_keepalive_stage_timing
      ~(timing_ring : Keeper_keepalive_signal.stage_timing array)
      ~(timing_cursor : int ref)
      ~(timing_filled : int ref)
      ~(ring_sz : int)
      ~(t_presence_start : float)
      ~(t_presence_end : float)
      ~(t_snapshot_start : float)
      ~(t_snapshot_end : float)
      ~(t_board_start : float)
      ~(t_board_end : float)
      ~(t_turn_start : float)
      ~(t_turn_end : float)
      ~(t_recurring_start : float)
      ~(t_recurring_end : float)
  : unit
  =
  let timing =
    { presence_ms = (t_presence_end -. t_presence_start) *. 1000.0
    ; snapshot_ms = (t_snapshot_end -. t_snapshot_start) *. 1000.0
    ; board_ms = (t_board_end -. t_board_start) *. 1000.0
    ; turn_ms = (t_turn_end -. t_turn_start) *. 1000.0
    ; recurring_ms = (t_recurring_end -. t_recurring_start) *. 1000.0
    }
  in
  timing_ring.(!timing_cursor) <- timing;
  timing_cursor := (!timing_cursor + 1) mod ring_sz;
  if !timing_filled < ring_sz then incr timing_filled
;;

(* Spec navigation (OCaml -> TLA+) — plan §19 Cycle 27 anchor for
   B1 (Heartbeat).  Authoritative spec mirror is
   specs/keeper-state-machine/KeeperHeartbeat.tla (Cycle 7 / Tier B1,
   PR #11408).

   Spec line 4 cites this function "at line 1815"; the actual current
   line is 1828 (drift of +13 since spec was authored, due to upstream
   changes in this module).  Future spec PRs may re-anchor; until
   then this comment is the authoritative reverse-direction citation.

   Action mapping (TLA+ -> OCaml):
     WakeupSignal     external code sets [wakeup] Atomic to true
                      (e.g., wakeup_keeper / operator_resume).
     HeartbeatTick    [interruptible_sleep] consumes the wakeup via
                      [Atomic.compare_and_set wakeup true false] at
                      this file line 589, then the loop body services
                      the pending event.
     TurnComplete     turn body finishes; loop returns to next sleep
                      cycle.
     MissedWakeup     bug action — the wakeup is observed and cleared
                      but the loop fails to start a turn.  In OCaml
                      this would be a regression where the
                      compare_and_set succeeds but the surrounding
                      branch returns early without dispatching.  The
                      spec's NoMissedSignals invariant catches that
                      drift; in code, the structural invariant is
                      that every successful compare_and_set is
                      followed by the dispatch path on the same loop
                      iteration. *)

let run_heartbeat_loop
      ~proactive_warmup_sec
      (ctx : _ context)
      (m : keeper_meta)
      (stop : bool Atomic.t)
      ~(wakeup : bool Atomic.t)
  : unit
  =
  let keepalive_started_ts = Time_compat.now () in
  let snapshot_interval_sec () =
    Runtime_params.get Governance_registry.keeper_snapshot_sec
  in
  let last_snapshot_ts = ref 0.0 in
  let consecutive_failures = ref 0 in
  (* Cycle 43: KeeperHeartbeat.tla [turn_state] mirror. Single-fiber by
     construction — only this loop body reads/writes the ref. *)
  let turn_running = ref false in
  (* Phase 0: per-stage timing ring buffer.
     ring_size is read once at fiber start — mid-flight resize requires
     ring buffer reallocation, so new values apply on next fiber restart. *)
  let ring_sz = Keeper_keepalive_signal.stage_timing_ring_size () in
  let timing_ring =
    Array.make
      ring_sz
      { presence_ms = 0.0
      ; snapshot_ms = 0.0
      ; board_ms = 0.0
      ; turn_ms = 0.0
      ; recurring_ms = 0.0
      }
  in
  let timing_cursor = ref 0 in
  let timing_filled = ref 0 in
  (* Phase 1: work-as-heartbeat freshness tracking.
     Updated ONLY on Coord.heartbeat success after turn. *)
  let last_successful_heartbeat_ts = ref (Time_compat.now ()) in
  let work_as_hb () = Runtime_params.get Governance_registry.keeper_work_as_hb_enabled in
  let max_silence () =
    Runtime_params.get Governance_registry.keeper_work_as_hb_max_silence_sec
  in
  (* Phase 2: smart heartbeat — adaptive scheduling via Heartbeat_smart *)
  let smart_hb_enabled () =
    Runtime_params.get Governance_registry.keeper_smart_hb_enabled
  in
  let smart_hb_config = Heartbeat_smart.default_config in
  let last_heartbeat_cycle_ts = ref 0.0 in
  (* Persistent OAS Context.t — created once per keeper lifecycle.
     OAS Context.t is a mutable cross-turn state container for values
     written directly into the shared context. This preserves shared
     metadata across turns, but per-turn context_injector-local timing
     and tool-call counters are recreated inside run_turn and therefore
     do not accumulate for the full keeper lifecycle. *)
  let shared_context = Agent_sdk.Context.create () in
  (* Mtime-based change detection for keeper meta disk reads.
     Avoids re-parsing the JSON file on every heartbeat cycle when
     no operator has modified it.  Initialized to 0.0 so the first
     cycle always reads. *)
  let last_meta_mtime = ref 0.0 in
  let rec loop () =
    if Atomic.get stop
    then ()
    else (
      (* Yield before each heartbeat cycle to prevent N keeper fibers
               from monopolizing the Eio scheduler during CPU-bound phases
               (tool filtering, snapshot construction, prompt building). *)
      Eio_guard.fair_yield ();
      (* Phase 0: timing markers *)
      let t_presence_start = Time_compat.now () in
      let disk_meta_opt, new_meta_mtime =
        match read_meta_if_changed ctx.config m.name ~last_mtime:!last_meta_mtime with
        | Some (latest, new_mtime) ->
          Some latest, Some new_mtime
        | None -> None, None
      in
      Option.iter (fun new_mtime -> last_meta_mtime := new_mtime) new_meta_mtime;
      let meta_current =
        effective_keepalive_meta
          ~base_path:ctx.config.base_path
          ~fallback:m
          ~disk_meta_opt
      in
      let meta_current =
        match repair_identity_drift_for_keepalive ~ctx meta_current with
        | Some repaired -> repaired
        | None -> meta_current
      in
      (* Sync disk meta to registry so dashboard reads live values.  #5364.
         When disk meta is unchanged we still prefer the registry copy because
         runtime writes update it via the write_meta hook. This keeps
         continuity/runtime fields fresh even if disk mtime does not advance
         between rapid writes inside a single loop window. *)
      let registry_meta =
        match Keeper_registry.get ~base_path:ctx.config.base_path meta_current.name with
        | Some entry -> entry.meta
        | None -> m
      in
      if meta_current != registry_meta then
        Keeper_registry.update_meta
          ~base_path:ctx.config.base_path meta_current.name meta_current;
      if
        run_smart_heartbeat_gate
          ~config:ctx.config
          ~clock:ctx.clock
          ~stop
          ~wakeup
          ~meta_current
          ~smart_hb_enabled
          ~smart_hb_config
          ~last_successful_heartbeat_ts
          ~last_heartbeat_cycle_ts
      then (
        (* Phase 1: skip presence sync when recent room heartbeat proves freshness *)
        let meta_current =
          sync_keeper_presence
            ~ctx
            ~meta_current
            ~t_presence_start
            ~consecutive_failures
            ~last_successful_heartbeat_ts
            ~work_as_hb
            ~max_silence
        in
        (* RFC-0002: fiber crash on heartbeat threshold breach *)
        if !consecutive_failures >= Keeper_heartbeat_snapshot.max_consecutive_heartbeat_failures ()
        then begin
          Keeper_registry.set_failure_reason
            ~base_path:ctx.config.base_path m.name
            (Some (Keeper_registry.Heartbeat_consecutive_failures
                     !consecutive_failures));
          raise Keeper_registry.Keeper_fiber_crash
        end;
        let t_presence_end = Time_compat.now () in
        let now_ts = t_presence_end in
        (* IR-4 fix: expire stale approval-queue entries every heartbeat cycle.
           Uses [Keeper_config.approval_queue_stale_max_wait_sec] so the timeout
           is explicit and discoverable. Critical entries are excluded by
           expire_stale itself, so only Low/Medium/High are swept. *)
        Keeper_approval_queue.expire_stale
          ~max_wait_s:Keeper_config.approval_queue_stale_max_wait_sec;
        let t_snapshot_start = now_ts in
        maybe_write_heartbeat_snapshot
          ~ctx
          ~meta_current
          ~now_ts
          ~consecutive_hb_failures:!consecutive_failures
          ~last_snapshot_ts
          ~snapshot_interval_sec:(snapshot_interval_sec ())
          ~timing_ring
          ~timing_filled:!timing_filled;
        let t_snapshot_end = Time_compat.now () in
        let t_board_start = t_snapshot_end in
        (* Compute warmup state BEFORE board collection so cursor
                 is not advanced while keeper cannot act on events. *)
        let proactive_warmup_elapsed =
          proactive_warmup_sec <= 0
          || now_ts -. keepalive_started_ts >= float_of_int proactive_warmup_sec
        in
        let pending_board_events, meta_after_triage =
          collect_keepalive_board_events ~ctx ~meta_current ~proactive_warmup_elapsed
        in
        let t_board_end = Time_compat.now () in
        let t_turn_start = t_board_end in
        let meta_after_proactive =
          (* Cycle 43: KeeperHeartbeat.tla TurnComplete bracket — the
             [turn_running] flag toggles around the dispatch and the
             pre/post guards mirror the spec's [turn_state] transition
             "running" -> "idle". *)
          turn_running := true;
          let r =
            run_keepalive_unified_turn
              ~ctx
              ~meta_after_triage
              ~pending_board_events
              ~stop
              ~proactive_warmup_elapsed
              ~shared_context
          in
          Keeper_keepalive_signal.pre_turn_complete_heartbeat ~turn_running;
          turn_running := false;
          Keeper_keepalive_signal.post_turn_complete_heartbeat ~turn_running;
          r
        in
        (* Turn failure threshold: registry tracks count (via unified_turn),
                 keepalive raises to terminate the fiber for supervisor restart. *)
        let turn_fail_count =
          Keeper_registry.get_turn_failures ~base_path:ctx.config.base_path m.name
        in
        (* RFC-0002: dispatch turn status event *)
        if turn_fail_count > 0 then
          Keeper_keepalive_signal.dispatch_keepalive_event ~ctx ~keeper_name:m.name
            (Keeper_state_machine.Turn_failed {
              consecutive = turn_fail_count;
              max_allowed = Keeper_heartbeat_snapshot.max_consecutive_turn_failures ();
            })
        else
          Keeper_keepalive_signal.dispatch_keepalive_event ~ctx ~keeper_name:m.name
            Keeper_state_machine.Turn_succeeded;
        if turn_fail_count >= Keeper_heartbeat_snapshot.max_consecutive_turn_failures ()
        then begin
          Keeper_registry.set_failure_reason
            ~base_path:ctx.config.base_path m.name
            (Some (Keeper_registry.Turn_consecutive_failures turn_fail_count));
          raise Keeper_registry.Keeper_fiber_crash
        end;
        (* Phase 1: work-as-heartbeat — renew point (b).
                 After turn, call Coord.heartbeat to prove room I/O health.
                 On success: refresh freshness lease + reset consecutive_failures.
                 On failure: leave timestamp unchanged → presence sync resumes next cycle. *)
        refresh_work_as_heartbeat
          ~ctx
          ~meta_after_proactive
          ~proactive_warmup_elapsed
          ~work_as_hb
          ~last_successful_heartbeat_ts
          ~consecutive_failures;
        let t_turn_end = Time_compat.now () in
        let t_recurring_start = t_turn_end in
        (* Recurring task dispatch (#3190) *)
        let _recurring_dispatched =
          dispatch_recurring_keepalive ~ctx ~meta_after_proactive ~now_ts
        in
        let t_recurring_end = Time_compat.now () in
        let base =
          if smart_hb_enabled ()
          then
            Heartbeat_smart.effective_interval
              ~config:smart_hb_config
              ~last_activity:!last_successful_heartbeat_ts
          else float_of_int (Keeper_heartbeat_snapshot.keepalive_interval_sec ())
        in
        (* Phase 0: push stage timing to ring buffer *)
        record_keepalive_stage_timing
          ~timing_ring
          ~timing_cursor
          ~timing_filled
          ~ring_sz
          ~t_presence_start
          ~t_presence_end
          ~t_snapshot_start
          ~t_snapshot_end
          ~t_board_start
          ~t_board_end
          ~t_turn_start
          ~t_turn_end
          ~t_recurring_start
          ~t_recurring_end;
        let jitter =
          base *. Env_config.KeeperKeepalive.jitter_factor *. Random.float 1.0
        in
        ignore (Keeper_keepalive_signal.interruptible_sleep
                  ~clock:ctx.clock ~stop ~wakeup (base +. jitter)
                : Keeper_keepalive_signal.sleep_outcome));
      if Atomic.get stop then () else loop ())
  in
  loop ()
;;
