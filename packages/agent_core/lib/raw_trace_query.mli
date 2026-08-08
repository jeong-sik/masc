(** Read-side operations for raw traces: list runs, read, summarize, validate.

    Extracted from {!Raw_trace} to separate write-path (recording) from
    read-path (query/analysis).  All functions operate on JSONL files
    written by {!Raw_trace} and return structured results.

    @stability Evolving
    @since 0.93.1 *)

(** {1 Run Discovery} *)

(** Extract [run_ref] values from a list of parsed records.
    Groups records by [worker_run_id] and computes [start_seq]/[end_seq]. *)
val run_refs_of_records : path:string -> Raw_trace.record list -> Raw_trace.run_ref list

(** Read all runs from a trace file at [path]. *)
val read_runs : path:string -> unit -> (Raw_trace.run_ref list, Error.sdk_error) result

(** Read all records for a single run. *)
val read_run : Raw_trace.run_ref -> (Raw_trace.record list, Error.sdk_error) result

(** {1 Summarize} *)

(** Produce a summary of a single run (event counts, tool/hook names,
    timestamps, final text and stop reason). *)
val summarize_run : Raw_trace.run_ref -> (Raw_trace.run_summary, Error.sdk_error) result

(** {1 Validate} *)

(** Run structural validation checks on a single run.
    Checks sequence monotonicity, run start/finish presence,
    and tool execution pairing. *)
val validate_run : Raw_trace.run_ref -> (Raw_trace.run_validation, Error.sdk_error) result
