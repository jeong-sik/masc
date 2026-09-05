(** Trajectory — Tool call recording, cost telemetry, and entropy gates for keeper sessions.

    Tracks tool calls per turn, accumulated cost telemetry, and detects stuck loops
    via entropy checking. Persists trajectory data as JSONL for post-hoc analysis. *)

(** {1 Types} *)

type gate_decision =
  | Pass
  | Reject of string

type tool_call_entry = {
  ts : float;
  ts_iso : string;
  turn : int;
  round : int;
  tool_name : string;
  args_json : string;
  gate_decision : gate_decision;
  result : string option;
  duration_ms : int;
  error : string option;
  execution_id : string option;
      (** RFC-0233 canonical join key shared with the tool_calls JSONL row
          for the same execution. [None] only for rows written by paths
          that have not adopted the id yet (and historical rows). *)
}

type trajectory_outcome =
  | Completed
  | Failed of string
  | Timeout
  | CostExceeded
  | Gated of string

type trajectory = {
  scenario_id : string option;
  keeper_name : string;
  trace_id : string;
  started_at : float;
  ended_at : float;
  entries : tool_call_entry list;
  total_turns : int;
  total_tool_calls : int;
  outcome : trajectory_outcome;
  task_id : string option;
}

(** {1 Withheld reasoning entries} *)

type withheld_reasoning_kind =
  | Thinking_block
  | Reasoning_details
  | Redacted_thinking

type withheld_thinking_entry = {
  ts : float;
  ts_iso : string;
  turn : int;
  block_index : int;
  reasoning_kind : withheld_reasoning_kind;
  char_count : int;
}
(** Metadata for one newly observed reasoning block. The type cannot carry
    hidden content or provider replay signatures. *)

(** Tagged union for reading tool calls and metadata-only reasoning evidence.
    Content-bearing historical thinking rows are rejected by the decoder. *)
type trajectory_line =
  | Tool_call of tool_call_entry
  | Withheld_thinking of withheld_thinking_entry

(** {1 Cost estimation} *)

(** Rough per-call cost estimate for keeper tools. *)

(** {1 JSON serialization} *)

val outcome_to_json : trajectory_outcome -> Yojson.Safe.t
val outcome_to_string : trajectory_outcome -> string
val entry_to_json :
  ?result_max_len:int ->
  ?runtime_contract:Yojson.Safe.t ->
  ?action_radius:Yojson.Safe.t ->
  tool_call_entry ->
  Yojson.Safe.t

val tool_call_entry_of_json : Yojson.Safe.t -> tool_call_entry option
val trajectory_line_to_json : ?result_max_len:int -> trajectory_line -> Yojson.Safe.t
val trajectory_to_json : trajectory -> Yojson.Safe.t

(** {1 Persistence} *)

val trajectories_dir : string -> string -> string
val trajectory_path : string -> string -> string -> string

val append_entry :
  ?runtime_contract:Yojson.Safe.t ->
  ?action_radius:Yojson.Safe.t ->
  masc_root:string -> keeper_name:string -> trace_id:string ->
  tool_call_entry -> unit

val append_withheld_thinking :
  masc_root:string -> keeper_name:string -> trace_id:string ->
  withheld_thinking_entry -> unit
(** Persist one metadata-only reasoning observation. [content] is always JSON
    null at this writer boundary. *)

val read_entries :
  masc_root:string -> keeper_name:string -> trace_id:string ->
  tool_call_entry list

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
  trace_id:string -> string list -> trajectory_line list * int * int
(** Decode JSONL lines into parsed trajectory lines, the number of malformed
    or unrecognized rows, and the total number of non-empty rows seen.
    Intentionally skipped rows such as [trajectory_summary] do not count as
    malformed. *)

val read_all_lines :
  masc_root:string -> keeper_name:string -> trace_id:string ->
  trajectory_line list
(** Read all entries (tool calls + thinking) from JSONL. *)

val read_recent_lines :
  masc_root:string -> keeper_name:string -> trace_id:string -> max_lines:int ->
  trajectory_line list
(** Read a bounded tail of entries (tool calls + thinking) from JSONL.
    Returns entries chronologically, oldest first. *)

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
  started_at : float;
  masc_root : string;
  mutable task_id : string option;
  pending_queue : pending_entry Queue.t;
  pending_mu : Mutex.t;
  mutable last_flush : float;
  mutable on_flush_error : (exn -> unit) option;
}

val create_accumulator :
  ?on_flush_error:(exn -> unit) ->
  masc_root:string -> keeper_name:string -> trace_id:string ->
  unit -> accumulator

val set_task_id : accumulator -> string -> unit
val clear_task_id : accumulator -> unit
val increment_turn : accumulator -> unit

val set_turn : accumulator -> int -> unit
(** Adopt the turn number the runtime already assigns, so tool-call entries
    carry the same turn as the reasoning entries they belong to. Monotonic:
    a lower value is ignored, which keeps [calls_in_current_turn] from
    re-counting an earlier turn's rounds. *)
val record_entry :
  ?runtime_contract:Yojson.Safe.t ->
  ?action_radius:Yojson.Safe.t ->
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
    Computes per-tool call counts, latency percentiles, cost, and
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

val read_entries_since :
  masc_root:string -> keeper_name:string -> since:float ->
  tool_call_entry list
(** Read entries from all trace files for a keeper with ts >= [since].
    Results sorted chronologically. *)


