(** The terminal's size, read from the tty itself.

    [tput] cannot answer this when its own output is a pipe: it falls back to
    the static terminfo entry, which is 80x24 for most terminals, so a caller
    that captures its output measures the terminfo default instead of the
    window. That is what this replaces. *)

(** [get ()] is [Some (rows, columns)] when one of stdout, stdin, or stderr is
    a terminal that reports a non-zero size, and [None] otherwise. The caller
    owns what happens with [None] -- there is no default here, because a
    guessed size is exactly the failure this module exists to remove. *)
val get : unit -> (int * int) option
