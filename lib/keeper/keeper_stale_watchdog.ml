(** Stale-turn watchdog — standalone fiber for keeper liveness detection.

    Extracted from [Keeper_supervisor] to avoid circular dependency with
    [Keeper_keepalive]. Both modules call [fork_stale_watchdog] through
    this shared implementation.

    Two stall detection modes:
    1. Idle stall: [last_turn_ts] older than 300s while [Running].
    2. Failure loop: [consecutive_noop_count >= 3] — catches keepers in
       LLM timeout loops where [last_turn_ts] stays fresh because each
       failed turn updates it.

    On detection, sets [fiber_stop] and emits a stale broadcast so the
    supervisor's [sweep_and_recover] can restart the keeper.

    @since PR #10670 — extracted from Keeper_supervisor. *)

open Keeper_types

(* Process-global termination history per keeper.  Survives keeper
   unregister/re-register because the watchdog module's state lives
   for the server process lifetime.  Each entry records the
   timestamps of recent stale terminations within a sliding window;
   when the count exceeds [escalation_threshold] we emit a loud
   warn line and a Prometheus counter so operators see the death
   spiral pattern (#10765 — 116 stale terminations / 24h, single
   keeper hit 13× with no escalation under the previous design).

   This is observability only — we still let the supervisor restart
   the keeper.  Phase 2 (deciding whether to auto-pause) is left
   for a follow-up PR with measurement evidence in hand. *)
let termination_window_sec = 21600.0  (* 6h *)
let escalation_threshold = 5
let termination_history : (string, float list) Hashtbl.t = Hashtbl.create 16
let termination_history_mu = Eio.Mutex.create ()

let record_stale_termination keeper_name now : int =
  Eio.Mutex.use_rw ~protect:true termination_history_mu (fun () ->
    let prev =
      Hashtbl.find_opt termination_history keeper_name
      |> Option.value ~default:[]
    in
    let window_start = now -. termination_window_sec in
    let pruned = List.filter (fun ts -> ts >= window_start) (now :: prev) in
    Hashtbl.replace termination_history keeper_name pruned;
    List.length pruned)

let fork_stale_watchdog (ctx : _ context) (meta : keeper_meta)
    (reg : Keeper_registry.registry_entry) =
  let base_path = ctx.config.base_path in
  let stale_threshold_sec () =
    Env_config_keeper.KeeperWatchdog.stale_threshold_sec
  in
  let watchdog_poll_sec () =
    Env_config_keeper.KeeperWatchdog.poll_sec
  in
  let noop_threshold () =
    Env_config_keeper.KeeperWatchdog.noop_threshold
  in
  let grace_period_sec () =
    Env_config_keeper.KeeperWatchdog.grace_period_sec
  in
  let last_broadcast_ts = ref 0.0 in
  Eio.Fiber.fork ~sw:ctx.sw (fun () ->
    let rec watchdog_loop () =
      if Atomic.get reg.fiber_stop then ()
      else begin
        Eio.Fiber.yield ();
        let now = Time_compat.now () in
        let threshold = stale_threshold_sec () in
        (try
           match Keeper_registry.get ~base_path meta.name with
           | Some entry
             when entry.phase = Keeper_state_machine.Running ->
             let last_turn = entry.meta.runtime.usage.last_turn_ts in
             let fiber_age = now -. entry.started_at in
             let grace_remaining = grace_period_sec () -. fiber_age in
             let idle_stale =
               last_turn > 0.0
               && now -. last_turn > threshold
               && fiber_age >= grace_period_sec ()
             in
             let noop_count =
               entry.meta.runtime.proactive_rt.consecutive_noop_count
             in
             let failure_loop = noop_count >= noop_threshold () in
             let stale = idle_stale || failure_loop in
             Log.Keeper.info
               "%s: watchdog tick noop=%d idle_stale=%b failure_loop=%b stale=%b last_turn=%.0f fiber_age=%.0f grace_rem=%.0f"
               meta.name noop_count idle_stale failure_loop stale last_turn
               fiber_age grace_remaining;
             let cooldown_ok =
               !last_broadcast_ts = 0.0
               || now -. !last_broadcast_ts > threshold
             in
             if stale && cooldown_ok then begin
               let reason_desc =
                 if idle_stale
                 then Printf.sprintf "idle %.0fs" (now -. last_turn)
                 else Printf.sprintf "failure-loop noop=%d" noop_count
               in
               Keeper_registry.set_failure_reason ~base_path meta.name
                 (Some (Keeper_registry.Stale_turn_timeout
                          (now -. last_turn)));
               Atomic.set reg.fiber_stop true;
               let window_count = record_stale_termination meta.name now in
               Prometheus.inc_counter
                 "masc_keeper_stale_termination_total"
                 ~labels:[ ("keeper", meta.name) ]
                 ();
               Log.Keeper.error
                 "%s: stale watchdog terminating fiber (%s) [window_count=%d/6h]"
                 meta.name reason_desc window_count;
               if window_count >= escalation_threshold then begin
                 Prometheus.inc_counter
                   "masc_keeper_stale_termination_threshold_breached_total"
                   ~labels:[ ("keeper", meta.name) ]
                   ();
                 Log.Keeper.error
                   "%s: STALE-TERMINATION THRESHOLD BREACHED — %d \
                    terminations in last %.0fs (threshold=%d). The \
                    supervisor will continue to restart this keeper, \
                    but the underlying root cause (cascade dead, fd \
                    leak, provider auth, etc.) needs operator review. \
                    See issue #10765."
                   meta.name window_count termination_window_sec
                   escalation_threshold
               end;
               (try
                  Keeper_execution_receipt.emit_stale_keeper_broadcast
                    ctx.config
                    ~keeper_name:meta.name
                    ~agent_name:meta.agent_name
                    ~trace_id:
                      (Keeper_id.Trace_id.to_string
                         entry.meta.runtime.trace_id)
                    ~generation:entry.meta.runtime.generation
                    ~stale_seconds:(now -. last_turn)
                    ~last_turn_ts:last_turn;
                  last_broadcast_ts := now
                with
                | Eio.Cancel.Cancelled _ as e -> raise e
                | exn ->
                  Log.Keeper.warn
                    "%s: stale broadcast emit failed (restart still triggered): %s"
                    meta.name (Printexc.to_string exn))
             end
           | None ->
             Log.Keeper.warn "%s: watchdog: registry entry NOT FOUND" meta.name
           | Some entry ->
             Log.Keeper.info
               "%s: watchdog: phase=%s (not Running, skipping)"
               meta.name
               (Keeper_state_machine.phase_to_string entry.phase)
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           Log.Keeper.warn
             "%s: stale watchdog tick failed (suppressed): %s"
             meta.name (Printexc.to_string exn));
        (try Eio.Time.sleep ctx.clock (watchdog_poll_sec ()) with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | _ -> ());
        watchdog_loop ()
      end
    in
    try watchdog_loop ()
    with Eio.Cancel.Cancelled _ -> ())
