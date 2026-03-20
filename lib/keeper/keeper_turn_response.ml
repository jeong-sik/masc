(** Keeper_turn_response -- turn_env type, JSON builders, finalize.

    Extracted from keeper_turn.ml.  Builds metrics JSONL and response JSON
    for both normal turns and handoff turns. *)

open Keeper_types
open Keeper_memory
open Keeper_alerting
open Keeper_execution

(* ── Shared types and helpers for handle_keeper_msg decomposition ───── *)

(** Captures all turn-level values needed by the response builder. *)
type turn_env = {
  meta_turn : keeper_meta;
  safe_reply : string;
  final_usage : Agent_sdk.Types.api_usage;
  final_model_used : string;
  final_latency_ms : int;
  total_cost_usd_turn : float;
  ctx_ratio : float;
  ctx_work : Context_manager.working_context;
  compacted : bool;
  before_compact_tokens : int;
  after_compact_tokens : int;
  compaction_trigger : string option;
  compaction_decision : string;
  work_kind : string;
  tool_call_count : int;
  tools_used : string list;
  effective_skill_route : keeper_skill_route;
  skill_route_resolution : keeper_skill_route_resolution;
  memory_check_json : Yojson.Safe.t;
  auto_rules : keeper_auto_rule_eval;
  drift_applied : bool;
  drift_reason : string option;
  repetition_risk : float;
  goal_alignment : float;
  response_alignment : float;
  memory_notes_added : int;
  memory_note_kinds : string list;
  memory_top_kind : string option;
  memory_compaction : memory_bank_compaction;
  interesting_alert : interesting_alert_result;
}

(** Build the common JSON fields shared between normal-turn and handoff metrics/response. *)
let build_turn_metrics_fields (env : turn_env) : (string * Yojson.Safe.t) list =
  let meta = env.meta_turn in
  [
    ("model_used", `String env.final_model_used);
    ("usage", `Assoc [
      ("input_tokens", `Int env.final_usage.input_tokens);
      ("output_tokens", `Int env.final_usage.output_tokens);
      ("total_tokens", `Int ((env.final_usage.input_tokens + env.final_usage.output_tokens)));
    ]);
    ("latency_ms", `Int env.final_latency_ms);
    ("cost_usd", `Float env.total_cost_usd_turn);
    ("context_ratio", `Float env.ctx_ratio);
    ("context_tokens", `Int env.ctx_work.token_count);
    ("context_max", `Int env.ctx_work.max_tokens);
    ("message_count", `Int (List.length env.ctx_work.messages));
    ("compacted", `Bool env.compacted);
    ("compaction_before_tokens", `Int env.before_compact_tokens);
    ("compaction_after_tokens", `Int env.after_compact_tokens);
    ( "compaction_trigger",
      match env.compaction_trigger with
      | Some reason -> `String reason
      | None -> `Null );
    ("compaction_decision", `String env.compaction_decision);
    ("work_kind", `String env.work_kind);
    ("tool_call_count", `Int env.tool_call_count);
    ("tools_used", `List (List.map (fun s -> `String s) env.tools_used));
    ("skill_primary", `String env.effective_skill_route.primary_skill);
    ("skill_secondary",
      `List (List.map (fun s -> `String s) env.effective_skill_route.secondary_skills));
    ("skill_reason", `String env.effective_skill_route.reason);
    ("skill_selection_mode",
      `String env.skill_route_resolution.selection_mode);
    ("skill_provenance",
      `String env.skill_route_resolution.provenance);
    ("memory_check", env.memory_check_json);
    ("auto_rules", keeper_auto_rule_eval_to_json env.auto_rules);
    ("reflection", keeper_reflection_payload_of_auto_rules env.auto_rules);
    ("auto_reflect", `Bool env.auto_rules.reflect);
    ("auto_plan", `Bool env.auto_rules.plan);
    ("auto_compact", `Bool env.auto_rules.compact);
    ("auto_handoff", `Bool env.auto_rules.handoff);
    ("guardrail_stop", `Bool env.auto_rules.guardrail_stop);
    ("guardrail_stop_reason",
      match env.auto_rules.guardrail_reason with
      | Some reason -> `String reason
      | None -> `Null);
    ("repetition_risk", `Float env.repetition_risk);
    ("goal_alignment", `Float env.goal_alignment);
    ("response_alignment", `Float env.response_alignment);
    ("goal_drift", `Float env.auto_rules.goal_drift);
    ("drift", `Assoc [
      ("enabled", `Bool meta.drift_enabled);
      ("applied", `Bool env.drift_applied);
      ("reason",
        match env.drift_reason with
        | Some reason -> `String reason
        | None -> `Null);
      ("min_turn_gap", `Int meta.drift_min_turn_gap);
      ("count_total", `Int meta.drift_count_total);
      ("last_turn", `Int meta.last_drift_turn);
      ("last_reason",
        if String.trim meta.last_drift_reason = ""
        then `Null
        else `String meta.last_drift_reason);
    ]);
    ("memory_notes_added", `Int env.memory_notes_added);
    ("memory_note_kinds",
      `List (List.map (fun s -> `String s) env.memory_note_kinds));
    ("memory_top_kind",
      match env.memory_top_kind with
      | Some kind -> `String kind
      | None -> `Null);
    ("memory_compaction_performed", `Bool env.memory_compaction.performed);
    ("memory_compaction_reason",
      match env.memory_compaction.reason with
      | Some reason -> `String reason
      | None -> `Null);
    ("memory_compaction_target_notes", `Int env.memory_compaction.target_notes);
    ("memory_compaction_before_notes", `Int env.memory_compaction.before_notes);
    ("memory_compaction_after_notes", `Int env.memory_compaction.after_notes);
    ("memory_compaction_dropped_notes", `Int env.memory_compaction.dropped_notes);
    ("memory_compaction_dedup_dropped", `Int env.memory_compaction.dedup_dropped);
    ("memory_compaction_invalid_dropped", `Int env.memory_compaction.invalid_dropped);
  ]

(** Build the metrics JSONL for a normal turn (no handoff). *)
let build_normal_turn_metrics_json ~now_ts (env : turn_env) : Yojson.Safe.t =
  let meta = env.meta_turn in
  `Assoc ([
    ("ts", `String (now_iso ()));
    ("ts_unix", `Float now_ts);
    ("channel", `String "turn");
    ("name", `String meta.name);
    ("agent_name", `String meta.agent_name);
    ("trace_id", `String meta.trace_id);
    ("generation", `Int meta.generation);
  ] @ build_turn_metrics_fields env @ [
    ("interesting_alert_triggered", `Bool env.interesting_alert.triggered);
    ("interesting_alert_score", `Float env.interesting_alert.score);
    ("interesting_alert", interesting_alert_result_to_json env.interesting_alert);
    ("handoff", `Assoc [("performed", `Bool false)]);
  ])

(** Build the response JSON for a normal turn (no handoff). *)
let build_normal_turn_response_json (env : turn_env) : Yojson.Safe.t =
  let meta = env.meta_turn in
  `Assoc ([
    ("name", `String meta.name);
    ("trace_id", `String meta.trace_id);
    ("generation", `Int meta.generation);
    ("soul_profile", `String meta.soul_profile);
    ("will", if String.trim meta.will = "" then `Null else `String meta.will);
    ("needs", if String.trim meta.needs = "" then `Null else `String meta.needs);
    ("desires", if String.trim meta.desires = "" then `Null else `String meta.desires);
    ("model_used", `String env.final_model_used);
    ("usage", `Assoc [
      ("input_tokens", `Int env.final_usage.input_tokens);
      ("output_tokens", `Int env.final_usage.output_tokens);
      ("total_tokens", `Int ((env.final_usage.input_tokens + env.final_usage.output_tokens)));
    ]);
    ("latency_ms", `Int env.final_latency_ms);
    ("cost_usd", `Float env.total_cost_usd_turn);
    ("reply", `String env.safe_reply);
    ("context_ratio", `Float env.ctx_ratio);
    ("compacted", `Bool env.compacted);
    ( "compaction_trigger",
      match env.compaction_trigger with
      | Some reason -> `String reason
      | None -> `Null );
    ("work_kind", `String env.work_kind);
    ("tool_call_count", `Int env.tool_call_count);
    ("tools_used", `List (List.map (fun s -> `String s) env.tools_used));
    ("skill_primary", `String env.effective_skill_route.primary_skill);
    ("skill_secondary",
      `List (List.map (fun s -> `String s) env.effective_skill_route.secondary_skills));
    ("skill_reason", `String env.effective_skill_route.reason);
    ("skill_selection_mode",
      `String env.skill_route_resolution.selection_mode);
    ("skill_provenance",
      `String env.skill_route_resolution.provenance);
    ("memory_check", env.memory_check_json);
    ("auto_rules", keeper_auto_rule_eval_to_json env.auto_rules);
    ("reflection", keeper_reflection_payload_of_auto_rules env.auto_rules);
    ("auto_reflect", `Bool env.auto_rules.reflect);
    ("auto_plan", `Bool env.auto_rules.plan);
    ("auto_compact", `Bool env.auto_rules.compact);
    ("auto_handoff", `Bool env.auto_rules.handoff);
    ("guardrail_stop", `Bool env.auto_rules.guardrail_stop);
    ("guardrail_stop_reason",
      match env.auto_rules.guardrail_reason with
      | Some reason -> `String reason
      | None -> `Null);
    ("repetition_risk", `Float env.repetition_risk);
    ("goal_alignment", `Float env.goal_alignment);
    ("response_alignment", `Float env.response_alignment);
    ("goal_drift", `Float env.auto_rules.goal_drift);
    ("drift", `Assoc [
      ("enabled", `Bool meta.drift_enabled);
      ("applied", `Bool env.drift_applied);
      ("reason",
        match env.drift_reason with
        | Some reason -> `String reason
        | None -> `Null);
      ("min_turn_gap", `Int meta.drift_min_turn_gap);
      ("count_total", `Int meta.drift_count_total);
      ("last_turn", `Int meta.last_drift_turn);
      ("last_reason",
        if String.trim meta.last_drift_reason = ""
        then `Null
        else `String meta.last_drift_reason);
    ]);
    ("memory_notes_added", `Int env.memory_notes_added);
    ("memory_note_kinds",
      `List (List.map (fun s -> `String s) env.memory_note_kinds));
    ("memory_top_kind",
      match env.memory_top_kind with
      | Some kind -> `String kind
      | None -> `Null);
    ("memory_compaction_performed", `Bool env.memory_compaction.performed);
    ("memory_compaction_reason",
      match env.memory_compaction.reason with
      | Some reason -> `String reason
      | None -> `Null);
    ("memory_compaction_target_notes", `Int env.memory_compaction.target_notes);
    ("memory_compaction_before_notes", `Int env.memory_compaction.before_notes);
    ("memory_compaction_after_notes", `Int env.memory_compaction.after_notes);
    ("memory_compaction_dropped_notes", `Int env.memory_compaction.dropped_notes);
    ("memory_compaction_dedup_dropped", `Int env.memory_compaction.dedup_dropped);
    ("memory_compaction_invalid_dropped", `Int env.memory_compaction.invalid_dropped);
    ("interesting_alert", interesting_alert_result_to_json env.interesting_alert);
  ])

(** Build the handoff metrics JSONL entry. *)
let build_handoff_metrics_json ~now_ts ~prev_trace_id ~next_model_id ~new_generation
    (env : turn_env) : Yojson.Safe.t =
  let meta = env.meta_turn in
  `Assoc ([
    ("ts", `String (now_iso ()));
    ("ts_unix", `Float now_ts);
    ("channel", `String "turn");
    ("name", `String meta.name);
    ("agent_name", `String meta.agent_name);
    ("trace_id", `String prev_trace_id);
    ("generation", `Int meta.generation);
  ] @ build_turn_metrics_fields env @ [
    ("interesting_alert_triggered", `Bool env.interesting_alert.triggered);
    ("interesting_alert_score", `Float env.interesting_alert.score);
    ("interesting_alert", interesting_alert_result_to_json env.interesting_alert);
    ("handoff", `Assoc [
      ("performed", `Bool true);
      ("prev_trace_id", `String prev_trace_id);
      ("new_trace_id", `String env.meta_turn.trace_id);
      ("to_model", `String next_model_id);
      ("new_generation", `Int new_generation);
    ]);
  ])

(** Build the handoff response JSON. *)
let build_handoff_response_json ~prev_trace_id ~next_model_id ~new_generation
    (env : turn_env) : Yojson.Safe.t =
  let meta = env.meta_turn in
  `Assoc [
    ("name", `String meta.name);
    ("soul_profile", `String meta.soul_profile);
    ("will", if String.trim meta.will = "" then `Null else `String meta.will);
    ("needs", if String.trim meta.needs = "" then `Null else `String meta.needs);
    ("desires", if String.trim meta.desires = "" then `Null else `String meta.desires);
    ("reply", `String env.safe_reply);
    ("model_used", `String env.final_model_used);
    ("latency_ms", `Int env.final_latency_ms);
    ("cost_usd", `Float env.total_cost_usd_turn);
    ("context_ratio", `Float env.ctx_ratio);
    ("compacted", `Bool env.compacted);
    ( "compaction_trigger",
      match env.compaction_trigger with
      | Some reason -> `String reason
      | None -> `Null );
    ("work_kind", `String env.work_kind);
    ("tool_call_count", `Int env.tool_call_count);
    ("tools_used", `List (List.map (fun s -> `String s) env.tools_used));
    ("skill_primary", `String env.effective_skill_route.primary_skill);
    ("skill_secondary",
      `List (List.map (fun s -> `String s) env.effective_skill_route.secondary_skills));
    ("skill_reason", `String env.effective_skill_route.reason);
    ("skill_selection_mode",
      `String env.skill_route_resolution.selection_mode);
    ("skill_provenance",
      `String env.skill_route_resolution.provenance);
    ("memory_check", env.memory_check_json);
    ("auto_rules", keeper_auto_rule_eval_to_json env.auto_rules);
    ("reflection", keeper_reflection_payload_of_auto_rules env.auto_rules);
    ("auto_reflect", `Bool env.auto_rules.reflect);
    ("auto_plan", `Bool env.auto_rules.plan);
    ("auto_compact", `Bool env.auto_rules.compact);
    ("auto_handoff", `Bool env.auto_rules.handoff);
    ("guardrail_stop", `Bool env.auto_rules.guardrail_stop);
    ("guardrail_stop_reason",
      match env.auto_rules.guardrail_reason with
      | Some reason -> `String reason
      | None -> `Null);
    ("repetition_risk", `Float env.repetition_risk);
    ("goal_alignment", `Float env.goal_alignment);
    ("response_alignment", `Float env.response_alignment);
    ("goal_drift", `Float env.auto_rules.goal_drift);
    ("drift", `Assoc [
      ("enabled", `Bool meta.drift_enabled);
      ("applied", `Bool env.drift_applied);
      ("reason",
        match env.drift_reason with
        | Some reason -> `String reason
        | None -> `Null);
      ("min_turn_gap", `Int meta.drift_min_turn_gap);
      ("count_total", `Int meta.drift_count_total);
      ("last_turn", `Int meta.last_drift_turn);
      ("last_reason",
        if String.trim meta.last_drift_reason = ""
        then `Null
        else `String meta.last_drift_reason);
    ]);
    ("memory_notes_added", `Int env.memory_notes_added);
    ("memory_note_kinds",
      `List (List.map (fun s -> `String s) env.memory_note_kinds));
    ("memory_top_kind",
      match env.memory_top_kind with
      | Some kind -> `String kind
      | None -> `Null);
    ("memory_compaction_performed", `Bool env.memory_compaction.performed);
    ("memory_compaction_reason",
      match env.memory_compaction.reason with
      | Some reason -> `String reason
      | None -> `Null);
    ("memory_compaction_target_notes", `Int env.memory_compaction.target_notes);
    ("memory_compaction_before_notes", `Int env.memory_compaction.before_notes);
    ("memory_compaction_after_notes", `Int env.memory_compaction.after_notes);
    ("memory_compaction_dropped_notes", `Int env.memory_compaction.dropped_notes);
    ("memory_compaction_dedup_dropped", `Int env.memory_compaction.dedup_dropped);
    ("memory_compaction_invalid_dropped", `Int env.memory_compaction.invalid_dropped);
    ("interesting_alert", interesting_alert_result_to_json env.interesting_alert);
    ("handoff", `Assoc [
      ("performed", `Bool true);
      ("prev_trace_id", `String prev_trace_id);
      ("new_trace_id", `String env.meta_turn.trace_id);
      ("to_model", `String next_model_id);
      ("new_generation", `Int new_generation);
    ]);
  ]

(** Emit SSE events + write metrics + finalize trajectory for a normal turn. *)
let finalize_normal_turn ctx ~session ~now_ts ~trajectory_acc ~gate_config (env : turn_env) : tool_result =
  let meta_turn = env.meta_turn in
  (match write_meta ctx.config meta_turn with
   | Ok () -> ()
   | Error e -> Log.Keeper.error "keeper:%s failed to write meta: %s" meta_turn.name e);
  let metrics_path = keeper_metrics_path ctx.config meta_turn.name in
  (try
     let metrics_json = build_normal_turn_metrics_json ~now_ts env in
     append_jsonl_line metrics_path metrics_json
   with exn ->
     log_keeper_exn ~label:"turn metrics JSONL write failed" exn);
  (* Harness: finalize trajectory with outcome *)
  (let traj_outcome =
    if trajectory_acc.Trajectory.total_cost >= gate_config.Eval_gate.max_cost_usd then
      Trajectory.CostExceeded
    else
      Trajectory.Completed
  in
  let _traj = Trajectory.finalize trajectory_acc traj_outcome in
  Log.Misc.info "Trajectory finalized: %s turns=%d calls=%d cost=$%.4f outcome=%s"
    meta_turn.trace_id
    _traj.Trajectory.total_turns
    _traj.Trajectory.total_tool_calls
    _traj.Trajectory.total_cost_usd
    (Trajectory.outcome_to_string traj_outcome));
  (* SSE: keeper_compaction — emitted only when compaction occurred *)
  (if env.compacted then
    (try Sse.broadcast (`Assoc [
      ("type", `String "keeper_compaction");
      ("name", `String meta_turn.name);
      ("saved_tokens", `Int (env.before_compact_tokens - env.after_compact_tokens));
      ("trigger", match env.compaction_trigger with
        | Some r -> `String r | None -> `Null);
    ]) with exn ->
      log_keeper_exn ~label:"SSE keeper_compaction broadcast failed" exn));
  (* SSE: keeper_turn_complete — emitted on every normal turn finish *)
  (try Sse.broadcast (`Assoc [
    ("type", `String "keeper_turn_complete");
    ("name", `String meta_turn.name);
    ("trace_id", `String meta_turn.trace_id);
    ("generation", `Int meta_turn.generation);
    ("tool_calls", `Int trajectory_acc.Trajectory.total_calls);
    ("compacted", `Bool env.compacted);
    ("context_ratio", `Float env.ctx_ratio);
    ("model_used", `String env.final_model_used);
  ]) with exn ->
    log_keeper_exn ~label:"SSE keeper_turn_complete broadcast failed" exn);
  ignore session;
  let json = build_normal_turn_response_json env in
  (true, Yojson.Safe.pretty_to_string json)

(** Execute handoff: hydrate successor context, rotate trace, emit metrics/SSE. *)
let finalize_handoff_turn ctx ~session ~now_ts ~specs ~primary ~base_dir
    ~trajectory_acc ~gate_config (env : turn_env) : tool_result =
  let meta_turn = env.meta_turn in
  let next_model =
    match specs with
    | _m0 :: m1 :: _ -> m1
    | m0 :: _ -> m0
    | [] -> primary
  in
  let metrics = Succession_oas.{
    total_turns = meta_turn.total_turns;
    total_tokens_used = meta_turn.total_tokens;
    total_cost_usd = meta_turn.total_cost_usd;
    tasks_completed = 0;
    errors_encountered = 0;
    elapsed_seconds = 0.0;
  } in
  let successor_trace = generate_trace_id () in
  let next_generation = meta_turn.generation + 1 in
  let dna = Succession_oas.extract_dna
    ~working_ctx:env.ctx_work
    ~session_ctx:session
    ~goal:meta_turn.goal
    ~generation:next_generation
    ~trace_id:successor_trace
    ~metrics
  in
  let spec = Succession_oas.{
    model = next_model;
    inherit_tools = false;
    context_budget = meta_turn.context_budget;
  } in
  let successor_ctx = Succession_oas.hydrate dna spec in
  let successor_session = Context_manager.create_session
    ~session_id:successor_trace ~base_dir in
  (try ignore (save_checkpoint successor_session successor_ctx ~generation:next_generation)
   with exn -> log_keeper_exn ~label:"save_checkpoint (succession) failed" exn);

  let prev_trace_id = meta_turn.trace_id in
  let trace_history = take 20 (prev_trace_id :: meta_turn.trace_history) in
  let meta' = { meta_turn with
    trace_id = successor_trace;
    trace_history;
    generation = next_generation;
    last_handoff_ts = now_ts;
    updated_at = now_iso ();
  } in
  (try ignore (write_meta ctx.config meta')
   with exn -> log_keeper_exn ~label:"write_meta (succession) failed" exn);

  let metrics_path = keeper_metrics_path ctx.config meta'.name in
  let env_for_handoff = { env with meta_turn = meta' } in
  (try
     let metrics_json = build_handoff_metrics_json
       ~now_ts ~prev_trace_id ~next_model_id:next_model.model_id
       ~new_generation:next_generation env_for_handoff in
     append_jsonl_line metrics_path metrics_json
   with exn ->
     log_keeper_exn ~label:"handoff metrics JSONL write failed" exn);
  (* Harness: finalize trajectory *)
  (let traj_outcome =
    if trajectory_acc.Trajectory.total_cost >= gate_config.Eval_gate.max_cost_usd then
      Trajectory.CostExceeded
    else
      Trajectory.Completed
  in
  ignore (Trajectory.finalize trajectory_acc traj_outcome));
  (* SSE: keeper_handoff — generation succession event *)
  (try Sse.broadcast (`Assoc [
    ("type", `String "keeper_handoff");
    ("name", `String meta_turn.name);
    ("from_generation", `Int meta_turn.generation);
    ("to_generation", `Int next_generation);
    ("to_model", `String next_model.model_id);
  ]) with exn ->
    log_keeper_exn ~label:"SSE keeper_handoff broadcast failed" exn);

  let json = build_handoff_response_json
    ~prev_trace_id ~next_model_id:next_model.model_id
    ~new_generation:next_generation env_for_handoff in
  (true, Yojson.Safe.pretty_to_string json)

(** Build the complete keeper response: emit side-effects + return JSON. *)
let build_keeper_response ctx ~session ~now_ts ~specs ~primary ~base_dir
    ~trajectory_acc ~gate_config ~do_handoff (env : turn_env) : tool_result =
  if not do_handoff then
    finalize_normal_turn ctx ~session ~now_ts ~trajectory_acc ~gate_config env
  else
    finalize_handoff_turn ctx ~session ~now_ts ~specs ~primary ~base_dir
      ~trajectory_acc ~gate_config env

