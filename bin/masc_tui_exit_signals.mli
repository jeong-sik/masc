(** The process signals that can end a session, and what the loop makes of
    them once per pass.

    A signal handler runs at the next poll point, inside whatever the loop was
    doing -- an Eio wait included -- so it cannot raise [Break] itself. It used
    to call [exit] instead, which runs the [at_exit] terminal restore and
    nothing else: the switch release that stops a server this TUI started
    never ran, and whether that server outlived the session depended on which
    key ended it. So a handler only records here, and the loop reads the
    record where it decides what to do next. [Quit] leaves the loop the way
    the q key does, through [Break], and every way out then shares one
    shutdown.

    Apart from the loop so the rule runs under a test with no terminal and no
    signal delivery. *)

type t

val create : unit -> t

val request_terminate : t -> unit
(** SIGTERM, SIGHUP, SIGQUIT: the session is over. One atomic store, so it is
    safe from a handler. Stays set: a terminate is never withdrawn. *)

val request_interrupt : t -> unit
(** SIGINT: asks the loop what a Ctrl-C means this time. One atomic store. *)

val withdraw_interrupt : t -> unit
(** Any deliberate input: a standing Ctrl-C no longer counts toward a double
    press, so a Ctrl-C typed minutes after another does not read as one. *)

type verdict =
  | Continue
  | Interrupt_armed
      (** A first Ctrl-C: tell the operator what a second one will do. *)
  | Quit
      (** A terminate request, or a second Ctrl-C while the first still
          stands. *)

val poll : t -> verdict
(** Once per loop pass. Consumes an interrupt request and arms the next one;
    a terminate request outranks both and is never consumed. *)

val quit_notice : key:string -> waiting:int -> string
(** What the first quit key -- [q], or Ctrl-C -- says it will do.

    A message sent while a turn is running waits in this process until that
    turn settles; it is not at the server yet. Quitting drops it, and nothing
    brings it back on the next launch. So a notice with [waiting] above zero
    names how many a second press drops. Continuous voice mode with
    send_on_stop queues a sentence this way each time one ends mid-turn. *)
