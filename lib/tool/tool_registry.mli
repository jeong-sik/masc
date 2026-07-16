
(** Tool_registry — in-memory call counters and usage statistics.

    Zero-allocation atomic counters for hot-path performance.
    Complements Telemetry_eio's JSONL persistence. Data resets on server restart.

    @since 0.1.0 *)

(** {1 Types} *)

type call_source =
  | External_mcp
  | Agent_internal

type call_stats = {
  call_count : int Atomic.t;
  success_count : int Atomic.t;
  deferred_count : int Atomic.t;
  failure_count : int Atomic.t;
  last_called_at : float Atomic.t;
  total_duration_ms : int Atomic.t;
  external_mcp_count : int Atomic.t;
  agent_internal_count : int Atomic.t;
  last_assignment_id : string option Atomic.t;
}

(** {1 Recording} *)

val string_of_source : call_source -> string
val record_call :
  ?source:call_source -> ?assignment_id:string -> tool_name:string ->
  disposition:('completed, 'deferred, 'failed) Tool_result.disposition ->
  duration_ms:int -> unit -> unit
val record_call_if_known :
  ?source:call_source -> ?assignment_id:string -> tool_name:string ->
  disposition:('completed, 'deferred, 'failed) Tool_result.disposition ->
  duration_ms:int -> unit -> unit

(** {1 Queries} *)

val is_known_tool : string -> bool
(** [is_known_tool name] returns whether [name] is admitted to in-memory call
    stats.  This is not a public-surface visibility predicate. *)
val get_stats : unit -> (string * call_stats) list
val get_top_n : int -> (string * call_stats) list
val get_unused_since : float -> string list
val get_never_called : string list -> string list
val total_calls : unit -> int
val distinct_tools_called : unit -> int

(** {1 Reporting} *)

val stats_to_json : string * call_stats -> Yojson.Safe.t
val stats_report : top_n:int -> all_tool_names:string list -> Yojson.Safe.t

(** {1 Lifecycle} *)

val reset : unit -> unit
