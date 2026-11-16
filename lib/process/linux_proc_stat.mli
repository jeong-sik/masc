(** One process's line in Linux's [/proc/<pid>/stat] (proc(5)).

    The line starts "pid (comm) state ppid pgrp ...". The command name sits
    in parentheses and may hold spaces and [')'] itself, so the fields are
    counted from the last [')']. *)

type t =
  { state : string  (** Field 3: ["S"], ["R"], ["Z"] for a zombie, and so on. *)
  ; parent : int  (** Field 4, ppid. *)
  ; group : int  (** Field 5, pgrp. *)
  ; start : string  (** Field 22, starttime: clock ticks after boot, as written. *)
  }

val parse : string -> t option
(** [None] when the line holds no [')'], stops before field 22, or holds no
    number where ppid or pgrp stands. *)

val read : int -> string
(** The stat line of process [pid].
    @raise Unix.Unix_error [ENOENT] when [/proc] holds no such process, and
    for every pid when there is no [/proc], which is every platform but
    Linux; [ESRCH] when the process was reaped after its file opened; the
    errno of the refusal when the file would not open or read. *)
