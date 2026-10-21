(** Process-owned structured TUI log storage. The directory is independent of
    server daily logs and of any later server/workspace identity replacement. *)
type t
val initialize : base_path:string -> (t, string) result
(** Create a private, unique session directory below the opening local base's
    [.masc/logs/tui], then bind the existing Log.Ring daily JSONL sink there.
    Creates an empty independent admission journal in the same private session.
    Returns its owner, or an expected filesystem failure explanation.
    Both outcomes record a typed initialization event with clocks spanning
    directory/sink setup. Logging policy, redaction and flush remain Log's.

    Call once after stderr redirection and log-level initialization, before TUI
    state/read producers. This performs synchronous filesystem setup. Expected
    filesystem failure is best effort: the caller may continue with the ring
    and existing console mirror. Unexpected errors and Eio cancellation propagate.
    The process owns the existing sink channel until exit. The returned directory is
    initialization evidence, not fsync, complete log coverage or runtime proof. *)
val directory : t -> string
val admissions_path : t -> string
val record_admission :
  t -> origin:Masc_tui_observation_origin.t -> request:int ->
  admission_started_ns:int64 -> (unit, string) result
(** Append the original admitted read identity before dispatch, independently of
    logger severity. Reuses Fs_compat's serialized JSONL append/flush backend.
    No outcome is inferred and no question/answer body is stored. Filesystem
    failures return Error and emit a best-effort warning; cancellation and
    unexpected exceptions propagate. This synchronous preparation cost belongs
    after the original admission clock, before started/worker observations.
    Flush is not fsync or proof of complete capture after failure/interruption. *)
