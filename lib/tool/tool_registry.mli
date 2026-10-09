
(** Tool_registry — in-memory call counters and usage statistics.

    Immutable per-tool observations published atomically.
    Complements Telemetry_eio's JSONL persistence. Data resets on server restart.

    @since 0.1.0 *)

(** {1 Types} *)

type call_source =
  | External_mcp
  | Agent_internal

type call_stats = {
  call_count : int;
  success_count : int;
  deferred_count : int;
  failure_count : int;
  last_called_at : float;
  total_duration_ms : int;
  external_mcp_count : int;
  agent_internal_count : int;
  last_assignment_id : string option;
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

(** Returns retained immutable per-tool observations. Later recording or reset
    does not change returned values. Different tools are sampled separately. *)
val get_stats : unit -> (string * call_stats) list
val get_top_n : int -> (string * call_stats) list
val get_never_called : string list -> string list
val total_calls : unit -> int
val distinct_tools_called : unit -> int

(** {1 Lifecycle} *)

val reset : unit -> unit
