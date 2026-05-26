(** Executable allowlists for keeper-driven dev/shell tools.

    The source of truth is typed {!Masc_exec.Exec_program.known} values; the string
    lists below are derived compatibility surfaces for gate APIs that still
    perform string equality membership checks. This keeps executable
    vocabulary owned by [Exec_program] instead of maintaining a parallel raw string
    table here.

    These allowlists do no shell parsing, metacharacter scanning, or quoting
    analysis. Those responsibilities belong to {!Agent_tool_execute_typed_input} and
    the Shell IR gate/dispatch pipeline.

    See: docs/rfc/RFC-0091-execute-typed-argv.md *)

val dev_programs : Masc_exec.Exec_program.known list
(** Typed executable vocabulary for full dev presets. *)

val dev : string list
(** [List.map Masc_exec.Exec_program.name_of_known dev_programs]. Executables permitted for
    write/execute-capable presets. Used by [Worker_dev_tools] when dispatching
    Execute for keepers with elevated dev capability. *)

val readonly_programs : Masc_exec.Exec_program.known list
(** Typed executable vocabulary for read-only presets. *)

val readonly : string list
(** [List.map Masc_exec.Exec_program.name_of_known readonly_programs]. Read-only executable
    subset. Used for keepers without write capability, and as the base
    allowlist for path-bearing commands. Strict subset of {!dev}. *)

val is_dev_allowed : string -> bool
(** [is_dev_allowed name] is [List.mem name dev]. *)

val is_readonly_allowed : string -> bool
(** [is_readonly_allowed name] is [List.mem name readonly]. *)
