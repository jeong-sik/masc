(** Work-as-heartbeat refresher, extracted from
    [keeper_heartbeat_loop.ml] (godfile decomp).

    [refresh_work_as_heartbeat] is the keepalive cycle's
    "implicit heartbeat" path: when the keeper just finished a
    productive turn (`work_as_hb () = true`) and the proactive warmup
    has elapsed, we count any successful Workspace.heartbeat against any
    session-bound workspace as evidence that the keeper is alive — and reset the
    consecutive-failure counter accordingly.

    Per-workspace failure logging is at DEBUG (not WARN) because the
    *any-success* aggregation policy means a single live workspace is
    sufficient; transient per-workspace misses are expected during workspace
    rebalance and shouldn't pollute the WARN stream.

    Cancellation re-raises (preserves Eio cancellation semantics).
    All other exceptions degrade to a per-workspace `false` result.

    Pure helper move — no callback injection, no parent-local
    dependencies. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

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
      try
        (* fire-and-forget: heartbeat persistence is enough; loop records only success/failure. *)
        ignore (Workspace.heartbeat ctx.config ~agent_name:meta_after_proactive.agent_name);
        true
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Log.Keeper.debug
          "heartbeat failed for %s: %s"
          meta_after_proactive.name
          (Printexc.to_string exn);
        false
    in
    if hb_ok
    then (
      last_successful_heartbeat_ts := Time_compat.now ();
      consecutive_failures := 0))
;;
