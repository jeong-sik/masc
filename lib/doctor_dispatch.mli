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

(** [aggregate_exit_code rcs] collapses a list of doctor exit codes into a
    single one, preserving the [error > warn > ok] priority used by every
    Doctor renderer (ok=0, warn=1, error=2, anything else treated as at
    least error=2). Empty list returns 0 (nothing ran → nothing to report). *)
val aggregate_exit_code : int list -> int
