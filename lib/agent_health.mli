open Base
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

(** Agent Health — Autonomy-specific health gate over Circuit Breaker.

    Wraps {!Circuit_breaker} with agent-name semantics for Keeper
    Heartbeat. Agents with open breakers are skipped during tick
    selection, preventing cascading failures from repeatedly invoking
    failing agents.

    Integration points:
    - Pre-action: {!is_healthy} before [decide_agent_action]
    - Post-action: {!record_success} / {!record_failure} after
      [execute_agent_action]
    - Statistics: {!get_summary} / {!get_all_summaries} for
      dashboard/monitoring

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

(** {1 Core API} *)

(** [Healthy] / [Unhealthy reason] / [Recovering]. This function
    currently never returns [Unknown] — that case is reserved for
    {!get_summary} when [Circuit_breaker] exposes an unrecognised
    [state_name]. *)
val check_health : agent_name:string -> health_status

(** Convenience predicate. Fail-closed: [Unhealthy] and [Unknown] map
    to [false]; [Healthy] and [Recovering] map to [true]. *)
val is_healthy : agent_name:string -> bool

(** Record a successful action — clears half-open state. *)
val record_success : agent_name:string -> unit

(** Record a failed action — may open the breaker. *)
val record_failure : agent_name:string -> reason:string -> unit

(** {1 Batch Filtering} *)

(** [filter_healthy agents] splits into [(healthy, skipped_with_reasons)].
    [Unknown raw] is reported as ["unknown breaker state <raw>"]. *)
val filter_healthy :
  (string * 'a) list ->
  (string * 'a) list * (string * string) list

(** {1 Statistics} *)

val get_summary : agent_name:string -> agent_health_summary

val get_all_summaries : unit -> agent_health_summary list

(** {1 JSON Serialization} *)

(** Wire strings: ["healthy"] / ["unhealthy"] / ["recovering"] /
    ["unknown"]. Issue #8607 introduced the dedicated ["unknown"] bucket
    so dashboards can filter unrecognised states instead of mixing
    them with green ones. *)
val health_status_to_string : health_status -> string

(** Shape: [{agent_name, status, recent_failures, cooldown_remaining_sec}]. *)
val summary_to_json : agent_health_summary -> Yojson.Safe.t
