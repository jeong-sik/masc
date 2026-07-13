(** Dashboard_http_tool_quality — operator-facing tool-quality
    aggregation endpoint.

    Reads the keeper tool-call log, classifies failure outputs into
    canonical reason codes, and emits per-tool / per-keeper /
    per-thinking-mode / per-hour rate tables for the
    [/api/v1/dashboard/tool-quality] surface.

    Internal helpers (the [normalize_failure_text] /
    [classify_process_status] text classifiers, the
    [bucket_key] / [thinking_mode_of_record] / [hour_key_of_record]
    record projectors, the [update_rate_table] / [render_rate_table]
    aggregation primitives, the [dashboard_surface] /
    [source_metadata_fields] / [empty_summary] payload builders) are
    hidden — callers consume the entry points only. *)

val classify_failure_output : string -> string
(** Map a raw tool-call failure output (which may carry an
    [error: ] / [tool_error: ] prefix and a JSON envelope) to a
    canonical reason code. Falls back to a normalised free-text
    classification or to ["parse_error"] /
    ["unknown_error"] / ["empty_output"] when nothing matches. *)

val unknown_runtime_profile_bucket : string
(** Bucket emitted by {!aggregate} when a tool-call record carries no
    [runtime_profile] evidence at either the top level or in
    [runtime_contract]. *)

val aggregate :
  ?n:int -> ?window_hours:float -> unit -> Yojson.Safe.t
(** Build the dashboard payload from the most recent [n] keeper
    tool-call log records (default [5000]), optionally narrowed to
    the last [window_hours] hours. The payload includes per-tool /
    per-keeper / per-thinking-mode / per-hour rate tables plus the
    source-metadata envelope and the canonical
    [dashboard_surface] tag. *)
