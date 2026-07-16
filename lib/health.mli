module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float
module Random = Stdlib.Random

(** Agent Health — Keeper failure observation over Circuit Breaker.

    Wraps {!Circuit_breaker} with agent-name semantics for Keeper
    Heartbeat. Failure history is diagnostic data and never controls
    Keeper participation.

    Integration points:
    - Post-action: {!record_success} / {!record_failure} after
      [execute_agent_action]
    - Statistics: {!get_summary} for dashboard/monitoring

    @since 2.75.0 *)

type agent_health_summary = {
  agent_name : string;
  failure_count : int;
  last_failure : Circuit_breaker.failure_record option;
  last_success_at : float option;
}

(** Record a successful action as an observation. *)
val record_success : agent_name:string -> unit

(** Append a failed action observation. *)
val record_failure : agent_name:string -> reason:string -> unit

(** {1 Statistics} *)

val get_summary : agent_name:string -> agent_health_summary

(** {1 JSON Serialization} *)

(** Shape: [{agent_name, failure_count, last_failure, last_success_at}]. *)
val summary_to_json : agent_health_summary -> Yojson.Safe.t
