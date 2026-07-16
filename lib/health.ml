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

(** {1 Types} *)

type health_status =
  | Healthy
  | Unhealthy of string  (** reason *)
  | Recovering           (** half-open, testing *)
  | Unknown of string    (** Issue #8607: unrecognised circuit-breaker
                             state_name (carries the raw value for
                             diagnostics). Previously [_ -> Healthy]
                             silently masked future state additions
                             (e.g. a 4th [Throttled]) and any wire-format
                             drift as a green health signal. *)

type agent_health_summary = {
  agent_name : string;
  status : health_status;
  recent_failures : int;
  cooldown_remaining_sec : int;
}

(** Record a successful action — clears half-open state. *)
let record_success ~agent_name =
  Circuit_breaker.record_success_global ~agent_id:agent_name

(** Record a failed action — may open the breaker. *)
let record_failure ~agent_name ~reason =
  Circuit_breaker.record_failure_global ~agent_id:agent_name ~reason

(** {1 Statistics} *)

(* Issue #8607: shared mapping helper — both get_summary and
   get_all_summaries used to inline the same 4-arm match with [_ ->
   Healthy] as the catch-all, so an unknown state_name lied as
   Healthy. Unifying ensures one place to update; routing the
   catch-all through [Unknown name] makes drift operator-visible. *)
let health_status_of_breaker
    ~(state_name : string)
    ~(open_reason : string option)
    : health_status =
  match state_name with
  | "closed" -> Healthy
  | "half_open" -> Recovering
  | "open" -> Unhealthy (Option.value ~default:"unknown" open_reason)
  | other -> Unknown other

let cooldown_remaining_of (open_until : float option) : int =
  match open_until with
  | Some until ->
      let remaining = until -. Time_compat.now () in
      if Stdlib.Float.compare remaining 0.0 > 0 then Int.of_float remaining else 0
  | None -> 0

(** Get health summary for a single agent. *)
let get_summary ~agent_name : agent_health_summary =
  let status = Circuit_breaker.get_status_global ~agent_id:agent_name in
  {
    agent_name;
    status =
      health_status_of_breaker
        ~state_name:status.state_name
        ~open_reason:status.open_reason;
    recent_failures = status.recent_failures;
    cooldown_remaining_sec = cooldown_remaining_of status.open_until;
  }

(** {1 JSON Serialization} *)

let health_status_to_string = function
  | Healthy -> "healthy"
  | Unhealthy _ -> "unhealthy"
  | Recovering -> "recovering"
  (* Issue #8607: distinct wire string so dashboards/operators can
     filter for unrecognised breaker states instead of mixing them
     with green ones. *)
  | Unknown _ -> "unknown"

let summary_to_json (s : agent_health_summary) : Yojson.Safe.t =
  `Assoc [
    ("agent_name", `String s.agent_name);
    ("status", `String (health_status_to_string s.status));
    ("recent_failures", `Int s.recent_failures);
    ("cooldown_remaining_sec", `Int s.cooldown_remaining_sec);
  ]
