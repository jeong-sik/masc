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

    Wraps Circuit_breaker with agent-name semantics for Keeper Heartbeat.
    Agents with open circuit breakers are skipped during tick selection,
    preventing cascading failures from repeatedly invoking failing agents.

    Integration points:
    - Pre-action: is_healthy checks before decide_agent_action
    - Post-action: record_outcome after execute_agent_action
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

(** {1 Core API} *)

(** Check if an agent is healthy enough to participate in the tick.
    Returns Healthy, Unhealthy(reason), or Recovering. *)
let check_health ~agent_name : health_status =
  match Circuit_breaker.check_global ~agent_id:agent_name with
  | Ok () ->
      let status = Circuit_breaker.get_status_global ~agent_id:agent_name in
      if String.equal status.state_name "half_open" then Recovering
      else Healthy
  | Error reason ->
      Unhealthy reason

(** Convenience predicate: can this agent participate?
    Issue #8607: [Unknown] is treated as not-healthy — a fail-closed
    response to drift. Today [check_health] never returns [Unknown]
    (only [get_summary] does), but the explicit arm pins the
    semantic so future paths producing [Unknown] don't accidentally
    grant participation. *)
let is_healthy ~agent_name : bool =
  match check_health ~agent_name with
  | Healthy | Recovering -> true
  | Unhealthy _ | Unknown _ -> false

(** Record a successful action — clears half-open state. *)
let record_success ~agent_name =
  Circuit_breaker.record_success_global ~agent_id:agent_name

(** Record a failed action — may open the breaker. *)
let record_failure ~agent_name ~reason =
  Circuit_breaker.record_failure_global ~agent_id:agent_name ~reason

(** {1 Batch Filtering} *)

(** Filter a list of agent names to only healthy ones.
    Returns (healthy_agents, skipped_with_reasons). *)
let filter_healthy (agents : (string * 'a) list) : (string * 'a) list * (string * string) list =
  let healthy = ref [] in
  let skipped = ref [] in
  List.iter (fun (name, data) ->
    match check_health ~agent_name:name with
    | Healthy | Recovering ->
        healthy := (name, data) :: !healthy
    | Unhealthy reason ->
        skipped := (name, reason) :: !skipped;
        Log.debug ~ctx:"agent_health" "Skipping %s: %s" name reason
    | Unknown raw ->
        (* Issue #8607: fail-closed for unrecognised breaker states.
           Surface the raw value so operators can investigate. *)
        let reason = Printf.sprintf "unknown breaker state %S" raw in
        skipped := (name, reason) :: !skipped;
        Log.debug ~ctx:"agent_health" "Skipping %s: %s" name reason
  ) agents;
  (List.rev !healthy, List.rev !skipped)

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

(** Get health summaries for all known agents. *)
let get_all_summaries () : agent_health_summary list =
  let breakers = Circuit_breaker.list_all_breakers (Eio.Lazy.force Circuit_breaker.global) in
  List.map (fun (s : Circuit_breaker.breaker_status) ->
    {
      agent_name = s.agent_id;
      status =
        health_status_of_breaker
          ~state_name:s.state_name
          ~open_reason:s.open_reason;
      recent_failures = s.recent_failures;
      cooldown_remaining_sec = cooldown_remaining_of s.open_until;
    }
  ) breakers

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
