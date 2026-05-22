(** Shell word helpers for worker path and transparent-wrapper policy. *)
val command_after_env_prefix : string list -> string option
(** Resolve the effective command name from argv words following an [env]
    executable. Environment assignments and supported env options are skipped;
    transparent nested wrappers are resolved recursively. *)

val opam_exec_command_name : string list -> string option
(** Resolve the effective command name for argv words following an [opam]
    executable. [opam exec] targets are resolved recursively; non-exec opam
    subcommands resolve to [Some "opam"]. *)
