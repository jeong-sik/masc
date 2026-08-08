(** Small env parsing helpers shared by llm_provider modules.

    These helpers intentionally read at call time. They are used for debug/test
    toggles where a process-level env mutation should affect later calls. *)

(** Parse a boolean-ish env value.

    Accepted true values are ["1"], ["true"], ["yes"], and ["on"]. Accepted
    false values are ["0"], ["false"], ["no"], ["off"], and the empty string.
    Matching is case-insensitive after trimming. Unknown values return
    [default], which is [false] unless supplied. *)
val bool_of_string : ?default:bool -> string -> bool

(** Read [name] with [Sys.getenv_opt] and parse it with [bool_of_string]. *)
val bool_env : ?default:bool -> string -> bool

(** Temporarily set [name] while [f] runs, then restore the previous value.

    OCaml 5.5 adds [Unix.unsetenv], but this library still supports the 5.4
    floor. If [name] was absent, this restores it to [""]. The parsers in this
    module treat [""]
    equivalently to an absent value. *)
val with_env : string -> string -> (unit -> 'a) -> 'a
