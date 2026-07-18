(** Trajectory — Tool call recording for keeper sessions.

    Tracks exact tool-call observations per turn and persists them as JSONL for
    post-hoc analysis. Model usage and cost are observed from OAS inference
    facts; Trajectory does not estimate either from Tool names. *)

(** {1 Types} *)

type tool_call_entry = {
  ts : float;
  ts_iso : string;
  turn : int;
  round : int;
  tool_name : string;
  arguments : (string * Yojson.Safe.t) list;
      (** Structured Tool arguments. The association-list type makes the JSON
          object invariant explicit and prevents a parallel string form. *)
  result : string option;
  duration_ms : int;
  error : string option;
  execution_id : string option;
      (** RFC-0233 canonical join key shared with the tool_calls JSONL row
          for the same execution. [None] is an explicit source value, never a
          fabricated identifier. *)
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
  | Result
  | Duration_ms
  | Error_message
  | Execution_id
  | Content
  | Content_length
  | Redacted

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

    Thinking blocks from LLM responses, persisted alongside tool call entries
    in the same JSONL file with [type = "thinking"]. *)

type thinking_entry = {
  ts : float;
  ts_iso : string;
  turn : int;
  content : string;
  content_length : int;
  redacted : bool;
}

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

(** {1 JSON serialization} *)

val outcome_to_json : trajectory_outcome -> Yojson.Safe.t
val outcome_to_string : trajectory_outcome -> string
val default_result_truncation : int
val default_thinking_truncation : int
val entry_to_json :
  ?result_max_len:int ->
  tool_call_entry ->
  Yojson.Safe.t

val tool_call_entry_of_json :
  Yojson.Safe.t -> tool_call_entry_decode
(** Decode one persisted JSONL row back into a [tool_call_entry].
    Invalid data is a row-local [Invalid_entry] and does not stop other rows
    from decoding. *)
val thinking_entry_to_json : ?content_max_len:int -> thinking_entry -> Yojson.Safe.t
val trajectory_line_to_json : ?result_max_len:int -> ?content_max_len:int -> trajectory_line -> Yojson.Safe.t
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

val append_entry :
  masc_root:string -> keeper_name:string -> trace_id:string ->
  tool_call_entry -> unit

val append_summary :
  masc_root:string -> keeper_name:string -> trace_id:string ->
  trajectory -> unit

val append_thinking :
  masc_root:string -> keeper_name:string -> trace_id:string ->
  thinking_entry -> unit

val read_entries_result :
  masc_root:string -> keeper_name:string -> trace_id:string ->
  entries_read_result
(** Read one trace without collapsing read failures or invalid rows into a
    false empty trajectory. Missing trace files are a legitimate empty result;
    I/O failures are preserved in [io_errors]. *)

(** Get the next round number for a (keeper_name, trace_id, turn) without
    reading the entire trajectory file. Lazily hydrates from disk on first
    access per key, then increments in-memory. Round numbers already issued by
    this process remain monotonic for the key even if an active counter is
    evicted and later rehydrated. *)
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
  masc_root:string -> keeper_name:string -> trace_id:string -> max_lines:int ->
  trajectory_lines_read_result
(** Read a bounded tail of entries (tool calls + thinking) from JSONL.
    [lines] are chronological, oldest first; decode and I/O failures remain
    explicit in the result. *)

(** {1 Accumulator}

    Mutable session-scoped state for tracking tool calls in progress. *)

type pending_entry = {
  pe_json : Yojson.Safe.t;
}

type accumulator = {
  mutable entries : tool_call_entry list;
  mutable total_calls : int;
  mutable turn : int;
  keeper_name : string;
  trace_id : string;
  generation : int;
  started_at : float;
  masc_root : string;
  pending_queue : pending_entry Queue.t;
  pending_mu : Mutex.t;
  mutable last_flush : float;
  mutable on_flush_error : (exn -> unit) option;
}

val create_accumulator :
  ?on_flush_error:(exn -> unit) ->
  masc_root:string -> keeper_name:string -> trace_id:string ->
  generation:int -> unit -> accumulator

val increment_turn : accumulator -> unit
val record_entry :
  ?on_persist_error:(exn -> unit) ->
  accumulator ->
  tool_call_entry ->
  unit
val finalize : accumulator -> trajectory_outcome -> trajectory

val flush_pending : accumulator -> unit
(** [flush_pending acc] drains the pending queue and writes all entries
    to disk in a single batch. Called automatically by [finalize] and
    by the background flush fiber. *)

val flush_all_pending : unit -> unit
(** [flush_all_pending ()] flushes pending entries for all active
    accumulators. Called by the background flush fiber in
    server_runtime_bootstrap. *)

val calls_in_current_turn : accumulator -> int

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
    are sorted chronologically. Explicit gate rejection is a valid decoded
    entry; malformed/unsupported rows and file failures are observed
    separately and never stop other files or rows. *)
