(** Trajectory — Tool call recording for keeper sessions.

    Tracks exact tool-call observations per turn and persists them as JSONL for
    post-hoc analysis. Model usage and cost are observed from OAS inference
    facts; Trajectory does not estimate either from Tool names. *)

(** {1 Types} *)

type tool_call_outcome =
  | Tool_succeeded of string
  | Tool_failed of string

type tool_call_entry = private {
  ts : float;
  ts_iso : string;
  turn : int;
  round : int;
  tool_name : string;
  arguments : (string * Yojson.Safe.t) list;
      (** Structured Tool arguments. The association-list type makes the JSON
          object invariant explicit and prevents a parallel string form. *)
  outcome : tool_call_outcome;
  duration_ms : int;
  execution_id : string;
      (** RFC-0233 canonical join key shared with the tool_calls JSONL row
          for the same execution. Rows without this identity are rejected by
          the closed codec rather than matched heuristically. *)
}

type invalid_entry_counts = {
  missing_required_field : int;
  invalid_field : int;
  unexpected_field : int;
  duplicate_field : int;
  unsupported_row_type : int;
  malformed_json : int;
}

type entry_decode_summary = {
  invalid_entry_count : int;
  invalid_reasons : invalid_entry_counts;
}

type trajectory_read_error = {
  path : string;
  message : string;
}

type entries_read_result = {
  entries : tool_call_entry list;
  decode : entry_decode_summary;
  io_errors : trajectory_read_error list;
}

type entry_field =
  | Row_type
  | Timestamp
  | Timestamp_iso
  | Turn
  | Round
  | Tool_name
  | Arguments
  | Tool_outcome
  | Duration_ms
  | Execution_id
  | Block_index
  | Thinking_block

type entry_decode_error =
  | Missing_required_field of entry_field
  | Invalid_field of entry_field
  | Unexpected_field of string
  | Duplicate_field of string
  | Unsupported_row_type of string
  | Malformed_json

type tool_call_entry_decode =
  | Decoded_entry of tool_call_entry
  | Non_entry_row
  | Invalid_entry of entry_decode_error

val entry_decode_error_to_string : entry_decode_error -> string

val make_tool_call_entry :
  ts:float ->
  ts_iso:string ->
  turn:int ->
  round:int ->
  tool_name:string ->
  arguments:(string * Yojson.Safe.t) list ->
  outcome:tool_call_outcome ->
  duration_ms:int ->
  execution_id:string ->
  (tool_call_entry, entry_decode_error) result
(** Construct a canonical Tool observation. Invalid timestamps, empty
    identities/names, non-positive rounds, negative durations, duplicate
    argument keys, and empty failure payloads are rejected before persistence. *)

type trajectory_outcome =
  | Completed
  | Failed of string
  | Timeout
  | Gated of string

type trajectory = {
  keeper_name : string;
  trace_id : string;
  generation : int;
  started_at : float;
  ended_at : float;
  entries : tool_call_entry list;
  total_turns : int;
  total_tool_calls : int;
  outcome : trajectory_outcome;
}

(** {1 Thinking entries}

    OAS Thinking/ReasoningDetails/RedactedThinking blocks, persisted in
    provider order with their canonical structured payload alongside Tool
    entries in the same JSONL file. *)

type thinking_entry = private {
  ts : float;
  ts_iso : string;
  turn : int;
  block_index : int;
  block : Agent_sdk.Types.content_block;
}

val make_thinking_entry :
  ts:float ->
  ts_iso:string ->
  turn:int ->
  block_index:int ->
  block:Agent_sdk.Types.content_block ->
  (thinking_entry, entry_decode_error) result
(** Construct one canonical provider-reasoning row. Non-reasoning OAS blocks
    and invalid ordering metadata are rejected before persistence. *)

(** Tagged union for reading mixed JSONL (tool calls + thinking). *)
type trajectory_line =
  | Tool_call of tool_call_entry
  | Thinking of thinking_entry

type trajectory_line_decode_summary = {
  tool_call_count : int;
  thinking_count : int;
  skipped_summary_count : int;
  invalid_line_count : int;
  invalid_reasons : invalid_entry_counts;
}

type trajectory_lines_read_result = {
  lines : trajectory_line list;
  line_decode : trajectory_line_decode_summary;
  io_errors : trajectory_read_error list;
}

type trajectory_byte_cursor
(** Opaque position in one immutable trajectory-file prefix.  A cursor binds
    its byte offset to the opened file identity and snapshot size, so a later
    page cannot silently continue in a replaced or truncated trace. *)

type trajectory_lines_page = {
  read : trajectory_lines_read_result;
  next_cursor : trajectory_byte_cursor option;
}

val trajectory_byte_cursor_offset : trajectory_byte_cursor -> int64
(** Byte boundary immediately before the oldest row observed by the page that
    produced this cursor. *)

type persistence_operation =
  | Append_tool_call
  | Flush_pending

type persistence_error_cause =
  | Durable_append_rejected of Fs_compat.private_jsonl_append_error
  | Persistence_exception of exn

type persistence_error = {
  operation : persistence_operation;
  path : string;
  cause : persistence_error_cause;
}

exception Persistence_error of persistence_error

val persistence_error_to_string : persistence_error -> string

type round_hydration_error =
  | Malformed_round_row of { trace_id : string; detail : string }
  | Invalid_round_row of
      { trace_id : string
      ; error : entry_decode_error
      }
  | Round_store_error of { path : string; detail : string }

exception Round_hydration_error of round_hydration_error

val round_hydration_error_to_string : round_hydration_error -> string

(** {1 JSON serialization} *)

val outcome_to_json : trajectory_outcome -> Yojson.Safe.t
val outcome_to_string : trajectory_outcome -> string
val entry_to_json : tool_call_entry -> Yojson.Safe.t

val tool_call_entry_of_json :
  Yojson.Safe.t -> tool_call_entry_decode
(** Decode one persisted JSONL row back into a [tool_call_entry].
    Invalid data is a row-local [Invalid_entry] and does not stop other rows
    from decoding. *)
val thinking_entry_to_json : thinking_entry -> Yojson.Safe.t
val trajectory_line_to_json : trajectory_line -> Yojson.Safe.t
val trajectory_to_json : trajectory -> Yojson.Safe.t
val invalid_entry_counts_to_json : invalid_entry_counts -> Yojson.Safe.t
val entry_decode_summary_to_json : entry_decode_summary -> Yojson.Safe.t
val trajectory_line_decode_summary_to_json :
  trajectory_line_decode_summary -> Yojson.Safe.t
val trajectory_read_errors_to_json :
  trajectory_read_error list -> Yojson.Safe.t

(** {1 Persistence} *)

val trajectories_dir : string -> string -> string
val trajectory_path : string -> string -> string -> string

val read_entries_result :
  masc_root:string -> keeper_name:string -> trace_id:string ->
  entries_read_result
(** Read one trace without collapsing read failures or invalid rows into a
    false empty trajectory. Missing trace files are a legitimate empty result;
    I/O failures are preserved in [io_errors]. *)

(** Get the next round number for a (keeper_name, trace_id, turn) without
    reading the entire trajectory file. A cold key finds the latest durable
    Tool row by exact exponential tail search, then increments in-memory. *)
val next_round :
  masc_root:string -> keeper_name:string -> trace_id:string -> turn:int ->
  int

val reset_round_counters_for_testing : unit -> unit
(** Clear the in-memory round-counter cache. Test-only: lets tests start from a
    known state and force re-hydration from disk. *)

val trajectory_lines_of_jsonl_lines :
  string list -> trajectory_lines_read_result
(** Decode JSONL rows using the closed Tool/Thinking/summary discriminator.
    Invalid rows are excluded from [lines] and counted by typed reason in
    [line_decode]; summaries are explicitly counted as skipped. *)

val read_all_lines_result :
  masc_root:string -> keeper_name:string -> trace_id:string ->
  trajectory_lines_read_result
(** Read all entries (tool calls + thinking) from JSONL with decode and I/O
    observations. *)

val read_recent_lines_result :
  masc_root:string -> keeper_name:string -> trace_id:string -> max_entries:int ->
  trajectory_lines_read_result
(** Read up to [max_entries] canonical entries (Tool calls + Thinking) from the
    JSONL tail.  The bound counts decoded entries, not physical rows:
    summaries and invalid rows are observed without consuming it.  [lines]
    are chronological, oldest first; decode and I/O failures remain explicit
    in the result. *)

val read_recent_lines_page_result :
  masc_root:string ->
  keeper_name:string ->
  trace_id:string ->
  ?before:trajectory_byte_cursor ->
  max_entries:int ->
  unit ->
  trajectory_lines_page
(** Cursor-driven form of {!read_recent_lines_result}.  Reads backwards from
    [before], or from a stable end-of-file snapshot when omitted, and stops at
    exactly [max_entries] canonical rows or the beginning of that snapshot.
    [next_cursor] is present only when older bytes remain.  A file replacement,
    truncation, or storage failure is reported in [read.io_errors]. *)

(** {1 Accumulator}

    Session-scoped mutable state whose queue, locks, and finalization flag stay
    private to this module. Callers can observe identity/current entries but
    cannot construct a second state representation or mutate persistence
    internals. *)

type accumulator

type accumulator_registration_error =
  | Active_accumulator_exists of
      { masc_root : string
      ; keeper_name : string
      ; trace_id : string
      }

exception Accumulator_registration_error of accumulator_registration_error

val accumulator_registration_error_to_string :
  accumulator_registration_error -> string

val create_accumulator :
  ?on_flush_error:(exn -> unit) ->
  masc_root:string -> keeper_name:string -> trace_id:string ->
  generation:int -> unit -> accumulator

val accumulator_masc_root : accumulator -> string
val accumulator_keeper_name : accumulator -> string
val accumulator_trace_id : accumulator -> string
val accumulator_entries : accumulator -> tool_call_entry list

val record_entry : accumulator -> tool_call_entry -> unit
(** Queue an already validated Tool observation.  Its [turn] must come from the
    exact execution occurrence (for OAS, {!Agent_sdk.Tool.Invocation.turn});
    the accumulator has no ambient or independently incremented turn state. *)
val record_thinking : accumulator -> thinking_entry -> unit
val record_tool_call :
  masc_root:string -> keeper_name:string -> trace_id:string ->
  tool_call_entry -> unit
(** Record through the active per-trace accumulator when one exists; otherwise
    durably append through the same closed serializer. This is the only public
    Tool-row persistence boundary. *)
val finalize : accumulator -> trajectory_outcome -> trajectory

val flush_pending : accumulator -> unit
(** [flush_pending acc] drains the pending queue and writes all entries
    to disk in a single batch. Called automatically by [finalize] and
    by the background flush fiber. *)

val flush_all_pending : sw:Eio.Switch.t -> unit
(** [flush_all_pending ~sw] schedules each active accumulator on an independent
    I/O fiber and returns without awaiting lane completion. A per-accumulator
    in-flight guard prevents overlapping writes while one stalled Keeper lane
    cannot delay later flush cycles for siblings. Must be called from an Eio
    fiber. *)

(** {1 Tool stats aggregation}

    Server-side aggregation for the keeper tool telemetry dashboard.
    Computes per-tool call counts, latency percentiles, and
    hourly activity buckets from raw trajectory entries. *)

type tool_stat = {
  name : string;
  call_count : int;
  success_count : int;
  failure_count : int;
  avg_duration_ms : int;
  p95_duration_ms : int;
  max_duration_ms : int;
  last_used_at : string;
}

type hourly_bucket = {
  hour : string;  (** ISO8601 hour start, e.g. "2026-04-06T10:00:00Z" *)
  call_count : int;
  error_count : int;
}

val aggregate_tool_stats : tool_call_entry list -> tool_stat list
(** Aggregate per-tool statistics from a list of entries.
    Results sorted by call_count descending. *)

val hourly_timeline : tool_call_entry list -> hourly_bucket list
(** Bucket entries by hour. Results sorted chronologically. *)

val tool_stat_to_json : tool_stat -> Yojson.Safe.t
val hourly_bucket_to_json : hourly_bucket -> Yojson.Safe.t

val read_entries_since_result :
  masc_root:string -> keeper_name:string -> since:float ->
  entries_read_result
(** Read entries from all trace files for a keeper with [ts >= since]. Results
    are sorted chronologically. Files are streamed row-by-row; malformed or
    unsupported rows and file failures are observed separately and never stop
    other files or rows. *)
