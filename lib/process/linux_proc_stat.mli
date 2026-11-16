(** One process's line in Linux's [/proc/<pid>/stat] (proc(5)).

    The line starts "pid (comm) state ppid pgrp ...". The command name sits
    in parentheses and may hold spaces and [')'] itself, so every caller that
    wants a field after it has to find the last [')'] first. Field 3 of
    proc(5), the state, is the head of the list both functions return. *)

val parse : string -> string list option
(** The fields after the command name in one stat line: state, ppid, pgrp
    and on. [None] when the line holds no [')']. *)

val read : int -> string list option
(** {!parse} of [/proc/<pid>/stat]. [None] when that file cannot be read --
    no process numbered [pid], or no [/proc], which is every platform but
    Linux -- or when it does not parse. *)
