(** Gardener — Self-Organizing Agent Ecosystem Manager (OAS-integrated).

    Implements autonomous management of the agent ecosystem:
    - Health monitoring with homeostatic balance
    - Spawn decisions based on gap signals and ecosystem needs
    - Retirement decisions for idle/redundant agents
    - Background loop with circuit breaker protection

    Design principles:
    - {b Inverse-U Reward}: Both over- and under-population are penalized
    - {b Safety First}: Hard limits, budgets, cooldowns, circuit breaker
    - {b LLM-Assisted}: Complex decisions can use LLM for nuanced judgment

    OAS integration: exports Agent Card, publishes events via Event_bus,
    uses Pulse for tick scheduling (replaces raw Eio.Time.sleep loop). *)

[@@@warning "-32-69"]

open Gardener_types

include Gardener_decisions

(* ââ OAS Agent Card âââââââââââââââââââââââââââââââââââââââââ *)

let agent_card : Agent_card.agent_card = {
  name = "gardener";
  version = "2.95.1";
  description = Some "Self-organizing agent ecosystem manager: spawn, retire, homeostatic balance";
  provider = Some { organization = "MASC"; url = None };
  protocol_versions = ["0.3"];
  capabilities = { streaming = false; push_notifications = false; extended_agent_card = false };
  skills = [
    { id = "health-monitor"; name = "Health Monitor";
      description = Some "Calculate ecosystem health metrics and homeostatic score";
      tags = ["monitoring"]; tool_count = 1;
      input_modes = []; output_modes = ["application/json"] };
    { id = "spawn-decision"; name = "Spawn Decision";
      description = Some "Evaluate and execute agent spawn proposals";
      tags = ["lifecycle"]; tool_count = 2;
      input_modes = ["application/json"]; output_modes = ["application/json"] };
    { id = "retire-decision"; name = "Retire Decision";
      description = Some "Evaluate and execute agent retirement proposals";
      tags = ["lifecycle"]; tool_count = 2;
      input_modes = ["application/json"]; output_modes = ["application/json"] };
  ];
  supported_interfaces = [];
  security_schemes = [];
  default_input_modes = ["application/json"];
  default_output_modes = ["application/json"];
  extensions = [];
  signatures = [];
  icon_url = None;
  documentation_url = None;
  created_at = "2026-03-16T00:00:00Z";
  updated_at = "2026-03-16T00:00:00Z";
}

(* ââ Event_bus + Pulse refs ââââââââââââââââââââââââââââââââââââââ *)

let bus_ref : Agent_sdk.Event_bus.t option ref = ref None
let gardener_pulse_ref : Pulse.t option ref = ref None

let publish_event name payload =
  match !bus_ref with
  | Some bus ->
      Agent_sdk.Event_bus.publish bus
        (Agent_sdk.Event_bus.Custom (name, payload))
  | None -> ()


(** Calculate comprehensive ecosystem health *)
let calculate_health ~config ~room_config : ecosystem_health =
  (* BUG-002 fix: count agents from Room filesystem (same source as masc_agents)
     to ensure consistency across endpoints *)
  let total_agents = match room_config with
    | Some rc ->
        let room_id = Room.current_room_id rc in
        List.length (Room.get_agents_raw_in_room rc room_id)
    | None ->
        (* No room_config available, assume 0 agents *)
        0
  in
  let all_stats = Thompson_sampling.get_all_stats () in
  let now = Time_compat.now () in
  let idle_threshold_sec = config.idle_threshold_hours *. 3600.0 in

  let active_agents, idle_agents = List.fold_left (fun (active, idle) (s : Thompson_sampling.agent_stats) ->
    let time_since = now -. s.last_selected_at in
    if time_since < 86400.0 then (active + 1, idle)
    else if time_since > idle_threshold_sec then (active, idle + 1)
    else (active, idle)
  ) (0, 0) all_stats in

  (* Activity metrics from Board *)
  let store = Board.global () in
  let posts = Board.list_posts store ~limit:50 () in
  let posts_24h = List.fold_left (fun count (p : Board.post) ->
    if now -. p.created_at < 86400.0 then count + 1 else count
  ) 0 posts in

  let all_comments = Board.list_comments store ~limit:1000 () in
  let comments_24h = List.fold_left (fun count (cm : Board.comment) ->
    if now -. cm.created_at < 86400.0 then count + 1 else count
  ) 0 all_comments in

  let unanswered_questions = count_unanswered_questions () in

  (* Calculate metrics *)
  let selection_entropy = calculate_entropy all_stats in
  let homeostatic_score = calculate_homeostatic_score ~config ~total_agents in

  (* Task backlog signals *)
  let task_backlog = match room_config with
    | Some rc -> collect_task_signals ~room_config:rc
    | None -> empty_task_backlog
  in

  (* Count non-Inactive agents in room (realtime, not Lodge 24h) *)
  let room_active_agents = match room_config with
    | Some rc ->
        let room_id = Room.current_room_id rc in
        let agents = Room.get_agents_raw_in_room rc room_id in
        List.length (List.filter (fun (agent : Types.agent) ->
          match agent.status with
          | Types.Active | Types.Busy | Types.Listening -> true
          | Types.Inactive -> false
        ) agents)
    | None -> 0
  in

  (* No heuristic gates — these fields are purely informational summaries.
     All decision-making is delegated to LLM (primary) or rule-based inline (fallback).
     Raw signals (agent counts, task_backlog, Board data) flow directly to the decision layer. *)
  let needs_spawn = false in
  let needs_workers = task_backlog.todo_count > 0 && active_agents < 2 in
  let needs_retirement = false in

  let state = get_state () in
  let last_spawn = if state.last_spawn_attempt > 0.0 then Some state.last_spawn_attempt else None in
  let last_retirement = if state.last_retirement_attempt > 0.0 then Some state.last_retirement_attempt else None in

  (* Calculate overloaded agents and topic coverage *)
  let overloaded_agents = count_overloaded_agents ~posts ~comments:all_comments ~now in
  let topic_coverage = calculate_topic_coverage ~posts in

  {
    total_agents;
    active_agents;
    idle_agents;
    overloaded_agents;
    posts_24h;
    comments_24h;
    unanswered_questions;
    topic_coverage;
    selection_entropy;
    homeostatic_score;
    needs_spawn;
    needs_retirement;
    last_spawn;
    last_retirement;
    spawns_today = state.spawns_today;
    retirements_today = state.retirements_today;
    task_backlog;
    system_error_rate = 0.0;
    needs_workers;
    room_active_agents;
  }

(** {1 Background Loop} *)

(** Main gardener loop iteration *)
let tick ~sw ~clock:_ ~config ~room_config : unit =
  let tick_started_at = mark_tick_start () in
  if is_circuit_open () then begin
    record_decision
      {
        intervention = Balanced;
        source = "none";
        reason = "circuit open; tick skipped";
        target = "";
        error = "";
      };
    record_tick_complete ();
    Eio.traceln "[Gardener] Circuit open, skipping tick"
  end else begin
    let health = calculate_health ~config ~room_config:(Some room_config) in
    record_health_summary ~at:tick_started_at health;
    let backlog = health.task_backlog in
    Eio.traceln
      "[Gardener] Health: agents=%d/%d active=%d idle=%d score=%.2f task_backlog: todo=%d high_pri=%d orphans=%d"
      health.total_agents config.target_agents health.active_agents
      health.idle_agents health.homeostatic_score backlog.todo_count
      backlog.high_priority_todo backlog.orphan_count;

    let decision = detect_intervention_detail ~config ~health in
    record_decision decision;
    match decision.intervention with
    | NeedSpawn gap ->
        Eio.traceln "[Gardener] Intervention needed: spawn %s" gap.topic;
        let spawn_decision = decide_spawn ~config ~health ~gap in
        (match execute_spawn ~sw ~room_config ~decision:spawn_decision () with
         | Ok name ->
             record_action "spawned" ~target:name
               ~reason:(Printf.sprintf "spawned from gap '%s'" gap.topic);
             Eio.traceln "[Gardener] Spawned: %s" name
         | Error e ->
             record_action "none" ~target:gap.topic
               ~reason:"spawn decision did not execute"
               ~error:e;
             Eio.traceln "[Gardener] Spawn failed: %s" e)
    | NeedWorker backlog ->
        Eio.traceln "[Gardener] Task pressure: %d TODO, %d high-pri, %d orphans"
          backlog.todo_count backlog.high_priority_todo backlog.orphan_count;
        let triage_state = get_state () in
        let max_triage_noops = 3 in
        if triage_state.consecutive_triage_noops >= max_triage_noops then begin
          Eio.traceln "[Gardener] Triage backoff: %d consecutive noops (>= %d), skipping"
            triage_state.consecutive_triage_noops max_triage_noops;
          record_action "triage_backoff"
            ~reason:(Printf.sprintf "skipped: %d consecutive noops" triage_state.consecutive_triage_noops)
        end else
        (match Gardener_worker.run_for_backlog ~config:room_config ~backlog with
         | Ok result ->
             triage_state.last_triage_started_at <- Time_compat.now ();
             triage_state.last_triage_outcome <- Triage_productive;
             triage_state.consecutive_triage_noops <- 0;
             record_action "worker_completed" ~target:result.Oas_worker.session_id
               ~reason:(Printf.sprintf "triage done in %d turns" result.Oas_worker.turns);
             Eio.traceln "[Gardener] Triage worker completed: %s (turns=%d)"
               result.Oas_worker.session_id result.Oas_worker.turns;
             Sse.broadcast
               (`Assoc
                 [
                   ("type", `String "gardener_need_worker");
                   ("session_id", `String result.Oas_worker.session_id);
                   ("turns", `Int result.Oas_worker.turns);
                   ("todo_count", `Int backlog.todo_count);
                   ("high_priority_todo", `Int backlog.high_priority_todo);
                   ("orphan_count", `Int backlog.orphan_count);
                 ])
         | Error err ->
             triage_state.last_triage_started_at <- Time_compat.now ();
             triage_state.last_triage_outcome <- Triage_noop;
             triage_state.consecutive_triage_noops <- triage_state.consecutive_triage_noops + 1;
             record_action "worker_failed"
               ~reason:"triage worker failed"
               ~error:err;
             Eio.traceln "[Gardener] Triage worker failed (%d/%d noops): %s"
               triage_state.consecutive_triage_noops max_triage_noops err;
             let store = Board.global () in
             let msg =
               Printf.sprintf
                 "[Gardener] %d unclaimed tasks (P1-P2: %d, oldest: %.1fh). Triage worker failed: %s"
                 backlog.todo_count backlog.high_priority_todo
                 backlog.oldest_todo_age_hours err
             in
             (try
                ignore
                  (Board.create_post store ~author:"gardener" ~content:msg
                     ~ttl_hours:24 ())
              with exn ->
                Eio.traceln "[Gardener] Board post failed: %s"
                  (Printexc.to_string exn));
             Sse.broadcast
               (`Assoc
                 [
                   ("type", `String "gardener_need_worker");
                   ("error", `String err);
                   ("todo_count", `Int backlog.todo_count);
                   ("high_priority_todo", `Int backlog.high_priority_todo);
                   ("orphan_count", `Int backlog.orphan_count);
                 ]))
    | NeedRetirement stats ->
        Eio.traceln "[Gardener] Intervention needed: retire %s" stats.name;
        let retirement_decision = decide_retire ~config ~health ~agent_stats:stats in
        (match execute_retire ~decision:retirement_decision with
         | Ok name ->
             record_action "retirement_initiated" ~target:name
               ~reason:"retirement grace period initiated";
             Eio.traceln "[Gardener] Retirement initiated: %s" name
         | Error e ->
             record_action "none" ~target:stats.name
               ~reason:"retirement decision did not execute"
               ~error:e;
             Eio.traceln "[Gardener] Retirement failed: %s" e)
    | Balanced ->
        record_action "none" ~reason:decision.reason;
        Eio.traceln "[Gardener] Ecosystem balanced";
    record_tick_complete ()
  end

(** Pulse consumer wrapping the existing [tick] function.
    The loop mechanism changes; tick logic stays identical. *)
let make_gardener_consumer ~sw ~clock ~config ~room_config : (module Pulse.Consumer) =
  (module struct
    let name = "gardener-tick"
    let should_act _beat = not (is_circuit_open ())
    let on_beat _beat =
      (try
        tick ~sw ~clock ~config ~room_config;
        publish_event "masc:gardener:tick"
          (`Assoc [
            ("agent_name", `String "gardener");
            ("circuit_open", `Bool false);
            ("timestamp", `Float (Time_compat.now ()));
          ]);
        Ok ()
      with exn ->
        let msg = Printf.sprintf "gardener tick failed: %s" (Printexc.to_string exn) in
        Eio.traceln "[Gardener] %s" msg;
        Error msg)
  end)

(** Sentinel event reactor: subscribes to sentinel task_hygiene events
    and nudges Pulse for immediate reaction. *)
let setup_sentinel_reactor ~(sub : Agent_sdk.Event_bus.subscription) =
  match !gardener_pulse_ref with
  | Some pulse ->
      let events = Agent_sdk.Event_bus.drain sub in
      List.iter (fun ev ->
        match ev with
        | Agent_sdk.Event_bus.Custom ("masc:sentinel:task_hygiene", _payload) ->
            Pulse.nudge pulse ~reason:"sentinel task_hygiene event"
        | _ -> ()
      ) events
  | None -> ()

(** Background fiber: periodically drains sentinel events and nudges Gardener pulse. *)
let start_sentinel_reactor_fiber ~sw ~clock ~sub =
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      Eio.Time.sleep clock 10.0;
      setup_sentinel_reactor ~sub;
      loop ()
    in
    loop ())

(** Start the gardener (called from main server init).
    Uses Pulse for tick scheduling (replaces raw Eio.Time.sleep loop).
    Optionally subscribes to Sentinel events via Event_bus. *)
let start ?bus ~sw ~clock ~room_config () =
  let config = load_config () in
  room_config_ref := Some room_config;
  sw_ref := Some sw;
  bus_ref := bus;
  if config.enabled then begin
    gardener_lock := Some (Eio.Mutex.create ());
    Eio.traceln
      "[Gardener] Starting with config: min=%d target=%d max=%d interval=%.0fs"
      config.min_agents config.target_agents config.max_agents
      config.check_interval_sec;
    let pulse = Pulse.create
      ~clock
      ~rhythm:{ Pulse.base_s = config.check_interval_sec;
                min_s = 60.0;
                max_s = config.check_interval_sec *. 2.0;
                quiet = (3, 7) }
      ~lifecycle:Perpetual
      ~consumers:[make_gardener_consumer ~sw ~clock ~config ~room_config]
    in
    gardener_pulse_ref := Some pulse;
    (match bus with
     | Some b ->
         let sub = Agent_sdk.Event_bus.subscribe b
           ~filter:(function
             | Agent_sdk.Event_bus.Custom (name, _) ->
                 String.length name >= 14 &&
                 String.sub name 0 14 = "masc:sentinel:"
             | _ -> false)
         in
         start_sentinel_reactor_fiber ~sw ~clock ~sub
     | None -> ());
    Pulse.run ~sw pulse
  end else
    Eio.traceln "[Gardener] Disabled (set MASC_GARDENER_ENABLED=true to enable)"

(** {1 Public API for Tools} *)

(** Get current ecosystem health (for MCP tool) *)
let get_health () : ecosystem_health =
  let config = load_config () in
  calculate_health ~config ~room_config:!room_config_ref

(** Propose a spawn (for MCP tool) *)
let propose_spawn ~topic ~reason ~urgency : spawn_decision =
  let config = load_config () in
  let health = calculate_health ~config ~room_config:!room_config_ref in
  let now = Time_compat.now () in
  let gap =
    {
      topic;
      signal_count = 1;
      proposers = [ "manual" ];
      context_snippets = [ reason ];
      first_detected = now;
      maturity_hours = config.gap_maturity_hours;
      topic_similarity = 0.0;
      urgency_score =
        (match urgency with
        | Critical -> 1.0
        | High -> 0.8
        | Medium -> 0.5
        | Low -> 0.3);
    }
  in
  decide_spawn ~config ~health ~gap

let propose_spawn_with_provenance ~topic ~reason ~urgency :
    spawn_decision * string =
  let config = load_config () in
  let health = calculate_health ~config ~room_config:!room_config_ref in
  let now = Time_compat.now () in
  let gap =
    {
      topic;
      signal_count = 1;
      proposers = [ "manual" ];
      context_snippets = [ reason ];
      first_detected = now;
      maturity_hours = config.gap_maturity_hours;
      topic_similarity = 0.0;
      urgency_score =
        (match urgency with
        | Critical -> 1.0
        | High -> 0.8
        | Medium -> 0.5
        | Low -> 0.3);
    }
  in
  decide_spawn_with_provenance ~config ~health ~gap

(** Propose a retirement (for MCP tool) *)
let propose_retire ~agent_name : retirement_decision =
  let config = load_config () in
  let health = calculate_health ~config ~room_config:!room_config_ref in

  (* Get stats for the agent *)
  let ls = Thompson_sampling.get_stats agent_name in
  let stats = convert_stats ls in

  decide_retire ~config ~health ~agent_stats:stats

(** Get configuration (for MCP tool) *)
let get_config () : gardener_config =
  load_config ()
