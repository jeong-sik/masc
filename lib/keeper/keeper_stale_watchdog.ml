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

let fork_stale_watchdog
      (ctx : _ context)
      (meta : keeper_meta)
      (reg : Keeper_registry.registry_entry)
  =
  let base_path = ctx.config.base_path in
  let stale_threshold_sec = 300.0 in
  let watchdog_poll_sec = 30.0 in
  let noop_threshold = 3 in
  let last_broadcast_ts = ref 0.0 in
  Eio.Fiber.fork ~sw:ctx.sw (fun () ->
    let rec watchdog_loop () =
      if Atomic.get reg.fiber_stop
      then ()
      else (
        Eio.Fiber.yield ();
        let now = Time_compat.now () in
        (try
           match Keeper_registry.get ~base_path meta.name with
           | Some entry when entry.phase = Keeper_state_machine.Running ->
             let last_turn = entry.meta.runtime.usage.last_turn_ts in
             let idle_stale = last_turn > 0.0 && now -. last_turn > stale_threshold_sec in
             let noop_count = entry.meta.runtime.proactive_rt.consecutive_noop_count in
             let failure_loop = noop_count >= noop_threshold in
             let stale = idle_stale || failure_loop in
             Log.Keeper.info
               "%s: watchdog tick noop=%d idle_stale=%b failure_loop=%b stale=%b \
                last_turn=%.0f"
               meta.name
               noop_count
               idle_stale
               failure_loop
               stale
               last_turn;
             let cooldown_ok =
               !last_broadcast_ts = 0.0 || now -. !last_broadcast_ts > stale_threshold_sec
             in
             if stale && cooldown_ok
             then (
               let reason_desc =
                 if idle_stale
                 then Printf.sprintf "idle %.0fs" (now -. last_turn)
                 else Printf.sprintf "failure-loop noop=%d" noop_count
               in
               Keeper_registry.set_failure_reason
                 ~base_path
                 meta.name
                 (Some (Keeper_registry.Stale_turn_timeout (now -. last_turn)));
               Atomic.set reg.fiber_stop true;
               Log.Keeper.error
                 "%s: stale watchdog terminating fiber (%s)"
                 meta.name
                 reason_desc;
               try
                 Keeper_execution_receipt.emit_stale_keeper_broadcast
                   ctx.config
                   ~keeper_name:meta.name
                   ~agent_name:meta.agent_name
                   ~trace_id:(Keeper_id.Trace_id.to_string entry.meta.runtime.trace_id)
                   ~generation:entry.meta.runtime.generation
                   ~stale_seconds:(now -. last_turn)
                   ~last_turn_ts:last_turn;
                 last_broadcast_ts := now
               with
               | Eio.Cancel.Cancelled _ as e -> raise e
               | exn ->
                 Log.Keeper.warn
                   "%s: stale broadcast emit failed (restart still triggered): %s"
                   meta.name
                   (Printexc.to_string exn))
           | None -> Log.Keeper.warn "%s: watchdog: registry entry NOT FOUND" meta.name
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
             meta.name
             (Printexc.to_string exn));
        (try Eio.Time.sleep ctx.clock watchdog_poll_sec with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | _ -> ());
        watchdog_loop ())
    in
    try watchdog_loop () with
    | Eio.Cancel.Cancelled _ -> ())
;;
