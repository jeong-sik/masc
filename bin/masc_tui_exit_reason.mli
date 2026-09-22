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
  | Unrecorded
      (** The loop was left without recording a cause. Its own case rather
          than an {!Exception} carrying that sentence: nothing here observed
          an exception, and a row that names one where none was seen sends a
          reader looking for a failure that did not happen. Abnormal all the
          same -- every way out this build has records a cause, so reaching
          this means one stopped doing it. *)

val label : t -> string
(** The cause alone, without the normal/abnormal split. *)

val is_normal : t -> bool
(** [true] when the operator or the session's owner ended it on purpose. *)

val line : t -> string
(** The one line written to the exit log, e.g. ["exit: normal (quit key)"].
    The writer prefixes it with ["[masc-tui] "]; grep for the whole prefix to
    find these rows and nothing else.

    A detail carrying a control byte is flattened to one row first, because
    the log is read a line at a time. A cause longer than 200 bytes is cut on
    a UTF-8 character boundary and the row ends in ["[+N bytes]"], so a reader
    can see that the text continues and by how much. *)
