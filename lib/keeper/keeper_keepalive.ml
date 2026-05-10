(** Keeper_keepalive — keeper heartbeat fiber and board-reactive wakeup.

    Per-keeper lifecycle (start, stop, wakeup) is managed through
    [Keeper_registry] (SSOT).  This module provides the heartbeat loop
    body, board-reactive wakeup filtering, and optional gRPC heartbeat
    fiber.

    [MASC_KEEPER_*] env vars read here (semaphore timeout, concurrency,
    fairness cooldown, autoboot max) can also be set in
    [<resolved config root>/keeper_runtime.toml].
    See {!Keeper_runtime_config} and [docs/BOOT-ENV-STATE-INVENTORY.md]
    section 1.3.

    Structure (facade decomposition):
    - [Keeper_turn_slot]      — semaphores, autonomous wait queue,
                                 fairness cooldown, [with_keeper_turn_slot]
    - [Keeper_keepalive_signal] — gRPC client refs, FSM guard identity
                                   helpers, interruptible sleep, wakeup
                                   dispatch, board-reactive wakeup,
                                   stage_timing type, event dispatch
    - [Keeper_heartbeat_snapshot] — heartbeat snapshot write, event
                                     dispatch, stage timing metrics
    - [Keeper_heartbeat_loop]  — [run_keepalive_unified_turn], smart
                                   heartbeat, [run_heartbeat_loop]
    This facade [include]s all four and adds: event bus delegation,
    identity repair, gRPC heartbeat stream, directive processing, and
    keeper lifecycle start/stop. *)

open Keeper_types
open Keeper_memory
open Keeper_execution
include Keeper_turn_slot
include Keeper_keepalive_signal
include Keeper_heartbeat_snapshot
include Keeper_heartbeat_loop

(* OAS Event_bus — delegated to Keeper_event_bus to avoid dependency cycles. *)
let set_bus bus = Keeper_event_bus.set bus
let get_bus () = Keeper_event_bus.get ()

(* ── gRPC directive processing ── *)

let with_keeper_entry_by_identity ~identity ~on_missing f =
  match Keeper_registry.find_by_agent_name identity with
  | Some entry -> f entry
  | None ->
    (match Keeper_registry.find_by_name identity with
     | Some entry -> f entry
     | None -> on_missing ())
;;

let persist_directive_meta_update
      (entry : Keeper_registry.registry_entry)
      ~(updated_meta : keeper_meta)
  : unit
  =
  let keeper_filename = entry.name ^ ".json" in
  let masc_root = Coord_utils.masc_dir_from_base_path ~base_path:entry.base_path in
  let default_path =
    Filename.concat (Filename.concat masc_root "keepers") keeper_filename
  in
  let persisted_path =
    if Fs_compat.file_exists default_path
    then default_path
    else (
      let clusters_dir = Filename.concat masc_root "clusters" in
      let cluster_paths =
        match Safe_ops.list_dir_safe clusters_dir with
        | Ok names ->
          names
          |> List.map (fun cluster_name ->
            Filename.concat
              (Filename.concat (Filename.concat clusters_dir cluster_name) "keepers")
              keeper_filename)
          |> List.filter Fs_compat.file_exists
        | Error _ -> []
      in
      match cluster_paths with
      | [] -> default_path
      | [ path ] -> path
      | paths ->
        let by_mtime_desc a b =
          let a_mtime = Option.value ~default:0.0 (Fs_compat.file_mtime a) in
          let b_mtime = Option.value ~default:0.0 (Fs_compat.file_mtime b) in
          Float.compare b_mtime a_mtime
        in
        (match List.sort by_mtime_desc paths with
         | latest_path :: _ -> latest_path
         | [] -> default_path))
  in
  match Keeper_fs.save_json_atomic persisted_path (meta_to_json updated_meta) with
  | Ok () ->
    Keeper_registry.update_meta ~base_path:entry.base_path entry.name updated_meta
  | Error msg ->
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_write_meta_failures
      ~labels:[ "keeper", entry.name; "site", "directive_persist" ]
      ();
    Log.Keeper.warn "directive meta persist failed for %s: %s" entry.name msg;
    Keeper_registry.update_meta ~base_path:entry.base_path entry.name updated_meta
;;

let set_keeper_paused_state ~agent_name paused =
  with_keeper_entry_by_identity
    ~identity:agent_name
    ~on_missing:(fun () ->
      let action = if paused then "pause" else "resume" in
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_directive_failures
        ~labels:[ "keeper", agent_name; "site", "pause_resume_not_in_registry" ]
        ();
      Log.Keeper.warn "directive %s: agent %s not in registry" action agent_name)
    (fun entry ->
       let updated_meta = { entry.meta with paused; updated_at = now_iso () } in
       persist_directive_meta_update entry ~updated_meta;
       Keeper_registry.dispatch_event_unit
         ~base_path:entry.base_path
         entry.name
         (if paused
          then Keeper_state_machine.Operator_pause
          else Keeper_state_machine.Operator_resume);
       if not paused
       then (
         (* tla-lint: allow-mutation: fiber signal — Atomic flag wakes the keeper from Eio.Promise.await *)
         Atomic.set entry.fiber_wakeup true;
         (* Cycle 43: KeeperHeartbeat.tla WakeupSignal post-condition.
            The [@@fsm_guard] PPX routes the assertion through
            [wrap_unit ~stage:"guard"] automatically. *)
         post_wakeup_signal ~wakeup:entry.fiber_wakeup))
;;

let wakeup_keeper_by_agent_name ~agent_name =
  with_keeper_entry_by_identity
    ~identity:agent_name
    ~on_missing:(fun () ->
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_directive_failures
        ~labels:[ "keeper", agent_name; "site", "wakeup_not_in_registry" ]
        ();
      Log.Keeper.warn "directive wakeup: agent %s not in registry" agent_name)
    (fun entry -> wakeup_keeper ~base_path:entry.base_path entry.name)
;;

let assign_keeper_task_from_directive ~agent_name ~task_id =
  with_keeper_entry_by_identity
    ~identity:agent_name
    ~on_missing:(fun () ->
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_directive_failures
        ~labels:[ "keeper", agent_name; "site", "claim_not_in_registry" ]
        ();
      Log.Keeper.warn "directive claim: agent %s not in registry" agent_name)
    (fun entry ->
       let updated_meta =
         { entry.meta with current_task_id = Some task_id; updated_at = now_iso () }
       in
       persist_directive_meta_update entry ~updated_meta;
       (* Cycle 44: KeeperTaskAcquisition.tla SubmitTask post-action
          guard pins that the directive successfully attached the
          [task_id] to the keeper's meta. The [@@fsm_guard] PPX
          routes the assertion through [wrap_unit ~stage:"guard"]
          automatically. *)
       post_submit_task ~meta:updated_meta ~task_id;
       wakeup_keeper ~base_path:entry.base_path entry.name)
;;

(** Process a single directive received from a gRPC HeartbeatAck.
    Directives are string commands: "pause", "resume", "wakeup",
    "claim:<task_id>". Unknown directives are logged and ignored. *)
let process_directive ~agent_name directive =
  match directive with
  | "pause" ->
    Log.Keeper.info "directive: pausing keeper %s" agent_name;
    set_keeper_paused_state ~agent_name true
  | "resume" ->
    Log.Keeper.info "directive: resuming keeper %s" agent_name;
    set_keeper_paused_state ~agent_name false
  | "wakeup" ->
    (* Auto-resume on wakeup: dashboard "깨우기" surfaces a single button,
       but auto-pause (stale_fleet_batch / turn_timeout) silently persists
       [meta.paused = true]. Without this branch, wakeup signals fiber_wakeup
       but the heartbeat loop honors paused state and skips — user clicks
       "깨우기" with no observable effect. Treat wakeup as a superset of
       resume so paused keepers re-enter the run loop. *)
    let entry_paused =
      match Keeper_registry.find_by_agent_name agent_name with
      | Some e -> e.meta.paused
      | None ->
        (match Keeper_exec_shared.find_registry_meta
                 ~keeper_name:agent_name
                 ~source_layer:"keepalive"
         with
         | Some meta -> meta.paused
         | None -> false)
    in
    if entry_paused
    then (
      Log.Keeper.info "directive: waking up %s (was paused — auto-resuming)" agent_name;
      set_keeper_paused_state ~agent_name false)
    else (
      Log.Keeper.debug "directive: waking up %s" agent_name;
      wakeup_keeper_by_agent_name ~agent_name)
  | s when String.length s > 6 && String.starts_with s ~prefix:"claim:" ->
    let task_id = String.sub s 6 (String.length s - 6) in
    (match Keeper_id.Task_id.of_string task_id with
     | Ok parsed_task_id ->
       Log.Keeper.info "directive: server assigned task %s to %s" task_id agent_name;
       assign_keeper_task_from_directive ~agent_name ~task_id:parsed_task_id
     | Error err ->
       Log.Keeper.warn
         "directive: ignoring invalid task assignment for %s (%s): %s"
         agent_name
         task_id
         err)
  | unknown -> Log.Keeper.warn "unknown gRPC directive for %s: %s" agent_name unknown
;;

(* ── gRPC heartbeat stream ── *)

let reconcile_current_task_id_for_heartbeat ~config ~agent_name =
  try
    Keeper_current_task_reconcile.sync_current_task_id_for_agent_name ~config ~agent_name;
    true
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_reconcile_failures
      ~labels:[ "keeper", agent_name; "phase", "grpc_heartbeat" ]
      ();
    Log.Keeper.warn
      "gRPC heartbeat: failed to reconcile current_task_id for %s: %s"
      agent_name
      (Printexc.to_string exn);
    false
;;

let registry_current_task_id agent_name =
  match Keeper_registry.find_by_agent_name agent_name with
  | Some e -> e.meta.current_task_id
  | None -> None
;;

let current_task_id_for_agent ~config agent_name =
  match registry_current_task_id agent_name with
  | None -> ""
  | Some _ ->
    if reconcile_current_task_id_for_heartbeat ~config ~agent_name
    then (
      match registry_current_task_id agent_name with
      | Some task_id -> Keeper_id.Task_id.to_string task_id
      | None -> "")
    else ""
;;

let make_grpc_heartbeat_ping ~config ~agent_name ~session_id =
  Masc_grpc_types.HeartbeatPing.
    { agent_name
    ; session_id
    ; timestamp_ms = Int64.of_float (Time_compat.now () *. 1000.0)
    ; current_task_id = current_task_id_for_agent ~config agent_name
    }
;;

let handle_grpc_heartbeat_ack ~agent_name (ack : Masc_grpc_types.HeartbeatAck.t) =
  Log.Keeper.debug
    "gRPC bidi heartbeat: agent=%s agents=%d tasks=%d directives=%d"
    agent_name
    ack.active_agent_count
    ack.pending_task_count
    (List.length ack.directives);
  List.iter (process_directive ~agent_name) ack.directives
;;

let run_grpc_heartbeat_stream
      ~stop
      ~close_ref
      ~clock
      ~interval_sec
      ~config
      ~agent_name
      ~session_id
      send
      recv
  =
  let rec tick () =
    if Atomic.get stop || Atomic.get close_ref
    then ()
    else (
      (try
         send (make_grpc_heartbeat_ping ~config ~agent_name ~session_id);
         match recv () with
         | Ok ack -> handle_grpc_heartbeat_ack ~agent_name ack
         | Error err ->
           Prometheus.inc_counter
             Keeper_metrics.metric_keeper_heartbeat_failures
             ~labels:[ "keeper", agent_name; "site", "grpc_recv" ]
             ();
           Log.Keeper.warn "gRPC heartbeat recv: %s" err
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | End_of_file -> raise End_of_file
       | exn ->
         Prometheus.inc_counter
           Keeper_metrics.metric_keeper_heartbeat_failures
           ~labels:[ "keeper", agent_name; "site", "grpc_tick" ]
           ();
         Log.Keeper.error "gRPC heartbeat tick error: %s" (Printexc.to_string exn));
      if not (Atomic.get stop || Atomic.get close_ref)
      then (
        let no_wakeup = Atomic.make false in
        ignore
          (interruptible_sleep ~clock ~stop ~wakeup:no_wakeup interval_sec
           : Keeper_keepalive_signal.sleep_outcome);
        tick ()))
  in
  tick ()
;;

let log_grpc_heartbeat_stream_failure ~agent_name ~attempts = function
  | `Closed ->
    Log.Keeper.warn
      "gRPC heartbeat stream closed for %s (attempt %d/%d)"
      agent_name
      (attempts + 1)
      Env_config.KeeperGrpc.max_reconnect_attempts
  | `Error exn ->
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_heartbeat_failures
      ~labels:[ "keeper", agent_name; "site", "grpc_stream" ]
      ();
    Log.Keeper.warn
      "gRPC heartbeat stream error for %s: %s (attempt %d/%d)"
      agent_name
      (Printexc.to_string exn)
      (attempts + 1)
      Env_config.KeeperGrpc.max_reconnect_attempts
;;

(** Run a gRPC heartbeat sender in a background fiber.
    Opens a bidirectional [Heartbeat] stream and sends [HeartbeatPing]
    messages at the configured interval. Reads [HeartbeatAck] responses,
    logs agent/task counts, and dispatches directives. Reconnects on
    stream failure up to 5 times. Stops when [stop] is set.

    Requires [grpc_client_ref] to be set (via [set_grpc_client])
    and Eio switch/env to be available in [Eio_context]. *)
let max_reconnect_attempts = Env_config.KeeperGrpc.max_reconnect_attempts

let reconnect_backoff_sec = Env_config.KeeperGrpc.reconnect_backoff_sec

let run_grpc_heartbeat_fiber
      ~sw
      ~stop
      ~(grpc_client : Masc_grpc_client.t)
      ~(config : Coord.config)
      ~(agent_name : string)
      ~(session_id : string)
      ~(interval_sec : float)
      ~(clock : _ Eio.Time.clock)
  =
  match Eio_context.get_switch_opt (), Atomic.get grpc_env_ref with
  | None, _ | _, None ->
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_heartbeat_failures
      ~labels:[ "keeper", agent_name; "site", "grpc_no_eio_context" ]
      ();
    Log.Keeper.warn "gRPC heartbeat: Eio context or env not available";
    None
  | Some grpc_sw, Some env ->
    let close_ref = Atomic.make false in
    Eio.Fiber.fork ~sw (fun () ->
      (* Outer loop: reconnect on stream failure *)
      let rec connect_loop attempts =
        if Atomic.get stop || Atomic.get close_ref
        then ()
        else if attempts >= max_reconnect_attempts
        then (
          Prometheus.inc_counter
            Keeper_metrics.metric_keeper_heartbeat_failures
            ~labels:[ "keeper", agent_name; "site", "grpc_reconnect_exhausted" ]
            ();
          Log.Keeper.error
            "gRPC heartbeat: exceeded %d reconnect attempts for %s, stopping"
            max_reconnect_attempts
            agent_name)
        else (
          let send, recv, close_stream =
            Masc_grpc_client.heartbeat_stream grpc_client ~sw:grpc_sw ~env
          in
          (try
             run_grpc_heartbeat_stream
               ~stop
               ~close_ref
               ~clock
               ~interval_sec
               ~config
               ~agent_name
               ~session_id
               send
               recv
           with
           | Eio.Cancel.Cancelled _ as e ->
             close_stream ();
             raise e
           | End_of_file ->
             log_grpc_heartbeat_stream_failure ~agent_name ~attempts `Closed;
             close_stream ()
           | exn ->
             log_grpc_heartbeat_stream_failure ~agent_name ~attempts (`Error exn);
             close_stream ());
          if not (Atomic.get stop || Atomic.get close_ref)
          then (
            Eio.Time.sleep clock reconnect_backoff_sec;
            connect_loop (attempts + 1)))
      in
      connect_loop 0);
    Some (fun () -> Atomic.set close_ref true)
;;

let start_keeper_grpc_heartbeat
      ~(ctx : _ context)
      ~(m : keeper_meta)
      ~(stop : bool Atomic.t)
  : (unit -> unit) option
  =
  match Masc_grpc_transport.from_env (), Atomic.get grpc_client_ref with
  | Masc_grpc_transport.Grpc, Some client ->
    Log.Keeper.info "keeper %s: starting gRPC heartbeat fiber" m.name;
    let interval = float_of_int (keepalive_interval_sec ()) in
    let session_id =
      Printf.sprintf
        "keeper-%s-%Ld"
        m.name
        (Int64.of_float (Time_compat.now () *. 1000.0))
    in
    run_grpc_heartbeat_fiber
      ~sw:ctx.sw
      ~stop
      ~grpc_client:client
      ~config:ctx.config
      ~agent_name:m.agent_name
      ~session_id
      ~interval_sec:interval
      ~clock:ctx.clock
  | Masc_grpc_transport.Grpc, None ->
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_heartbeat_failures
      ~labels:[ "keeper", m.name; "site", "grpc_no_client" ]
      ();
    Log.Keeper.warn "keeper %s: gRPC transport requested but no client configured" m.name;
    None
  | _ -> None
;;

(* ── Lifecycle bootstrap / publish helpers ── *)

let bootstrap_live_keeper_meta ~(ctx : _ context) (m : keeper_meta) : keeper_meta =
  try
    if not (Coord_utils.is_initialized ctx.config)
    then (
      let (_init_msg : string) = Coord.init ctx.config ~agent_name:None in
      ());
    let m =
      match repair_identity_drift_for_keepalive ~ctx m with
      | Some repaired -> repaired
      | None -> m
    in
    let synced = ensure_keeper_room_presence ctx.config m in
    (* Reset stale timestamp from previous server lifecycle.

       Use [Time_compat.now ()] (not [0.0]). The original intent was to
       prevent the stale watchdog from immediately terminating the fiber
       on server restart by clearing an old [last_turn_ts]. Setting it
       to [0.0] worked for that — but [keeper_stale_watchdog.ml:141]
       gates the stall check on [last_turn > 0.0], so [0.0] permanently
       blinds the watchdog: a keeper that never runs a real turn (auth
       failure, OAS budget exhaustion, no work signal) stays in a
       zombie state the watchdog cannot detect.

       Resetting to [now_ts] preserves the original goal — grace_period
       (180s default) covers the bootstrap window so the watchdog still
       doesn't fire prematurely — while restoring detection for a
       truly idle keeper after grace elapses. Real turns continue to
       overwrite this with the actual turn time as before.

       Production evidence (2026-04-27): 7 of 11 keepers had
       [last_turn_ts = 0.0] for 50-65 min after server restart with no
       watchdog stall fired despite obvious silence. *)
    let bootstrap_ts = Time_compat.now () in
    let synced =
      { synced with
        runtime =
          { synced.runtime with
            usage = { synced.runtime.usage with last_turn_ts = bootstrap_ts }
          }
      }
    in
    (match write_meta ~force:true ctx.config synced with
     | Ok () -> ()
     | Error e ->
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_write_meta_failures
         ~labels:[ "keeper", synced.name; "phase", "bootstrap" ]
         ();
       Log.Keeper.warn "write_meta failed (bootstrap): %s" e);
    synced
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_write_meta_failures
      ~labels:[ "keeper", m.name; "phase", "bootstrap-catch" ]
      ();
    Log.Keeper.error "room presence bootstrap failed: %s" (Printexc.to_string exn);
    m
;;

(* #8856: hook takes the unified
   [Keeper_lifecycle_events.lifecycle_event] variant. *)
let publish_keeper_lifecycle
      ~(event : Keeper_lifecycle_events.lifecycle_event)
      ~keeper_name
      ~detail
      ()
  : unit
  =
  match get_bus () with
  | Some bus -> Cascade_events.publish_keeper_lifecycle bus ~event ~keeper_name ~detail ()
  | None -> ()
;;

(** Phase-event helper: the wire event name IS the phase name. *)
let publish_keeper_phase_lifecycle ~phase ~keeper_name ~detail () : unit =
  publish_keeper_lifecycle
    ~event:(Keeper_lifecycle_events.Phase_event phase)
    ~keeper_name
    ~detail
    ()
;;

let publish_keeper_started ~(live_meta : keeper_meta) : unit =
  publish_keeper_lifecycle
    ~event:
      (Keeper_lifecycle_events.Custom_event
         { verb = Keeper_lifecycle_events.Started
         ; phase = Some Keeper_state_machine.Running
         })
    ~keeper_name:live_meta.name
    ~detail:"keepalive"
    ()
;;

let dispatch_fiber_started ~base_path keeper_name =
  match Keeper_registry.prepare_fiber_launch ~base_path keeper_name with
  | Ok _ -> ()
  | Error err ->
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_dispatch_event_failures
      ~labels:[ "keeper", keeper_name; "site", "fiber_started_rejected" ]
      ();
    Log.Keeper.warn
      "keeper %s: Fiber_started rejected during launch: %s"
      keeper_name
      (Keeper_state_machine.transition_error_to_string err)
;;

(* ── Registry lifecycle helpers ── *)

let resolve_registry_done
      (entry : Keeper_registry.registry_entry)
      (value : [ `Stopped | `Crashed of string ])
  : bool
  =
  Keeper_registry.try_resolve_done entry value
;;

let record_keeper_stopped
      (entry : Keeper_registry.registry_entry)
      ~base_path
      ~keeper_name
      ~detail
  : bool
  =
  if resolve_registry_done entry `Stopped
  then (
    Keeper_registry.dispatch_event_unit
      ~base_path
      keeper_name
      Keeper_state_machine.Stop_requested;
    Keeper_registry.dispatch_event_unit
      ~base_path
      keeper_name
      Keeper_state_machine.Drain_complete;
    publish_keeper_phase_lifecycle
      ~phase:Keeper_state_machine.Stopped
      ~keeper_name
      ~detail
      ();
    true)
  else false
;;

let record_keeper_crashed
      (entry : Keeper_registry.registry_entry)
      ~base_path
      ~keeper_name
      ~failure_reason
  : unit
  =
  let reason = Keeper_registry.failure_reason_to_string failure_reason in
  if resolve_registry_done entry (`Crashed reason)
  then (
    Keeper_registry.set_failure_reason ~base_path keeper_name (Some failure_reason);
    Keeper_registry.dispatch_event_unit
      ~base_path
      keeper_name
      (Keeper_state_machine.Fiber_terminated { outcome = reason });
    Keeper_registry.record_crash ~base_path keeper_name (Time_compat.now ()) reason;
    Keeper_registry.record_error ~base_path keeper_name reason;
    publish_keeper_phase_lifecycle
      ~phase:Keeper_state_machine.Crashed
      ~keeper_name
      ~detail:reason
      ())
;;

(* ── Keeper lifecycle start/stop ── *)

let start_keepalive ?(proactive_warmup_sec = 0) (ctx : _ context) (m : keeper_meta) : unit
  =
  match repair_identity_drift_for_keepalive ~ctx m with
  | None ->
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_heartbeat_failures
      ~labels:[ "keeper", m.name; "phase", "identity_drift_unrepairable" ]
      ();
    Log.Keeper.error
      "start_keepalive skipped %s: identity drift could not be repaired"
      m.name
  | Some m ->
    let existing_entry = Keeper_registry.get ~base_path:ctx.config.base_path m.name in
    let reclaim_stale_stopped_entry (entry : Keeper_registry.registry_entry) =
      entry.phase = Keeper_state_machine.Stopped
      && Eio.Promise.peek entry.done_p = Some `Stopped
    in
    (match existing_entry with
     | Some entry when reclaim_stale_stopped_entry entry ->
       Log.Keeper.info "start_keepalive: reclaiming stale stopped entry %s" m.name;
       Keeper_registry.unregister ~base_path:ctx.config.base_path m.name
     | _ -> ());
    if Keeper_registry.is_registered ~base_path:ctx.config.base_path m.name
    then Log.Keeper.info "start_keepalive: skipped %s (already registered)" m.name
    else if not (Keeper_registry.spawn_slots_available ())
    then Log.Keeper.info "start_keepalive: skipped %s (no spawn slots)" m.name
    else (
      (* Register in Keeper_registry first — single source of truth. *)
      let reg =
        Keeper_registry.register_offline ~base_path:ctx.config.base_path m.name m
      in
      (* Restore persisted tool usage stats from previous session *)
      Keeper_registry.restore_tool_usage ~base_path:ctx.config.base_path m.name;
      let stop = reg.fiber_stop in
      let wakeup = reg.fiber_wakeup in
      (* Start optional gRPC heartbeat fiber *)
      let grpc_close = start_keeper_grpc_heartbeat ~ctx ~m ~stop in
      (match grpc_close with
       | Some _ ->
         Keeper_registry.set_grpc_close ~base_path:ctx.config.base_path m.name grpc_close
       | None -> ());
      let live_meta = bootstrap_live_keeper_meta ~ctx m in
      Keeper_registry.update_meta ~base_path:ctx.config.base_path m.name live_meta;
      (* Telemetry feedback refresh loop removed in #6814:
       behavioral_stats no longer consumed by build_prompt. *)
      dispatch_fiber_started ~base_path:ctx.config.base_path live_meta.name;
      publish_keeper_started ~live_meta;
      Keeper_stale_watchdog.fork_stale_watchdog ctx live_meta reg;
      Eio.Fiber.fork ~sw:ctx.sw (fun () ->
        let record_crash failure_reason =
          record_keeper_crashed
            reg
            ~base_path:ctx.config.base_path
            ~keeper_name:live_meta.name
            ~failure_reason
        in
        let record_stopped detail =
          ignore
            (record_keeper_stopped
               reg
               ~base_path:ctx.config.base_path
               ~keeper_name:live_meta.name
               ~detail)
        in
        let record_loop_exit () =
          match Keeper_registry.get ~base_path:ctx.config.base_path live_meta.name with
          | Some
              { Keeper_registry.last_failure_reason =
                  Some
                    (( Keeper_registry.Stale_turn_timeout _
                     | Keeper_registry.Stale_termination_storm _
                     | Keeper_registry.Stale_fleet_batch _
                     | Keeper_registry.Oas_timeout_budget_loop _ ) as reason)
              ; _
              } -> record_crash reason
          | _ -> record_stopped "normal exit"
        in
        (* Cancel-safe finally (#9747 iter 2): [cleanup_tracking] touches
         registry state that can raise transiently during shutdown.
         Stdlib [Fun.protect] would wrap that as [Fun.Finally_raised],
         masking the body's Cancelled / Keeper_fiber_crash. Swallow
         Cancelled (the outer one is in flight) and log non-cancel
         exceptions instead of propagating them. Mirrors
         keeper_agent_run.ml and keeper_unified_turn.ml:990. *)
        let safe_cleanup_tracking () =
          try
            Keeper_registry.cleanup_tracking
              ~base_path:ctx.config.base_path
              live_meta.name
          with
          | Eio.Cancel.Cancelled _ -> ()
          | e ->
            Prometheus.inc_counter
              Keeper_metrics.metric_keeper_cleanup_tracking_failures
              ~labels:[ "keeper", live_meta.name; "site", "heartbeat_finally" ]
              ();
            Log.Keeper.warn
              "%s: cleanup_tracking in heartbeat finally raised: %s"
              live_meta.name
              (Printexc.to_string e)
        in
        Eio_guard.protect
          (fun () ->
             try
               run_heartbeat_loop ~proactive_warmup_sec ctx live_meta stop ~wakeup;
               record_loop_exit ()
             with
             | Keeper_registry.Keeper_fiber_crash ->
               if Atomic.get stop
               then record_stopped "manual stop"
               else (
                 let reason =
                   match
                     Keeper_registry.get ~base_path:ctx.config.base_path live_meta.name
                   with
                   | Some e ->
                     Option.value
                       ~default:(Keeper_registry.Exception "fiber_crash")
                       e.last_failure_reason
                   | None -> Keeper_registry.Exception "fiber_crash"
                 in
                 record_crash reason)
             | Eio.Cancel.Cancelled _ as e -> raise e
             | exn ->
               if Atomic.get stop
               then record_stopped "manual stop"
               else (
                 Prometheus.inc_counter
                   Keeper_metrics.metric_keeper_heartbeat_failures
                   ~labels:[ "keeper", live_meta.name; "phase", "loop_crash" ]
                   ();
                 Log.Keeper.error
                   "heartbeat loop for %s crashed: %s"
                   live_meta.name
                   (Printexc.to_string exn);
                 record_crash (Keeper_registry.Exception (Printexc.to_string exn))))
          ~finally:safe_cleanup_tracking))
;;

let stop_keepalive ?base_path name =
  let entries =
    Keeper_registry.all ?base_path ()
    |> List.filter (fun (e : Keeper_registry.registry_entry) -> String.equal e.name name)
  in
  List.iter
    (fun (entry : Keeper_registry.registry_entry) ->
       (* tla-lint: allow-mutation: fiber signal — stop+wakeup pair triggers cooperative shutdown *)
       Atomic.set entry.fiber_stop true;
       Atomic.set entry.fiber_wakeup true;
       (* Cycle 43: KeeperHeartbeat.tla WakeupSignal post-condition fires
          even on stop_keepalive — the wakeup atomic must be observable
          as TRUE before the heartbeat fiber consumes its termination
          signal. *)
       post_wakeup_signal ~wakeup:entry.fiber_wakeup;
       (match Atomic.get entry.grpc_close with
        | Some close_fn ->
          (try close_fn () with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | _exn ->
             Prometheus.inc_counter
               "masc_keeper_grpc_close_failures"
               ~labels:[ "keeper", entry.meta.name ]
               ())
        | None -> ());
       match entry.phase with
       | Keeper_state_machine.Crashed | Keeper_state_machine.Dead -> ()
       | _ ->
         if
           record_keeper_stopped
             entry
             ~base_path:entry.base_path
             ~keeper_name:entry.name
             ~detail:"manual stop"
         then Keeper_registry.cleanup_tracking ~base_path:entry.base_path entry.name)
    entries
;;

(** Stop all running keepers. Used in test cleanup to prevent orphaned
    keepalive loops from blocking process exit. *)
let stop_all_keepalives () =
  Keeper_registry.all ()
  |> List.iter (fun (entry : Keeper_registry.registry_entry) -> stop_keepalive entry.name)
;;
