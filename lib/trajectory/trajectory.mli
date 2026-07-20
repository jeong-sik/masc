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
  keeper_turn_id : int;
  oas_turn : int;
  schedule : Agent_sdk.Tool.schedule;
  tool_use_id : string;
  tool_name : string;
  arguments : (string * Yojson.Safe.t) list;
      (** Structured Tool arguments. The association-list type makes the JSON
          object invariant explicit and prevents a parallel string form. *)
  outcome : tool_call_outcome;
  duration_ms : int;
  execution_id : Ids.Execution_id.t;
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
  | Schema
  | Row_type
  | Timestamp
  | Timestamp_iso
  | Keeper_turn_id
  | Oas_turn
  | Schedule
  | Planned_index
  | Batch_index
  | Batch_size
  | Execution_mode
  | Tool_use_id
  | Tool_name
  | Arguments
  | Tool_outcome
  | Duration_ms
  | Execution_id
  | Keeper_name
  | Trace_id
  | Generation
  | Observed_oas_turn_count
  | Total_tool_calls
  | Trajectory_outcome
  | Started_at
  | Ended_at
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
  keeper_turn_id:int ->
  invocation:Agent_sdk.Tool.Invocation.t ->
  tool_name:string ->
  arguments:(string * Yojson.Safe.t) list ->
  outcome:tool_call_outcome ->
  duration_ms:int ->
  execution_id:Ids.Execution_id.t ->
  (tool_call_entry, entry_decode_error) result
(** Construct a canonical Tool observation. Invalid timestamps, empty
    identities/names, invalid exact OAS schedule values, negative durations, duplicate
    argument keys, and empty failure payloads are rejected before persistence. *)

type trajectory_outcome =
  | Completed
  | Failed of string
  | Input_required
  | Cancelled

type trajectory = {
  keeper_name : string;
  trace_id : string;
  keeper_turn_id : int;
  generation : int;
  started_at : float;
  ended_at : float;
  observed_oas_turn_count : int;
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
  keeper_turn_id : int;
  oas_turn : int;
  block_index : int;
  block : Agent_sdk.Types.content_block;
}

val make_thinking_entry :
  ts:float ->
  ts_iso:string ->
  keeper_turn_id:int ->
  oas_turn:int ->
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

type trajectory_scan_limit_error =
  | Non_positive_physical_row_limit of int
  | Non_positive_byte_limit of int64

type trajectory_scan_limits = private {
  max_physical_rows : int;
  max_bytes : int64;
}

val make_trajectory_scan_limits :
  max_physical_rows:int ->
  max_bytes:int64 ->
  (trajectory_scan_limits, trajectory_scan_limit_error) result
(** Construct one transport-I/O scan contract. Both limits must be positive.
    These limits bound work performed by one read/page request; they are not a
    Keeper turn, cost, token, recurrence, pause, or stop policy. *)

val trajectory_scan_limit_error_to_string :
  trajectory_scan_limit_error -> string

val standard_trajectory_scan_limits : trajectory_scan_limits
(** Canonical bounded transport-I/O contract for server call sites that select
    the standard page policy explicitly. It is process-local read protection
    only and never gates a Keeper's behavior or lifecycle. *)

type trajectory_scan_stop =
  | Reached_snapshot_start
  | Reached_entry_limit
  | Reached_physical_row_limit
  | Reached_byte_limit
  | Blocked_by_oversized_physical_row
  | Rejected_cursor
  | Read_error

type trajectory_scan_coverage =
  | Scan_complete
  | Scan_partial
  | Scan_blocked

val trajectory_scan_coverage : trajectory_scan_stop -> trajectory_scan_coverage
(** Derive coverage from the single authoritative stop reason. *)

val trajectory_scan_stop_to_string : trajectory_scan_stop -> string
(** Canonical closed wire label for a page stop reason. *)

type trajectory_scan_observation = {
  physical_rows : int;
      (** Complete newline-delimited rows inspected, including blank,
          summary, and invalid rows. A partial oversized row is not counted. *)
  bytes_read : int64;
      (** Bytes actually returned by the underlying reads, including bytes
          consumed before an explicit I/O error. *)
  stop : trajectory_scan_stop;
}

type trajectory_byte_cursor
(** Opaque position in one immutable trajectory-file prefix.  A cursor binds
    its byte offset to the logical keeper/trace identity, opened file identity,
    and snapshot size, so a later page cannot silently continue in a different,
    replaced, or truncated trace. *)

type trajectory_cursor_field =
  | Cursor_schema
  | Cursor_keeper_name
  | Cursor_trace_id
  | Cursor_snapshot_device
  | Cursor_snapshot_inode
  | Cursor_snapshot_size
  | Cursor_before_byte

type trajectory_cursor_decode_error =
  | Cursor_base64_decode_failed
  | Cursor_json_decode_failed
  | Cursor_expected_object
  | Cursor_missing_field of trajectory_cursor_field
  | Cursor_invalid_field of trajectory_cursor_field
  | Cursor_unexpected_field of string
  | Cursor_duplicate_field of string

val trajectory_cursor_decode_error_to_string :
  trajectory_cursor_decode_error -> string

val trajectory_byte_cursor_to_string : trajectory_byte_cursor -> string
(** Encode a versioned closed cursor as unpadded URI-safe Base64. The token is
    opaque transport state, not an authorization credential. *)

val trajectory_byte_cursor_of_string :
  string -> (trajectory_byte_cursor, trajectory_cursor_decode_error) result
(** Decode the exact closed cursor schema. Malformed Base64/JSON, missing,
    duplicate, unexpected, incorrectly typed, or out-of-range fields are
    explicit typed errors. *)

type trajectory_lines_page = {
  read : trajectory_lines_read_result;
  scan : trajectory_scan_observation;
  next_cursor : trajectory_byte_cursor option;
}

val trajectory_byte_cursor_offset : trajectory_byte_cursor -> int64
(** Byte boundary immediately before the oldest row observed by the page that
    produced this cursor. *)

type persistence_operation =
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

val trajectory_contract_version : string
(** Canonical wire and store version segment. The current closed codec and
    [trajectories_dir] both derive their [v1] identity from this value. *)

val trajectories_dir : string -> string -> string
val trajectory_path : string -> string -> string -> string

val read_entries_result :
  masc_root:string -> keeper_name:string -> trace_id:string ->
  entries_read_result
(** Read one trace without collapsing read failures or invalid rows into a
    false empty trajectory. Missing trace files are a legitimate empty result;
    I/O failures are preserved in [io_errors]. The file is decoded one physical
    row at a time, so memory is bounded by the decoded result plus the largest
    row rather than an additional full-file string and split-line list. *)

val trajectory_lines_of_jsonl_lines :
  string list -> trajectory_lines_read_result
(** Decode JSONL rows using the closed Tool/Thinking/summary discriminator.
    Invalid rows are excluded from [lines] and counted by typed reason in
    [line_decode]; summaries are explicitly counted as skipped. *)

val read_all_lines_result :
  masc_root:string -> keeper_name:string -> trace_id:string ->
  trajectory_lines_read_result
(** Read all entries (tool calls + thinking) from JSONL one physical row at a
    time with decode and I/O observations. Memory is bounded by the decoded
    result plus the largest row. *)

val read_recent_lines_page_result :
  masc_root:string ->
  keeper_name:string ->
  trace_id:string ->
  ?before:trajectory_byte_cursor ->
  scan_limits:trajectory_scan_limits ->
  max_entries:int ->
  unit ->
  trajectory_lines_page
(** Read backwards from [before], or from a stable end-of-file snapshot when
    omitted. One page stops
    at [max_entries], a physical-row/byte scan limit, or the beginning of the
    snapshot. [max_entries] must be positive. [scan] reports exact work and the
    typed stop reason; coverage is derived by {!trajectory_scan_coverage}.

    A byte-limit stop occurs only at a verified newline boundary, so following
    [next_cursor] neither skips nor duplicates a complete physical row. If one
    physical row itself exceeds the byte contract before any safe boundary can
    be established, the page is explicitly
    [Blocked_by_oversized_physical_row] and does not fabricate a continuation.
    File replacement, truncation, a cursor that is not on a verified newline
    boundary, cursor rejection, and storage failures remain explicit in
    [read.io_errors]. These are transport-I/O limits only, never Keeper
    behavioral gates. *)

(** {1 Accumulator}

    Keeper-turn-scoped mutable state whose pending durable queue, locks, and
    finalization flag stay private. Successfully flushed Tool payloads are not
    retained in memory. *)

type accumulator

type accumulator_registration_error =
  | Active_accumulator_exists of
      { masc_root : string
      ; keeper_name : string
      ; trace_id : string
      ; keeper_turn_id : int
      }

exception Accumulator_registration_error of accumulator_registration_error

val accumulator_registration_error_to_string :
  accumulator_registration_error -> string

val create_accumulator :
  ?on_flush_error:(exn -> unit) ->
  masc_root:string -> keeper_name:string -> trace_id:string ->
  keeper_turn_id:int -> generation:int -> unit -> accumulator

val accumulator_masc_root : accumulator -> string
val accumulator_keeper_name : accumulator -> string
val accumulator_trace_id : accumulator -> string
val accumulator_keeper_turn_id : accumulator -> int

val record_entry : accumulator -> tool_call_entry -> unit
(** Queue an already validated Tool observation. Its Keeper turn must equal
    the accumulator and its OAS turn/schedule come from the exact Invocation. *)
val record_thinking : accumulator -> thinking_entry -> unit
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
