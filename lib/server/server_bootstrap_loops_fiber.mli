(** Fiber + fair-yield helpers for the server bootstrap loops. *)

val fork_logged_fiber
  :  sw:Eio.Switch.t
  -> on_error:(exn -> unit)
  -> (unit -> unit)
  -> unit

val log_server_fiber_crash : string -> exn -> unit
val log_dashboard_fiber_crash : string -> exn -> unit

val filteri_with_fair_yield : (int -> 'a -> bool) -> 'a list -> 'a list
val iteri_with_fair_yield : (int -> 'a -> unit) -> 'a list -> unit
