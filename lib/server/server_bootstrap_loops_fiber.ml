(** Fiber + fair-yield helpers for the server bootstrap loops.

    [fork_logged_fiber] forks under a switch and routes non-cancel
    exceptions through an [on_error] handler so a single crashed
    fiber does not propagate up to the switch and cancel sibling
    work. [Eio.Cancel.Cancelled] is re-raised unchanged because the
    switch may need to honor cancellation.

    [log_server_fiber_crash] / [log_dashboard_fiber_crash] are the
    two standard [on_error] adapters that print a fiber-crash line
    to the [Log.Server] / [Log.Dashboard] streams.

    [filteri_with_fair_yield] / [iteri_with_fair_yield] iterate a
    list while inserting [Eio_guard.yield_step] calls every element,
    so a long-list iteration cannot starve other fibers on the
    domain.

    Pure (modulo Eio fiber scheduling + Log emit). All callers are
    internal to [Server_bootstrap_loops]. *)

let fork_logged_fiber ~sw ~on_error run =
  Eio.Fiber.fork ~sw (fun () ->
    try run () with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn -> on_error exn)
;;

let log_server_fiber_crash name exn =
  Log.Server.error "%s fiber crashed: %s" name (Printexc.to_string exn)
;;

let log_dashboard_fiber_crash name exn =
  Log.Dashboard.error "%s fiber crashed: %s" name (Printexc.to_string exn)
;;

let filteri_with_fair_yield f xs =
  let meter = Eio_guard.create_yield_meter ~interval:1 () in
  List.filteri
    (fun idx item ->
       let keep = f idx item in
       Eio_guard.yield_step meter;
       keep)
    xs
;;

let iteri_with_fair_yield f xs =
  let meter = Eio_guard.create_yield_meter ~interval:1 () in
  List.iteri
    (fun idx item ->
       f idx item;
       Eio_guard.yield_step meter)
    xs
;;
