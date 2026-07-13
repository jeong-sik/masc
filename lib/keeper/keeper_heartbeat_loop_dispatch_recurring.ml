(** Recurring-task keepalive dispatch, extracted from
    [keeper_heartbeat_loop.ml] (godfile decomp).

    Per heartbeat cycle, attempts to:

    1. Dispatch all due tasks via [Keeper_recurring.dispatch_due],
       broadcasting each via [Workspace.broadcast] tagged
       [\[loop:<label>\] <msg>]. Per-task broadcast failures tick
       [metric_keeper_recurring_failures] with [phase="task_execution"]
       and surface as [Error] in the inner result. The outer try/with
       catches dispatch-loop errors and ticks the same metric with
       [phase="dispatch_error"].

    Returns the count of tasks dispatched (or 0 on dispatch-loop failure).
    Cancellation re-raises. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

let dispatch_recurring_keepalive
      ~(ctx : _ context)
      ~(meta_after_proactive : keeper_meta)
      ~(now_ts : float)
  : int
  =
  try
    Keeper_recurring.dispatch_due
      ~keeper_name:meta_after_proactive.name
      ~now_ts
      ~dispatch:(fun task action ->
        match action with
        | Keeper_recurring.Broadcast msg ->
          (try
             let _ =
               Workspace.broadcast
                 ctx.config
                 ~from_agent:meta_after_proactive.agent_name
                 ~content:(Printf.sprintf "[loop:%s] %s" task.label msg)
             in
             Log.Keeper.info "[recurring] %s dispatched: %s" task.id task.label;
             Ok ()
           with
           | exn ->
             Log.Keeper.warn "[recurring] %s failed: %s" task.id (Printexc.to_string exn);
             Otel_metric_store.inc_counter
               Keeper_metrics.(to_string RecurringFailures)
               ~labels:[ "task", task.id; "phase", "task_execution" ]
               ();
             Error (Printexc.to_string exn)))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.warn "[recurring] dispatch error: %s" (Printexc.to_string exn);
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string RecurringFailures)
      ~labels:[ "task", "dispatch"; "phase", "dispatch_error" ]
      ();
    0
;;
