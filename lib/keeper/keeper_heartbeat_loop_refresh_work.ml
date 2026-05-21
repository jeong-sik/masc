(** Work-as-heartbeat refresher, extracted from
    [keeper_heartbeat_loop.ml] (godfile decomp).

    [refresh_work_as_heartbeat] is the keepalive cycle's
    "implicit heartbeat" path: when the keeper just finished a
    productive turn (`work_as_hb () = true`) and the proactive warmup
    has elapsed, we count any successful Coord.heartbeat against any
    joined room as evidence that the keeper is alive — and reset the
    consecutive-failure counter accordingly.

    Per-room failure logging is at DEBUG (not WARN) because the
    *any-success* aggregation policy means a single live room is
    sufficient; transient per-room misses are expected during room
    rebalance and shouldn't pollute the WARN stream.

    Cancellation re-raises (preserves Eio cancellation semantics).
    All other exceptions degrade to a per-room `false` result.

    Pure helper move — no callback injection, no parent-local
    dependencies. *)

open Keeper_types

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
               (Coord.heartbeat ctx.config ~agent_name:meta_after_proactive.agent_name);
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
