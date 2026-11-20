(** Session termination journal written once to the redirected per-PID log. *)

exception Break
(** Local control-flow exception for leaving the main TUI loop through one
    clean shutdown path. *)

val note : Masc_tui_exit_reason.t -> unit
(** Record the first termination reason observed for this process. Subsequent
    calls preserve the initial cause. *)

val write_once : unit -> unit
(** Flush at most one exit summary line to [stderr] after terminal restoration. *)

val signal_name : int -> string
(** Human-readable label for a POSIX termination signal. *)
