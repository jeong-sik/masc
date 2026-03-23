(** Agent Health — Lodge-specific health gate over Circuit Breaker.

    Wraps Circuit_breaker with agent-name semantics for Lodge Heartbeat.
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
      if status.state_name = "half_open" then Recovering
      else Healthy
  | Error reason ->
      Unhealthy reason

(** Convenience predicate: can this agent participate? *)
let is_healthy ~agent_name : bool =
  match check_health ~agent_name with
  | Healthy | Recovering -> true
  | Unhealthy _ -> false

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
        Printf.printf "[agent_health] Skipping %s: %s\n%!" name reason
  ) agents;
  (List.rev !healthy, List.rev !skipped)

(** {1 Statistics} *)

(** Get health summary for a single agent. *)
let get_summary ~agent_name : agent_health_summary =
  let status = Circuit_breaker.get_status_global ~agent_id:agent_name in
  let health_status = match status.state_name with
    | "closed" -> Healthy
    | "half_open" -> Recovering
    | "open" -> Unhealthy (Option.value ~default:"unknown" status.open_reason)
    | _ -> Healthy
  in
  let cooldown_remaining = match status.open_until with
    | Some until ->
        let remaining = until -. Time_compat.now () in
        if remaining > 0.0 then int_of_float remaining else 0
    | None -> 0
  in
  {
    agent_name;
    status = health_status;
    recent_failures = status.recent_failures;
    cooldown_remaining_sec = cooldown_remaining;
  }

(** Get health summaries for all known agents. *)
let get_all_summaries () : agent_health_summary list =
  let breakers = Circuit_breaker.list_all_breakers (Eio.Lazy.force Circuit_breaker.global) in
  List.map (fun (s : Circuit_breaker.breaker_status) ->
    let health_status = match s.state_name with
      | "closed" -> Healthy
      | "half_open" -> Recovering
      | "open" -> Unhealthy (Option.value ~default:"unknown" s.open_reason)
      | _ -> Healthy
    in
    let cooldown_remaining = match s.open_until with
      | Some until ->
          let remaining = until -. Time_compat.now () in
          if remaining > 0.0 then int_of_float remaining else 0
      | None -> 0
    in
    {
      agent_name = s.agent_id;
      status = health_status;
      recent_failures = s.recent_failures;
      cooldown_remaining_sec = cooldown_remaining;
    }
  ) breakers

(** {1 JSON Serialization} *)

let health_status_to_string = function
  | Healthy -> "healthy"
  | Unhealthy _ -> "unhealthy"
  | Recovering -> "recovering"

let summary_to_json (s : agent_health_summary) : Yojson.Safe.t =
  `Assoc [
    ("agent_name", `String s.agent_name);
    ("status", `String (health_status_to_string s.status));
    ("recent_failures", `Int s.recent_failures);
    ("cooldown_remaining_sec", `Int s.cooldown_remaining_sec);
  ]
