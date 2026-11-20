(** Fiber + fair-yield helpers for the server bootstrap loops. *)

val fork_logged_fiber
  :  sw:Eio.Switch.t
  -> on_error:(exn -> unit)
  -> (unit -> unit)
  -> unit

val log_server_fiber_crash : string -> exn -> unit
val log_dashboard_fiber_crash : string -> exn -> unit

(** [run_steps ~on_error steps] runs the named steps in order. An exception a
    step raises is that step's failure: [on_error name exn] is called and the
    steps after it still run. Cancellation and the runtime's reserved
    exceptions ({!Llm_provider.Reserved_exn}) are raised again. *)
val run_steps : on_error:(string -> exn -> unit) -> (string * (unit -> unit)) list -> unit

(** [log_server_step_failure loop name exn] prints the failed step of [loop]
    to the [Log.Server] stream. *)
val log_server_step_failure : string -> string -> exn -> unit

val filteri_with_fair_yield : (int -> 'a -> bool) -> 'a list -> 'a list
