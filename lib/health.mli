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

(** {1 Types} *)

type health_status =
  | Healthy
  | Unhealthy of string  (** reason *)
  | Recovering           (** half-open, testing *)
  | Unknown of string
      (** Issue #8607: unrecognised circuit-breaker state_name (carries
          the raw value for diagnostics). Previously [_ -> Healthy]
          silently masked future state additions and wire-format drift
          as a green health signal. *)

type agent_health_summary = {
  agent_name : string;
  status : health_status;
  recent_failures : int;
  cooldown_remaining_sec : int;
}

(** Record a successful action — clears half-open state. *)
val record_success : agent_name:string -> unit

(** Record a failed action — may open the breaker. *)
val record_failure : agent_name:string -> reason:string -> unit

(** {1 Statistics} *)

val get_summary : agent_name:string -> agent_health_summary

(** {1 JSON Serialization} *)

(** Wire strings: ["healthy"] / ["unhealthy"] / ["recovering"] /
    ["unknown"]. Issue #8607 introduced the dedicated ["unknown"] bucket
    so dashboards can filter unrecognised states instead of mixing
    them with green ones. *)
val health_status_to_string : health_status -> string

(** Shape: [{agent_name, status, recent_failures, cooldown_remaining_sec}]. *)
val summary_to_json : agent_health_summary -> Yojson.Safe.t
