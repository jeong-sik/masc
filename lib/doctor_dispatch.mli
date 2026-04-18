(** Doctor dispatch: maps a sidecar name to its source directory.

    Used by [masc-mcp doctor sidecar <name>] to resolve which directory to
    invoke [python -m src doctor] in. Kept pure and separate from the CLI
    binary so it can be unit-tested without spawning subprocesses. *)

(** Canonical list of known sidecar names. *)
val known_sidecars : string list

(** [sidecar_dir name] returns the relative directory (repo-root relative)
    where [python -m src doctor] should be executed for the sidecar, or
    [None] when [name] is not a recognised sidecar. *)
val sidecar_dir : string -> string option

(** Human-readable summary listing the known sidecar names, suitable for
    error output when an unknown name is supplied. *)
val known_summary : string
