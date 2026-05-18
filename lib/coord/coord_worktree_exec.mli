(** Argv-only exec helpers shared by the coord_worktree subsystem.  Wraps
    [Masc_exec.Exec_gate.run_argv*] with a pinned actor tag and audit
    summary so every git plumbing call surfaces a consistent trail. *)

val exec_gate_raw_source : string list -> string
(** Render [argv] as a quoted shell-string for the audit/raw_source field;
    never executed as a shell command. *)

val run_argv_lines : string list -> string list
(** Run [argv] (no shell) and return non-empty stdout lines. *)

val run_argv_with_status :
  ?timeout_sec:float -> string list -> Unix.process_status * string
(** Run [argv] and return [(status, combined_output)]. *)

val run_argv_exit : ?timeout_sec:float -> string list -> int
(** Run [argv] and return the exit code (128 for signaled/stopped). *)

val first_nonempty_line : string -> string option
(** First non-empty trimmed line from [output], or [None] if every line is
    blank. *)
