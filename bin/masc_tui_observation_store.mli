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
type admission_outcome = Capture_returned | Capture_failed of string
type admission_capture = private {
  capture_started_ns : int64;
  capture_returned_ns : int64;
  capture_outcome : admission_outcome;
}
val admission_capture_to_json : admission_capture option -> Yojson.Safe.t
(** [None] means no configured store was attempted, not capture success. A
    receipt exposes its outcome and clocks without copying filesystem error
    text into routine Info events. The original Warn diagnostic retains it. *)
val record_admission :
  t -> origin:Masc_tui_observation_origin.t -> request:int ->
  admission_started_ns:int64 -> admission_capture
(** Append the original admitted identity before dispatch, independently of
    logger severity, through Fs_compat's serialized JSONL append/flush backend.
    Return an immutable receipt for both normal return and expected filesystem
    failure. No question/answer body or producer/UI outcome is stored.

    Clocks bracket payload/append through expected error conversion, before
    lazy warning formatting/output. A normal return means append/flush returned;
    failure does not prove write/flush was reached or completed. Neither is fsync,
    exhaustive capture, worker exit, visible UI or Task progress. These two
    synchronous clock reads and capture/logging costs remain inside original
    admission-to-start/worker/UI intervals.

    Expected failures also emit the existing best-effort Startup Warn/Boundary
    fact with original provenance, identity, failed span and opaque explanation.
    Existing severity/redaction/sinks apply; no extra successful-write event or
    flush is added. Cancellation and unexpected exceptions propagate. *)
