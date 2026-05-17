(** Executable allowlists for keeper-driven dev/shell tools.

    Extracted from [Worker_dev_tools] under RFC-0091 PR-1 (§5.1.2).
    The allowlists are *string equality* membership tables only —
    no shell parsing, no metacharacter scanning, no quoting analysis.
    Those responsibilities move to {!Keeper_tool_bash_input} (typed
    schema) in subsequent PR-1 commits and disappear entirely in
    PR-2 when the legacy lexer is deleted.

    See: docs/rfc/RFC-0091-keeper-bash-typed-argv.md *)

val dev : string list
(** Executables permitted for full dev presets (Coding/Full).
    Used by [Worker_dev_tools] when dispatching keeper_bash for
    keepers with elevated dev capability. *)

val readonly : string list
(** Read-only executable subset. Used for keepers without write
    capability, and as the base allowlist for path-bearing
    commands. Strict subset of {!dev}. *)

val is_dev_allowed : string -> bool
(** [is_dev_allowed name] is [List.mem name dev]. *)

val is_readonly_allowed : string -> bool
(** [is_readonly_allowed name] is [List.mem name readonly]. *)
