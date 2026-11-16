(** How the end of a child process reads in a sentence for the operator.

    [Unix.process_status] and Eio's [`Signaled] carry OCaml's own signal
    numbers ([Sys.sigkill] is -7), which no operator can look up. This module
    names them. It depends on nothing else in this library, so every module
    here can use it, [Posix_spawn_detached] included. *)

val signal_name : int -> string
(** The name of a signal in OCaml's numbering, such as ["SIGTERM"] for
    [Sys.sigterm]. A signal the runtime does not name arrives as the host's
    positive number and reads ["signal N"]. *)

val of_status : Unix.process_status -> string
(** ["exited with status N"], ["was killed by SIGKILL"] or
    ["was stopped by SIGTSTP"]: the predicate of a sentence whose subject is
    the process. *)
