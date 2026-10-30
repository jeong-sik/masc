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

let is_internal_race_cancel exn =
  match exn with
  | Eio.Cancel.Cancelled _ ->
      let msg = Printexc.to_string exn in
      String.equal msg "Cancelled: Eio__core__Fiber.Not_first"
      || String.ends_with ~suffix:"Eio__core__Fiber.Not_first" msg
  | _ -> false
