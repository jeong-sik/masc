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

    Wraps Circuit_breaker with agent-name semantics for Keeper Heartbeat.
    Failure history is diagnostic data and never controls participation.

    Integration points:
    - Statistics: health_summary for dashboard/monitoring

    @since 2.75.0 *)

type agent_health_summary = {
  agent_name : string;
  failure_count : int;
  last_failure : Circuit_breaker.failure_record option;
  last_success_at : float option;
}

let record_success ~agent_name =
  Circuit_breaker.record_success_global ~agent_id:agent_name

let record_failure ~agent_name ~reason =
  Circuit_breaker.record_failure_global ~agent_id:agent_name ~reason

(** {1 Statistics} *)

(** Get health summary for a single agent. *)
let get_summary ~agent_name : agent_health_summary =
  let observation =
    Circuit_breaker.get_observation_global ~agent_id:agent_name
  in
  {
    agent_name;
    failure_count = observation.failure_count;
    last_failure = observation.last_failure;
    last_success_at = observation.last_success_at;
  }

(** {1 JSON Serialization} *)

let failure_to_json (failure : Circuit_breaker.failure_record) =
  `Assoc
    [ "timestamp", `Float failure.timestamp
    ; "reason", `String failure.reason
    ]

let summary_to_json (s : agent_health_summary) : Yojson.Safe.t =
  `Assoc [
    ("agent_name", `String s.agent_name);
    ("failure_count", `Int s.failure_count);
    ( "last_failure"
    , Option.fold ~none:`Null ~some:failure_to_json s.last_failure );
    ("last_success_at", Json_util.float_opt_to_json s.last_success_at);
  ]
