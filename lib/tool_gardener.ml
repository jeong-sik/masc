(** Tool_gardener — MCP Tool Handlers for Gardener Agent

    Provides MCP tool endpoints for:
    - [masc_gardener_health]: Get ecosystem health metrics
    - [masc_gardener_propose_spawn]: Propose spawning a new agent
    - [masc_gardener_retire_agent]: Propose retiring an agent
    - [masc_gardener_config]: Get current configuration
*)

open Gardener_types
open Tool_args

type result = bool * string

let spawn_decision_provenance ~(decision_path : string)
    (_decision : spawn_decision) =
  match String.lowercase_ascii (String.trim decision_path) with
  | "judgment" -> "judgment"
  | _ -> "fallback"

let retirement_decision_provenance (_decision : retirement_decision) =
  "fallback"

(** {1 Tool Handlers} *)

(** Handle masc_gardener_health tool call.

    Returns comprehensive ecosystem health metrics including:
    - Agent population (total, active, idle)
    - Activity metrics (posts, comments, unanswered questions)
    - Homeostatic score and intervention needs
    - Daily budget status *)
let handle_health _ctx _args : result =
  try
    let health = Gardener.get_health () in
    let config = Gardener.get_config () in

    let json = `Assoc [
      ("status", `String "ok");
      ("provenance", `String "derived");
      ("authoritative", `Bool false);
      ("health_kind", `String "derived_snapshot");
      ("informational_only_fields", `List [`String "needs_spawn"; `String "needs_retirement"]);
      ("health", ecosystem_health_to_yojson health);
      ("config_summary", `Assoc [
        ("enabled", `Bool config.enabled);
        ("min_agents", `Int config.min_agents);
        ("target_agents", `Int config.target_agents);
        ("max_agents", `Int config.max_agents);
        ("max_daily_spawns", `Int config.max_daily_spawns);
        ("max_daily_retirements", `Int config.max_daily_retirements);
      ]);
      ("gardener_disabled", `Bool (not config.enabled));
      ("recommendations", `List (
        if not config.enabled then []
        else
          (if health.needs_spawn then [`String "Consider spawning new agents"] else []) @
          (if health.needs_retirement then [`String "Consider retiring idle agents"] else []) @
          (if health.needs_workers then [`String (Printf.sprintf "Task pressure: %d unclaimed tasks, workers needed" health.task_backlog.todo_count)] else []) @
          (if health.homeostatic_score < 0.5 then [`String "Ecosystem imbalanced, intervention recommended"] else [])
      ));
    ] in
    (true, Yojson.Safe.to_string json)
  with exn ->
    (false, Printf.sprintf "Error getting health: %s" (Printexc.to_string exn))

(** Handle masc_gardener_status tool call.

    Returns truth-only runtime state for the current gardener loop. *)
let handle_status _ctx _args : result =
  try
    let json = `Assoc [
      ("status", `String "ok");
      ("provenance", `String "truth");
      ("authoritative", `Bool true);
      ("runtime", Gardener.status_json ());
    ] in
    (true, Yojson.Safe.to_string json)
  with exn ->
    (false, Printf.sprintf "Error getting gardener status: %s" (Printexc.to_string exn))

(** Handle masc_gardener_propose_spawn tool call.

    Evaluates whether a new agent should be spawned for a given topic.
    Uses LLM decision if enabled, otherwise rule-based.

    Parameters:
    - topic: The role/topic for the new agent (required)
    - reason: Why this agent is needed (optional)
    - urgency: low/medium/high/critical (default: medium) *)
let handle_propose_spawn _ctx args : result =
  try
    let topic = get_string args "topic" "" in
    if topic = "" then
      (false, "Missing required parameter: topic")
    else
    let config = Gardener.get_config () in
    if not config.enabled then
      (false, "Gardener is disabled. Enable with MASC_GARDENER_ENABLED=true")
    else begin
      let reason = get_string args "reason" "Manual spawn request" in
      let urgency_str = get_string args "urgency" "medium" in
      let urgency = urgency_of_string urgency_str in

      let decision, decision_path =
        Gardener.propose_spawn_with_provenance ~topic ~reason ~urgency
      in
      let decision_provenance =
        spawn_decision_provenance ~decision_path decision
      in

      let json = `Assoc [
        ("status", `String "ok");
        ("provenance", `String decision_provenance);
        ("authoritative", `Bool false);
        ("decision", spawn_decision_to_yojson decision);
        ("topic", `String topic);
        ("can_execute", `Bool (match decision with SpawnApproved _ -> true | _ -> false));
      ] in
      (true, Yojson.Safe.to_string json)
    end
  with exn ->
    (false, Printf.sprintf "Error proposing spawn: %s" (Printexc.to_string exn))

(** Handle masc_gardener_retire_agent tool call.

    Evaluates whether an agent should be retired.
    Checks population minimums, idle thresholds, and recent contributions.

    Parameters:
    - agent_name: Name of the agent to consider (required) *)
let handle_retire_agent _ctx args : result =
  try
    let agent_name = get_string args "agent_name" "" in
    if agent_name = "" then
      (false, "Missing required parameter: agent_name")
    else
    let config = Gardener.get_config () in
    if not config.enabled then
      (false, "Gardener is disabled. Enable with MASC_GARDENER_ENABLED=true")
    else begin
      let decision = Gardener.propose_retire ~agent_name in
      let decision_provenance = retirement_decision_provenance decision in

      let json = `Assoc [
        ("status", `String "ok");
        ("provenance", `String decision_provenance);
        ("authoritative", `Bool false);
        ("decision", retirement_decision_to_yojson decision);
        ("agent_name", `String agent_name);
        ("can_execute", `Bool (match decision with RetireApproved _ -> true | _ -> false));
      ] in
      (true, Yojson.Safe.to_string json)
    end
  with exn ->
    (false, Printf.sprintf "Error proposing retirement: %s" (Printexc.to_string exn))

(** Handle masc_gardener_config tool call.

    Returns the current Gardener configuration from environment variables. *)
let handle_config _ctx _args : result =
  try
    let config = Gardener.get_config () in
    let json = `Assoc [
      ("status", `String "ok");
      ("provenance", `String "truth");
      ("authoritative", `Bool true);
      ("config", gardener_config_to_yojson config);
      ("circuit_breaker", `Assoc [
        ("is_open", `Bool (Gardener.is_circuit_open ()));
      ]);
      ("can_spawn", `Bool (Gardener.can_spawn ~config));
      ("can_retire", `Bool (Gardener.can_retire ~config));
    ] in
    (true, Yojson.Safe.to_string json)
  with exn ->
    (false, Printf.sprintf "Error getting config: %s" (Printexc.to_string exn))

(** Handle masc_gardener_execute_spawn tool call.

    Actually execute a spawn that was previously approved.
    This creates the agent in Neo4j and posts announcements.

    Parameters:
    - topic: The topic that was approved (required)
    - urgency: The urgency level (default: medium) *)
let handle_execute_spawn _ctx args : result =
  try
    let topic = get_string args "topic" "" in
    if topic = "" then
      (false, "Missing required parameter: topic")
    else begin
      let reason = get_string args "reason" "Manual spawn execution" in
      let urgency_str = get_string args "urgency" "medium" in
      let urgency = urgency_of_string urgency_str in

      (* First get approval *)
      let decision, _decision_path =
        Gardener.propose_spawn_with_provenance ~topic ~reason ~urgency
      in

      (* Then execute if approved *)
      match decision with
      | SpawnApproved _ ->
          (match Gardener.execute_spawn ~decision with
           | Ok name ->
               let json = `Assoc [
                 ("status", `String "ok");
                 ("spawned", `String name);
                 ("message", `String (Printf.sprintf "Agent '%s' spawned successfully" name));
               ] in
               (true, Yojson.Safe.to_string json)
           | Error e ->
               (false, Printf.sprintf "Spawn execution failed: %s" e))
      | SpawnDeferred { reason; retry_after_sec; _ } ->
          let json = `Assoc [
            ("status", `String "deferred");
            ("reason", `String reason);
            ("retry_after_sec", `Float retry_after_sec);
          ] in
          (true, Yojson.Safe.to_string json)
      | SpawnRejected { reason; _ } ->
          (false, Printf.sprintf "Spawn rejected: %s" reason)
    end
  with exn ->
    (false, Printf.sprintf "Error executing spawn: %s" (Printexc.to_string exn))

(** Handle masc_gardener_execute_retire tool call.

    Actually execute a retirement that was previously approved.
    This initiates the grace period and posts warnings.

    Parameters:
    - agent_name: Name of the agent to retire (required) *)
let handle_execute_retire _ctx args : result =
  try
    let agent_name = get_string args "agent_name" "" in
    if agent_name = "" then
      (false, "Missing required parameter: agent_name")
    else begin
      (* First get approval *)
      let decision = Gardener.propose_retire ~agent_name in

      (* Then execute if approved *)
      match decision with
      | RetireApproved _ ->
          (match Gardener.execute_retire ~decision with
           | Ok name ->
               let json = `Assoc [
                 ("status", `String "ok");
                 ("retired", `String name);
                 ("message", `String (Printf.sprintf "Retirement initiated for '%s'" name));
               ] in
               (true, Yojson.Safe.to_string json)
           | Error e ->
               (false, Printf.sprintf "Retirement execution failed: %s" e))
      | RetireDeferred { reason; retry_after_sec; _ } ->
          let json = `Assoc [
            ("status", `String "deferred");
            ("reason", `String reason);
            ("retry_after_sec", `Float retry_after_sec);
          ] in
          (true, Yojson.Safe.to_string json)
      | RetireRejected { reason; _ } ->
          (false, Printf.sprintf "Retirement rejected: %s" reason)
    end
  with exn ->
    (false, Printf.sprintf "Error executing retirement: %s" (Printexc.to_string exn))

(** Handle masc_gardener_reset_circuit tool call.

    Manually reset the circuit breaker if it's stuck open.
    Use with caution — only when you've addressed the root cause. *)
let handle_reset_circuit _ctx _args : result =
  try
    let was_open = Gardener.is_circuit_open () in
    Gardener.reset_circuit ();
    let json = `Assoc [
      ("status", `String "ok");
      ("was_open", `Bool was_open);
      ("message", `String (if was_open then "Circuit breaker reset" else "Circuit was already closed"));
    ] in
    (true, Yojson.Safe.to_string json)
  with exn ->
    (false, Printf.sprintf "Error resetting circuit: %s" (Printexc.to_string exn))

let schemas : Types.tool_schema list = [
  {
    name = "masc_gardener_status";
    description = "Get truth-only gardener loop runtime status. Returns liveness, last tick timestamps, last decision source, last action, last error, cooldown/circuit state, and the last observed health summary.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_gardener_reset_circuit";
    description = "Manually reset the circuit breaker if it's stuck open due to consecutive failures. Use with caution — only when you've addressed the root cause of the failures.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
]

(** {1 Tool Dispatcher} *)

(** Dispatch gardener tool calls to appropriate handlers *)
let dispatch ctx tool_name args : result =
  match tool_name with
  | "masc_gardener_health" -> handle_health ctx args
  | "masc_gardener_status" -> handle_status ctx args
  | "masc_gardener_propose_spawn" -> handle_propose_spawn ctx args
  | "masc_gardener_retire_agent" -> handle_retire_agent ctx args
  | "masc_gardener_config" -> handle_config ctx args
  | "masc_gardener_execute_spawn" -> handle_execute_spawn ctx args
  | "masc_gardener_execute_retire" -> handle_execute_retire ctx args
  | "masc_gardener_reset_circuit" -> handle_reset_circuit ctx args
  | _ -> (false, Printf.sprintf "Unknown gardener tool: %s" tool_name)
