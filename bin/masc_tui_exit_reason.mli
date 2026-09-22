(** Why a TUI session ended, in the one place that names it.

    The per-PID stderr log held only the boot lines, so a session that ended
    left no reason behind: the operator saw roughly a hundred files a day and
    none said why. This is the vocabulary the exit line is written in, and the
    split the line carries -- a normal end is the operator or the session's
    owner asking for it, an abnormal one is the surface leaving without being
    asked. Apart from the loop so the vocabulary runs under a test with no
    terminal and no signal delivery. *)

type t =
  | Quit_key  (** q, Q, or Ctrl-Q: the operator asked to leave. *)
  | Interrupt  (** A second Ctrl-C while the first still stood. *)
  | Terminate of string
      (** SIGTERM, SIGHUP, SIGQUIT: the session was told to end. *)
  | Exception of string  (** An uncaught exception left the loop. *)

val label : t -> string
(** The cause alone, without the normal/abnormal split. *)

val is_normal : t -> bool
(** [true] when the operator or the session's owner ended it on purpose. *)

val line : t -> string
(** The one line written to the exit log, e.g. ["exit: normal (quit key)"]. A
    detail carrying a control byte is flattened to one row first, because the
    log is read a line at a time. *)
