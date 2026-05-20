(** Shell word helpers for worker path and transparent-wrapper policy. *)

val strip_wrapping_quotes : string -> string

val command_after_env_prefix : string list -> string option
(** Resolve the effective command name from argv words following an [env]
    executable. Environment assignments and supported env options are skipped;
    transparent nested wrappers are resolved recursively. *)

val opam_exec_command_name : string list -> string option
(** Resolve the effective command name for argv words following an [opam]
    executable. [opam exec] targets are resolved recursively; non-exec opam
    subcommands resolve to [Some "opam"]. *)

val segment_command_name : string -> string option
(** Resolve the effective command name of a shell segment, including transparent
    [env] and [opam exec] wrappers. *)

val extract_command_name : string -> string option
(** Return the basename of the first shell token without resolving transparent
    wrappers. Intended for diagnostics when {!segment_command_name} has no
    effective target. *)
