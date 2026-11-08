(** Cancel_safe — exception-safe callback wrapper for Eio fibers.

    [observe] runs [f ()] and catches all exceptions except
    [Eio.Cancel.Cancelled] (which must propagate to honor cooperative
    cancellation). All other exceptions are routed to [on_exn] instead
    of propagating to the caller. The caller owns any logging, metrics,
    or durable failure record required by its boundary. *)

let protect ~on_exn f =
  try f ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> on_exn exn

let observe ~on_exn f = protect ~on_exn f

(* A cancellation context, once cancelled, stays cancelled.  So when the
   handling fiber's own context is still live, the [Cancelled] it holds cannot
   have come from that context or any ancestor: it came from a sub-context
   below it — the one [Eio.Fiber.first] / [Fiber.any] creates and cancels
   when another branch wins.  This is the same test Eio's [any_gen] applies
   to decide whether to swallow a loser's cancellation ([not (Cancel.is_on
   cc)]), without naming the private [Fiber.Not_first] payload or reading
   its rendering (#49742). *)
let is_internal_race_cancel exn =
  match exn with
  | Eio.Cancel.Cancelled _ -> not (Eio.Fiber.is_cancelled ())
  | _ -> false
