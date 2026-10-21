(** Process-owned structured TUI log storage. The directory is independent of
    server daily logs and of any later server/workspace identity replacement. *)
val initialize : base_path:string -> (string, string) result
(** Create a private, unique session directory below the opening local base's
    [.masc/logs/tui], then bind the existing Log.Ring daily JSONL sink there.
    Returns its directory, or an expected filesystem failure explanation.
    Both outcomes record a typed initialization event with clocks spanning
    directory/sink setup. Logging policy, redaction and flush remain Log's.

    Call once after stderr redirection and log-level initialization, before TUI
    state/read producers. This performs synchronous filesystem setup. Expected
    filesystem failure is best effort: the caller may continue with the ring
    and existing console mirror. Unexpected errors and Eio cancellation propagate.
    The process owns the existing sink channel until exit. A returned path is
    initialization evidence, not fsync, complete log coverage or runtime proof. *)
