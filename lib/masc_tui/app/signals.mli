(** POSIX signal router feeding {!Wake_bell} with guaranteed handler restoration
    on [Eio.Switch.on_release].

    Installs handlers for [SIGWINCH], [SIGINT], [SIGTERM], [SIGHUP], [SIGCONT],
    catches [SIGTSTP] safely while raw mode is active (suspended/resumed around
    [$EDITOR] handoffs via {!suspend_sigtstp_guard}/{!resume_sigtstp_guard}),
    and ignores [SIGPIPE]. Signal callbacks allocate zero heap memory and touch only pre-allocated values and
    {!Atomic.t} cells. *)

open Masc_tui_core

val interrupt_arm_window_s : float
(** Duration ([3.0] s) for which a first [SIGINT] stays armed waiting for a
    confirming second [SIGINT], matching the quit-warning toast window. *)

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
    [SIGCONT], [SIGTSTP], and [SIGPIPE] ([Signal_ignore]), registering
    reverse-order restoration of all previous behaviors on
    [Eio.Switch.on_release sw]. *)

val suspend_sigtstp_guard : t -> unit
(** Temporarily restore the saved prior [SIGTSTP] disposition while handing the
    restored terminal off to an interactive [$EDITOR] child process so [Ctrl+Z]
    suspends the entire foreground process group cleanly instead of deadlocking
    [system(3)]'s [waitpid]. Safe no-op if uninstalled or already suspended. *)

val resume_sigtstp_guard : t -> unit
(** Re-install the zero-alloc [SIGTSTP] guard immediately before re-entering raw
    mode after [$EDITOR] returns. Safe no-op if uninstalled or already guarded. *)

val is_sigtstp_guarded : t -> bool
(** [true] iff [SIGTSTP] is currently caught by the TUI safety guard. *)

val record_resize : t -> unit
(** Record a window resize / resume event and ring {!Wake_bell.Resize}. *)

val record_interrupt : t -> unit
(** Record a [SIGINT] interrupt and ring {!Wake_bell.Interrupt}. *)

val record_terminate : t -> signal:string -> unit
(** Record a termination signal (e.g. ["SIGTERM"], ["SIGHUP"]) and ring
    {!Wake_bell.Terminate}. *)

val poll_exit : ?now:Clock.Mono.t -> t -> exit_verdict
(** Consume pending interrupt/terminate flags into a single loop decision.
    A first [SIGINT] arms termination ({!Interrupt_armed}) for
    {!interrupt_arm_window_s}; a second [SIGINT] before expiry or
    {!withdraw_interrupt} confirms exit ({!Interrupt_confirmed}).
    [SIGTERM]/[SIGHUP] always produce {!Terminate} immediately. *)

val expire_interrupt : now:Clock.Mono.t -> t -> bool
(** Expire an armed first [SIGINT] once [now] reaches or passes its deadline.
    Returns [true] iff an armed state expired. *)

val is_interrupt_armed : ?now:Clock.Mono.t -> t -> bool
(** [true] iff a first [SIGINT] is currently armed and unexpired at [now]. *)

val interrupt_armed_deadline : t -> Clock.Mono.t option
(** Monotonic deadline at which a currently armed [SIGINT] expires, or [None]
    when disarmed. *)

val withdraw_interrupt : t -> unit
(** Disarm a pending first [SIGINT] after ordinary operator input (key, paste,
    or mouse). *)

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
