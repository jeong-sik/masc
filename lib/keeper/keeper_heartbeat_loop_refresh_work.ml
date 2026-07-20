(** Work-as-heartbeat refresher, extracted from
    [keeper_heartbeat_loop.ml] (godfile decomp).

    [refresh_work_as_heartbeat] is the keepalive cycle's post-turn heartbeat
    path: when enabled and proactive warmup has elapsed, it calls
    [Workspace.heartbeat] for [ctx.config]. Success resets the consecutive
    failure counter. Failure is debug-logged and leaves the counter unchanged.

    Cancellation re-raises (preserves Eio cancellation semantics).
    All other exceptions become an observed heartbeat failure.

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
      ~(consecutive_failures : int ref)
  : unit
  =
  if work_as_hb () && proactive_warmup_elapsed
  then (
    let hb_ok =
      try
        (* Heartbeat persistence is enough; the loop records only success/failure. *)
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
    then consecutive_failures := 0)
;;
