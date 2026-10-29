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

val request_terminate : t -> signal:string -> unit
(** SIGTERM, SIGHUP, SIGQUIT: the session is over. [signal] is the name the
    exit line writes down, so a day of ends can be read by cause. One atomic
    store each, so it is safe from a handler. Stays set: a terminate is never
    withdrawn. *)

val terminate_signal : t -> string option
(** The name of the signal that requested the terminate, or [None] when none
    did. Read after {!poll} returns [Quit] to record the cause. *)

val request_interrupt : t -> unit
(** SIGINT: asks the loop what a Ctrl-C means this time. One atomic store. *)

val interrupt_pending : t -> bool
(** Observe an interrupt without consuming it, including immediately after
    frame output when deciding whether a confirmation can become active. *)

val withdraw_interrupt : t -> unit
(** Any deliberate input: a standing Ctrl-C no longer counts toward a double
    press, so a Ctrl-C typed minutes after another does not read as one. *)

type verdict =
  | Continue
  | Interrupt_armed
      (** A first Ctrl-C: tell the operator what a second one will do. *)
  | Interrupt_again
      (** A second Ctrl-C; the caller still checks the displayed confirmation. *)
  | Quit
      (** An explicit terminate request. *)

val poll : t -> verdict
(** Once per loop pass. Consumes an interrupt request and arms the next one;
    a terminate request outranks both and is never consumed. *)
