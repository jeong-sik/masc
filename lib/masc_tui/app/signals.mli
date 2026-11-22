(** POSIX signal router feeding {!Wake_bell} with guaranteed handler restoration
    on [Eio.Switch.on_release].

    Installs handlers for [SIGWINCH], [SIGINT], [SIGTERM], [SIGHUP], [SIGCONT],
    and ignores [SIGPIPE]. Signal callbacks allocate zero heap memory and touch
    only pre-allocated values and {!Atomic.t} cells. *)

open Masc_tui_core

type exit_verdict =
  | Continue
  | Interrupt_armed
  | Interrupt_confirmed
  | Terminate of string

val equal_exit_verdict : exit_verdict -> exit_verdict -> bool

type t

val create : bell:Wake_bell.t -> t

val install : sw:Eio.Switch.t -> t -> unit
(** Install POSIX handlers for [SIGWINCH], [SIGINT], [SIGTERM], [SIGHUP],
    [SIGCONT], and [SIGPIPE] ([Signal_ignore]), registering reverse-order
    restoration of all previous behaviors on [Eio.Switch.on_release sw]. *)

val record_resize : t -> unit
(** Record a window resize / resume event and ring {!Wake_bell.Resize}. *)

val record_interrupt : t -> unit
(** Record a [SIGINT] interrupt and ring {!Wake_bell.Interrupt}. *)

val record_terminate : t -> signal:string -> unit
(** Record a termination signal (e.g. ["SIGTERM"], ["SIGHUP"]) and ring
    {!Wake_bell.Terminate}. *)

val poll_exit : t -> exit_verdict
(** Consume pending interrupt/terminate flags into a single loop decision.
    A first [SIGINT] arms termination ({!Interrupt_armed}); a second [SIGINT]
    before {!withdraw_interrupt} confirms exit ({!Interrupt_confirmed}).
    [SIGTERM]/[SIGHUP] always produce {!Terminate} immediately. *)

val withdraw_interrupt : t -> unit
(** Disarm a pending first [SIGINT] after ordinary operator input. *)

val clear_interrupts : t -> unit
(** Clear both pending and armed [SIGINT] flags (e.g. after returning from an
    interactive [$EDITOR] escape-hatch session where Ctrl-C belonged to the
    child editor) without clearing [SIGTERM]/[SIGHUP]. *)

val resize_generation : t -> int
(** Monotonic counter incremented on every [SIGWINCH] / [SIGCONT]. *)

val terminate_signal : t -> string option
(** [Some name] once a termination signal has been recorded, else [None]. *)

val pending_signal : t -> bool
(** [true] if a termination or unhandled interrupt signal is pending. *)

val exit_reason_of_verdict : exit_verdict -> Exit_reason.t option
(** Project a terminal {!exit_verdict} into {!Exit_reason.t}; [None] for
    {!Continue} and {!Interrupt_armed}. *)
