(** Keeper_identity — Trace ID generation and git author/committer identity
    for keeper operations.

    Consolidates trace_id generation, session_id conventions, and
    git identity so that commits made by keepers are properly attributed.

    Identity patterns follow [config/tool_policy.toml] section
    [keeper_identity].  When config is not loaded, uses default patterns.

    @since 2.162.0 — #3721 keeper stabilization (trace_id)
    @since 2.254.0 — git identity for keeper operations *)

val generate_trace_id : unit -> string
(** Generate a new trace ID. Used at keeper creation and handoff rollover.
    Format: [trace-<epoch_ms>-<5hex>]. *)

val keeper_git_author : keeper_name:string -> string
(** Return the git author name for a keeper.
    Default pattern: ["{keeper_name} (MASC Keeper)"].
    The keeper name is sanitized to [A-Za-z0-9._-]. *)

val keeper_git_email : keeper_name:string -> string
(** Return the git email for a keeper.
    Default pattern: ["{keeper_name}\@masc.local"].
    The keeper name is sanitized to [A-Za-z0-9._-]. *)

val git_env_for_keeper : keeper_name:string -> string array
(** Return environment variable array suitable for
    [Process_eio.run_argv_with_status ~env].
    Sets GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL, GIT_COMMITTER_NAME,
    GIT_COMMITTER_EMAIL.  Inherits all other env vars from the
    current process. *)
