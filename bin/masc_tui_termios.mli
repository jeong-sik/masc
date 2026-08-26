(** Terminal settings this program needs that [Unix.terminal_io] cannot state.

    The record [Unix.tcsetattr] takes has no IEXTEN field and no c_cc array, so
    a key the tty layer claims for itself cannot be reclaimed through it -- and
    cannot be handed back through it either. That is not a gap worth a whole
    termios binding: it is one key, taken at session start and returned at the
    end. *)

val disable_literal_next : Unix.file_descr -> bool
(** Turn off the literal-next key (VLNEXT, Ctrl-V by default) on [fd] so
    Ctrl-V arrives as the byte [\x16] instead of being consumed by the tty
    layer, which otherwise passes the byte *after* it through uninterpreted.

    [false] when [fd] is not a terminal or the kernel refused: the key stays
    swallowed and nothing else about the terminal changes.

    Call this after every [Unix.tcsetattr], not once at startup. OCaml's
    [tcsetattr] writes a C-side termios buffer and overwrites only the fields
    the record names, so a later call leaves c_cc holding whatever the kernel
    has -- which, once raw mode is re-applied, is this key turned back on. *)

val literal_next : Unix.file_descr -> int
(** The current literal-next character on [fd] as 0..255, or [-1] when [fd] is
    not a terminal.

    Read this before {!disable_literal_next} and give it back with
    {!set_literal_next} at exit. Restoring the [Unix.terminal_io] captured at
    startup does not restore this character -- the record cannot carry it --
    so a session that skipped the pair would hand the operator back a shell
    with no literal-next key. *)

val set_literal_next : Unix.file_descr -> int -> bool
(** Put the literal-next character back. [false] when [fd] is not a terminal
    or the kernel refused. *)
