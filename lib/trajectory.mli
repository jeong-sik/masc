(** Trajectory — Tool call recording and cost/entropy gates for keeper sessions.

    Tracks tool calls per turn, accumulated cost, and detects stuck loops
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
  cost_usd : float;
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
  generation : int;
  started_at : float;
  ended_at : float;
  entries : tool_call_entry list;
  total_cost_usd : float;
  total_turns : int;
  total_tool_calls : int;
  outcome : trajectory_outcome;
  task_id : string option;
}

(** {1 Cost estimation} *)

val tool_cost_estimate : string -> float
(** Rough per-call cost estimate for keeper tools. *)

(** {1 JSON serialization} *)

val gate_decision_to_json : gate_decision -> Yojson.Safe.t
val outcome_to_json : trajectory_outcome -> Yojson.Safe.t
val outcome_to_string : trajectory_outcome -> string
val default_result_truncation : int
val entry_to_json : ?result_max_len:int -> tool_call_entry -> Yojson.Safe.t
val trajectory_to_json : trajectory -> Yojson.Safe.t

(** {1 Persistence} *)

val trajectories_dir : string -> string -> string
val trajectory_path : string -> string -> string -> string

val append_entry :
  masc_root:string -> keeper_name:string -> trace_id:string ->
  tool_call_entry -> unit

val append_summary :
  masc_root:string -> keeper_name:string -> trace_id:string ->
  trajectory -> unit

val read_entries :
  masc_root:string -> keeper_name:string -> trace_id:string ->
  tool_call_entry list

(** {1 Accumulator}

    Mutable session-scoped state for tracking tool calls in progress. *)

type accumulator = {
  mutable entries : tool_call_entry list;
  mutable total_cost : float;
  mutable total_calls : int;
  mutable turn : int;
  keeper_name : string;
  trace_id : string;
  generation : int;
  started_at : float;
  masc_root : string;
  mutable task_id : string option;
}

val create_accumulator :
  masc_root:string -> keeper_name:string -> trace_id:string ->
  generation:int -> accumulator

val set_task_id : accumulator -> string -> unit
val clear_task_id : accumulator -> unit
val increment_turn : accumulator -> unit
val record_entry : accumulator -> tool_call_entry -> unit
val finalize : accumulator -> trajectory_outcome -> trajectory

val detect_entropy :
  ?threshold:int -> accumulator -> string -> (string * int) option
(** Detect if [tool_name] has been called [threshold]+ times consecutively. *)

val calls_in_current_turn : accumulator -> int
