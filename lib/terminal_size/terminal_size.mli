(** The terminal's size, read from the tty itself.

    [tput] cannot answer this when its own output is a pipe: it falls back to
    the static terminfo entry, which is 80x24 for most terminals, so a caller
    that captures its output measures the terminfo default instead of the
    window. That is what this replaces. *)

(** [get ()] is [Some (rows, columns)] when stdout, stdin, stderr, or the
    controlling terminal at /dev/tty reports a non-zero size, and [None]
    otherwise. /dev/tty is last and is what answers a process whose three
    standard descriptors are all redirected.

    The caller owns what happens with [None] -- there is no default here,
    because a guessed size is exactly the failure this module exists to
    remove. *)
val get : unit -> (int * int) option
