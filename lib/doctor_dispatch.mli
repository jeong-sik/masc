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

(** Resolve the python interpreter, honouring [MASC_PYTHON] env override,
    defaulting to ["python3"]. *)
val python_bin : unit -> string

(** [capture_sidecar_json name] spawns [python -m src doctor --json] inside
    the sidecar's directory and captures its stdout verbatim. Returns
    [(payload, exit_code)] on success, or an explanatory string in [Error]
    for pre-spawn failures (unknown sidecar name, missing directory,
    subprocess crash). Used by [doctor all --json] to assemble an envelope
    of all doctor outputs without losing the raw per-doctor JSON shape. *)
val capture_sidecar_json : string -> (string * int, string) result
