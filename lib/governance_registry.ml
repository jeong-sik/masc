(** Governance_registry — Governable parameter surface declarations.

    Declares which runtime parameters can be changed by governance decisions.
    Each parameter is registered with [Runtime_params] with validation bounds.

    Surfaces:
    - [board_policy]:      default TTL, message max count (Low risk)
    - [inference_config]:        default model, timeout (High risk)

    @since 2.96.0 *)

(* ── validation helpers ──────────────────────────────────────── *)

let validate_float_range ~min ~max key v =
  if v >= min && v <= max then Ok ()
  else Error (Printf.sprintf "%s must be in [%g, %g], got %g" key min max v)

let validate_int_range ~min ~max key v =
  if v >= min && v <= max then Ok ()
  else Error (Printf.sprintf "%s must be in [%d, %d], got %d" key min max v)

let deserialize_float json =
  match json with
  | `Float f -> Ok f
  | `Int i -> Ok (float_of_int i)
  | _ -> Error "expected number"

let deserialize_int json =
  match json with
  | `Int i -> Ok i
  | `Float f ->
      let i = Float.to_int f in
      if Float.equal (Float.of_int i) f then Ok i
      else Error (Printf.sprintf "expected integer, got %g" f)
  | _ -> Error "expected integer"

let deserialize_string json =
  match json with
  | `String s -> Ok s
  | _ -> Error "expected string"

let deserialize_bool json =
  match json with
  | `Bool b -> Ok b
  | _ -> Error "expected boolean"

(* ── board_policy surface ────────────────────────────────────── *)

let message_max_count =
  Runtime_params.register
    ~key:"message.max_count"
    ~default:(fun () -> Env_config_runtime.Message.max_count)
    ~validate:(validate_int_range ~min:10 ~max:10000 "message_max_count")
    ~serialize:(fun v -> `Int v)
    ~deserialize:deserialize_int
    ()

(* ── inference_config surface (High risk) ──────────────────────────── *)

let inference_default_model =
  Runtime_params.register
    ~key:"inference.default_model"
    ~default:(fun () -> "auto")
    ~validate:(fun v ->
      if String.length v > 0 && String.length v <= 100 then Ok ()
      else Error "model name must be 1-100 chars")
    ~serialize:(fun v -> `String v)
    ~deserialize:deserialize_string
    ()

let inference_timeout =
  Runtime_params.register
    ~key:"inference.timeout_seconds"
    ~default:(fun () -> Env_config_governance.Inference.timeout_seconds)
    ~validate:(validate_float_range ~min:5.0 ~max:300.0 "inference_timeout")
    ~serialize:(fun v -> `Float v)
    ~deserialize:deserialize_float
    ()

(* ── dashboard surface (Low risk, display-only) ──────────────── *)

(** Maximum path length before truncation in dashboard output. *)
let dashboard_max_path_length =
  Runtime_params.register
    ~key:"dashboard.max_path_length"
    ~default:(fun () -> 30)
    ~validate:(validate_int_range ~min:10 ~max:200 "dashboard_max_path_length")
    ~serialize:(fun v -> `Int v)
    ~deserialize:deserialize_int
    ~meta:{ description = "대시보드 경로 출력 최대 길이 (문자)";
            value_type = "int";
            min_value = Some (`Int 10); max_value = Some (`Int 200) }
    ()

(** Maximum message body length before truncation. *)
let dashboard_max_message_length =
  Runtime_params.register
    ~key:"dashboard.max_message_length"
    ~default:(fun () -> 35)
    ~validate:(validate_int_range ~min:10 ~max:500 "dashboard_max_message_length")
    ~serialize:(fun v -> `Int v)
    ~deserialize:deserialize_int
    ~meta:{ description = "대시보드 메시지 출력 최대 길이 (문자)";
            value_type = "int";
            min_value = Some (`Int 10); max_value = Some (`Int 500) }
    ()

(** Maximum number of pending tasks to show in dashboard. *)
let dashboard_max_pending_tasks =
  Runtime_params.register
    ~key:"dashboard.max_pending_tasks"
    ~default:(fun () -> 5)
    ~validate:(validate_int_range ~min:1 ~max:50 "dashboard_max_pending_tasks")
    ~serialize:(fun v -> `Int v)
    ~deserialize:deserialize_int
    ~meta:{ description = "대시보드 pending task 표시 최대 개수";
            value_type = "int";
            min_value = Some (`Int 1); max_value = Some (`Int 50) }
    ()

(** Maximum number of recent messages to show. *)
let dashboard_max_recent_messages =
  Runtime_params.register
    ~key:"dashboard.max_recent_messages"
    ~default:(fun () -> 5)
    ~validate:(validate_int_range ~min:1 ~max:50 "dashboard_max_recent_messages")
    ~serialize:(fun v -> `Int v)
    ~deserialize:deserialize_int
    ~meta:{ description = "대시보드 recent message 표시 최대 개수";
            value_type = "int";
            min_value = Some (`Int 1); max_value = Some (`Int 50) }
    ()

(** Minimum section border length. *)
let dashboard_min_border_length =
  Runtime_params.register
    ~key:"dashboard.min_border_length"
    ~default:(fun () -> 45)
    ~validate:(validate_int_range ~min:20 ~max:200 "dashboard_min_border_length")
    ~serialize:(fun v -> `Int v)
    ~deserialize:deserialize_int
    ~meta:{ description = "대시보드 섹션 경계선 최소 길이";
            value_type = "int";
            min_value = Some (`Int 20); max_value = Some (`Int 200) }
    ()

(** Threshold for surfacing a quiet-agent warning in dashboard labels. *)
let dashboard_agent_quiet_threshold_sec =
  Runtime_params.register
    ~key:"dashboard.agent_quiet_threshold_sec"
    ~default:(fun () -> Env_config_runtime.InternalTimers.label_quiet_threshold_sec)
    ~validate:
      (validate_float_range ~min:30.0 ~max:Masc_time_constants.day
         "dashboard_agent_quiet_threshold_sec")
    ~serialize:(fun v -> `Float v)
    ~deserialize:deserialize_float
    ~meta:
      {
        description = "대시보드 quiet 상태 임계값(초)";
        value_type = "float";
        min_value = Some (`Float 30.0);
        max_value = Some (`Float Masc_time_constants.day);
      }
    ()

(** Threshold for surfacing a stuck-agent warning in dashboard labels. *)
let dashboard_agent_stuck_threshold_sec =
  Runtime_params.register
    ~key:"dashboard.agent_stuck_threshold_sec"
    ~default:(fun () -> Env_config_runtime.InternalTimers.label_stuck_threshold_sec)
    ~validate:
      (validate_float_range ~min:60.0 ~max:(7.0 *. Masc_time_constants.day)
         "dashboard_agent_stuck_threshold_sec")
    ~serialize:(fun v -> `Float v)
    ~deserialize:deserialize_float
    ~meta:
      {
        description = "대시보드 STUCK 상태 임계값(초)";
        value_type = "float";
        min_value = Some (`Float 60.0);
        max_value = Some (`Float (7.0 *. Masc_time_constants.day));
      }
    ()

(* ── cost_policy surface ──────────────────────────────────────── *)

(** Per-session cost ceiling in USD.
    Default 0.50: based on observed keeper sessions averaging $0.02-0.15
    (local llama + GLM fallback). 0.50 is ~3x worst-case observed session cost.
    Governs Eval_gate.max_cost_usd pre-execution gating. *)
let _cost_max_session_usd =
  Runtime_params.register
    ~key:"cost.max_session_usd"
    ~default:(fun () -> 0.50)
    ~validate:(validate_float_range ~min:0.01 ~max:50.0 "cost_max_session_usd")
    ~serialize:(fun v -> `Float v)
    ~deserialize:deserialize_float
    ()

(* ── keeper_lifecycle surface (Medium risk) ─────────────────── *)

let keeper_max_hb_failures =
  Runtime_params.register
    ~key:"keeper.max_consecutive_hb_failures"
    ~default:(fun () -> Env_config_keeper.KeeperKeepalive.max_consecutive_failures)
    ~validate:(validate_int_range ~min:2 ~max:50 "keeper_max_hb_failures")
    ~serialize:(fun v -> `Int v)
    ~meta:{ description = "Heartbeat 연속 실패 허용 횟수";
            value_type = "int";
            min_value = Some (`Int 2); max_value = Some (`Int 50) }
    ~deserialize:deserialize_int
    ()

let keeper_max_turn_failures =
  Runtime_params.register
    ~key:"keeper.max_consecutive_turn_failures"
    ~default:(fun () -> Env_config_keeper.KeeperKeepalive.max_consecutive_turn_failures)
    ~validate:(validate_int_range ~min:3 ~max:100 "keeper_max_turn_failures")
    ~serialize:(fun v -> `Int v)
    ~meta:{ description = "Turn 연속 실패 허용 횟수";
            value_type = "int";
            min_value = Some (`Int 3); max_value = Some (`Int 100) }
    ~deserialize:deserialize_int
    ()

let keeper_supervisor_sweep_sec =
  Runtime_params.register
    ~key:"keeper.supervisor_sweep_sec"
    ~default:(fun () -> Env_config_keeper.KeeperSupervisor.sweep_interval_sec)
    ~validate:(validate_float_range ~min:10.0 ~max:120.0 "keeper_supervisor_sweep_sec")
    ~serialize:(fun v -> `Float v)
    ~meta:{ description = "Supervisor sweep 주기(초)";
            value_type = "float";
            min_value = Some (`Float 10.0); max_value = Some (`Float 120.0) }
    ~deserialize:deserialize_float
    ()

let keeper_supervisor_max_restarts =
  Runtime_params.register
    ~key:"keeper.supervisor_max_restarts"
    ~default:(fun () -> Env_config_keeper.KeeperSupervisor.max_restarts)
    ~validate:(validate_int_range ~min:1 ~max:50 "keeper_supervisor_max_restarts")
    ~serialize:(fun v -> `Int v)
    ~meta:{ description = "Crash 후 재시작 예산";
            value_type = "int";
            min_value = Some (`Int 1); max_value = Some (`Int 50) }
    ~deserialize:deserialize_int
    ()

let keeper_keepalive_interval_sec =
  Runtime_params.register
    ~key:"keeper.keepalive_interval_sec"
    ~default:(fun () -> Env_config_keeper.KeeperKeepalive.interval_sec)
    ~validate:(validate_int_range ~min:5 ~max:300 "keeper_keepalive_interval_sec")
    ~serialize:(fun v -> `Int v)
    ~meta:{ description = "Heartbeat 주기(초)";
            value_type = "int";
            min_value = Some (`Int 5); max_value = Some (`Int 300) }
    ~deserialize:deserialize_int
    ()

let keeper_dead_ttl_sec =
  Runtime_params.register
    ~key:"keeper.dead_ttl_sec"
    ~default:(fun () -> Env_config_keeper.KeeperSupervisor.dead_ttl_sec)
    ~validate:(validate_float_range ~min:60.0 ~max:Masc_time_constants.day "keeper_dead_ttl_sec")
    ~serialize:(fun v -> `Float v)
    ~meta:{ description = "Dead 상태 유지 시간(초)";
            value_type = "float";
            min_value = Some (`Float 60.0); max_value = Some (`Float Masc_time_constants.day) }
    ~deserialize:deserialize_float
    ()

(* ── keeper_handoff surface (Medium risk) ─────────────────────── *)

(** Default handoff threshold (context_ratio).
    When context ratio exceeds this, automatic handoff is considered. *)
let keeper_handoff_threshold =
  Runtime_params.register
    ~key:"keeper.handoff_threshold"
    ~default:(fun () -> 0.85)
    ~validate:(validate_float_range ~min:0.5 ~max:0.99 "keeper.handoff_threshold")
    ~serialize:(fun v -> `Float v)
    ~meta:{ description = "Handoff context ratio 임계값";
            value_type = "float";
            min_value = Some (`Float 0.5); max_value = Some (`Float 0.99) }
    ~deserialize:deserialize_float
    ()

(** Handoff cooldown in seconds.
    After a handoff, suppress further handoffs for this duration. *)
let keeper_handoff_cooldown_sec =
  Runtime_params.register
    ~key:"keeper.handoff_cooldown_sec"
    ~default:(fun () -> 300)
    ~validate:(validate_int_range ~min:30 ~max:3600 "keeper.handoff_cooldown_sec")
    ~serialize:(fun v -> `Int v)
    ~meta:{ description = "Handoff 쿨다운(초)";
            value_type = "int";
            min_value = Some (`Int 30); max_value = Some (`Int 3600) }
    ~deserialize:deserialize_int
    ()

(** Context ratio above which handoff pressure alert fires. *)
let keeper_handoff_pressure_threshold =
  Runtime_params.register
    ~key:"keeper.handoff_pressure_threshold"
    ~default:(fun () -> 0.88)
    ~validate:(validate_float_range ~min:0.5 ~max:0.99 "keeper.handoff_pressure_threshold")
    ~serialize:(fun v -> `Float v)
    ~meta:{ description = "Handoff pressure 알림 임계값";
            value_type = "float";
            min_value = Some (`Float 0.5); max_value = Some (`Float 0.99) }
    ~deserialize:deserialize_float
    ()

(* ── relay_heuristic surface (Low risk) ───────────────────────── *)

let relay_tokens_per_user_msg =
  Runtime_params.register ~key:"relay.tokens_per_user_msg"
    ~default:(fun () -> 150)
    ~validate:(validate_int_range ~min:10 ~max:5000 "relay.tokens_per_user_msg")
    ~serialize:(fun v -> `Int v) ~deserialize:deserialize_int ()

let relay_tokens_per_assistant_msg =
  Runtime_params.register ~key:"relay.tokens_per_assistant_msg"
    ~default:(fun () -> 500)
    ~validate:(validate_int_range ~min:10 ~max:10000 "relay.tokens_per_assistant_msg")
    ~serialize:(fun v -> `Int v) ~deserialize:deserialize_int ()

let relay_tokens_per_tool_call =
  Runtime_params.register ~key:"relay.tokens_per_tool_call"
    ~default:(fun () -> 200)
    ~validate:(validate_int_range ~min:10 ~max:5000 "relay.tokens_per_tool_call")
    ~serialize:(fun v -> `Int v) ~deserialize:deserialize_int ()

let relay_tokens_per_tool_result =
  Runtime_params.register ~key:"relay.tokens_per_tool_result"
    ~default:(fun () -> 300)
    ~validate:(validate_int_range ~min:10 ~max:10000 "relay.tokens_per_tool_result")
    ~serialize:(fun v -> `Int v) ~deserialize:deserialize_int ()

let relay_cost_large_file_read =
  Runtime_params.register ~key:"relay.cost_large_file_read"
    ~default:(fun () -> 10_000)
    ~validate:(validate_int_range ~min:1000 ~max:100_000 "relay.cost_large_file_read")
    ~serialize:(fun v -> `Int v) ~deserialize:deserialize_int ()

let relay_cost_per_file_edit =
  Runtime_params.register ~key:"relay.cost_per_file_edit"
    ~default:(fun () -> 3_000)
    ~validate:(validate_int_range ~min:500 ~max:50_000 "relay.cost_per_file_edit")
    ~serialize:(fun v -> `Int v) ~deserialize:deserialize_int ()

let relay_cost_long_running =
  Runtime_params.register ~key:"relay.cost_long_running"
    ~default:(fun () -> 20_000)
    ~validate:(validate_int_range ~min:1000 ~max:200_000 "relay.cost_long_running")
    ~serialize:(fun v -> `Int v) ~deserialize:deserialize_int ()

let relay_cost_exploration =
  Runtime_params.register ~key:"relay.cost_exploration"
    ~default:(fun () -> 15_000)
    ~validate:(validate_int_range ~min:1000 ~max:100_000 "relay.cost_exploration")
    ~serialize:(fun v -> `Int v) ~deserialize:deserialize_int ()

let relay_cost_simple =
  Runtime_params.register ~key:"relay.cost_simple"
    ~default:(fun () -> 1_000)
    ~validate:(validate_int_range ~min:100 ~max:10_000 "relay.cost_simple")
    ~serialize:(fun v -> `Int v) ~deserialize:deserialize_int ()

(* ── keeper_diagnostics surface (Medium risk) ─────────────────── *)

let keeper_snapshot_sec =
  Runtime_params.register
    ~key:"keeper.snapshot_sec"
    ~default:(fun () -> Env_config_keeper.KeeperRuntime.snapshot_sec)
    ~validate:(validate_int_range ~min:15 ~max:3600 "keeper_snapshot_sec")
    ~serialize:(fun v -> `Int v)
    ~meta:{ description = "Snapshot 캡처 주기(초)";
            value_type = "int";
            min_value = Some (`Int 15); max_value = Some (`Int 3600) }
    ~deserialize:deserialize_int
    ()

let keeper_work_as_hb_enabled =
  Runtime_params.register
    ~key:"keeper.work_as_hb_enabled"
    ~default:(fun () -> Env_config_keeper.WorkAsHeartbeat.enabled)
    ~validate:(fun _ -> Ok ())
    ~serialize:(fun v -> `Bool v)
    ~meta:{ description = "Work-as-heartbeat 활성화 여부";
            value_type = "bool";
            min_value = None; max_value = None }
    ~deserialize:deserialize_bool
    ()

let keeper_work_as_hb_max_silence_sec =
  Runtime_params.register
    ~key:"keeper.work_as_hb_max_silence_sec"
    ~default:(fun () -> Env_config_keeper.WorkAsHeartbeat.max_silence_sec)
    ~validate:(validate_float_range ~min:10.0 ~max:600.0 "keeper_work_as_hb_max_silence_sec")
    ~serialize:(fun v -> `Float v)
    ~meta:{ description = "Work-as-heartbeat 최대 침묵 시간(초)";
            value_type = "float";
            min_value = Some (`Float 10.0); max_value = Some (`Float 600.0) }
    ~deserialize:deserialize_float
    ()

let keeper_smart_hb_enabled =
  Runtime_params.register
    ~key:"keeper.smart_hb_enabled"
    ~default:(fun () -> Env_config_keeper.SmartHeartbeat.enabled)
    ~validate:(fun _ -> Ok ())
    ~serialize:(fun v -> `Bool v)
    ~meta:{ description = "Smart heartbeat 적응형 스케줄링 활성화";
            value_type = "bool";
            min_value = None; max_value = None }
    ~deserialize:deserialize_bool
    ()

let keeper_stage_timing_ring_size =
  Runtime_params.register
    ~key:"keeper.stage_timing_ring_size"
    ~default:(fun () -> Env_config_keeper.KeeperProactive.stage_timing_ring_size)
    ~validate:(validate_int_range ~min:10 ~max:1000 "keeper_stage_timing_ring_size")
    ~serialize:(fun v -> `Int v)
    ~meta:{ description = "Stage timing ring buffer 크기 (fiber restart 시 적용)";
            value_type = "int";
            min_value = Some (`Int 10); max_value = Some (`Int 1000) }
    ~deserialize:deserialize_int
    ()

(* ── drift_guard heuristics (Low risk, detection tuning) ───── *)

(** Token-coverage floor below which a handoff is classified as
    factual drift. Initial estimate from drift_guard.ml; not
    empirically calibrated against a labelled corpus. *)
let drift_factual_coverage_floor =
  Runtime_params.register
    ~key:"drift.factual_coverage_floor"
    ~default:(fun () -> 0.55)
    ~validate:(validate_float_range ~min:0.0 ~max:1.0 "drift_factual_coverage_floor")
    ~serialize:(fun v -> `Float v)
    ~deserialize:deserialize_float
    ~meta:{ description = "drift_guard factual drift 판정 — 토큰 커버리지 하한";
            value_type = "float";
            min_value = Some (`Float 0.0); max_value = Some (`Float 1.0) }
    ()

(** Size-ratio floor (handoff / original) below which the handoff is
    factual drift. Captures "content replaced" vs "content edited". *)
let drift_factual_size_ratio_floor =
  Runtime_params.register
    ~key:"drift.factual_size_ratio_floor"
    ~default:(fun () -> 0.6)
    ~validate:(validate_float_range ~min:0.0 ~max:1.0 "drift_factual_size_ratio_floor")
    ~serialize:(fun v -> `Float v)
    ~deserialize:deserialize_float
    ~meta:{ description = "drift_guard factual drift 판정 — 크기 비율 하한";
            value_type = "float";
            min_value = Some (`Float 0.0); max_value = Some (`Float 1.0) }
    ()

(** Cosine-jaccard divergence threshold for structural drift. Above
    this, vocabulary overlap is high but word-order/phrasing shifted. *)
let drift_structural_divergence_threshold =
  Runtime_params.register
    ~key:"drift.structural_divergence_threshold"
    ~default:(fun () -> 0.18)
    ~validate:(validate_float_range ~min:0.0 ~max:1.0 "drift_structural_divergence_threshold")
    ~serialize:(fun v -> `Float v)
    ~deserialize:deserialize_float
    ~meta:{ description = "drift_guard structural drift 판정 — cosine-jaccard 발산 임계치";
            value_type = "float";
            min_value = Some (`Float 0.0); max_value = Some (`Float 1.0) }
    ()

(* ── surface catalog ─────────────────────────────────────────── *)

type surface = {
  id : string;
  description : string;
  risk : string;
  param_keys : string list;
}

let surfaces =
  [
    {
      id = "board_policy";
      description = "Message retention cap";
      risk = "low";
      param_keys = [ "message.max_count" ];
    };
    {
      id = "inference_config";
      description = "Default MODEL model and timeout";
      risk = "high";
      param_keys =
        [
          "inference.default_model";
          "inference.timeout_seconds";
        ];
    };
    {
      id = "cost_policy";
      description = "Per-session cost limits for keeper execution";
      risk = "medium";
      param_keys = [ "cost.max_session_usd" ];
    };
    {
      id = "keeper_lifecycle";
      description = "Keeper heartbeat, supervisor, and restart thresholds";
      risk = "medium";
      param_keys = [
        "keeper.max_consecutive_hb_failures";
        "keeper.max_consecutive_turn_failures";
        "keeper.supervisor_max_restarts";
        "keeper.supervisor_sweep_sec";
        "keeper.keepalive_interval_sec";
        "keeper.dead_ttl_sec";
      ];
    };
    {
      id = "keeper_handoff";
      description = "Keeper handoff context ratio, cooldown, and pressure thresholds";
      risk = "medium";
      param_keys = [
        "keeper.handoff_threshold";
        "keeper.handoff_cooldown_sec";
        "keeper.handoff_pressure_threshold";
      ];
    };
    {
      id = "keeper_diagnostics";
      description = "Keeper snapshot, heartbeat tuning, and profiling ring";
      risk = "medium";
      param_keys = [
        "keeper.snapshot_sec";
        "keeper.work_as_hb_enabled";
        "keeper.work_as_hb_max_silence_sec";
        "keeper.smart_hb_enabled";
        "keeper.stage_timing_ring_size";
      ];
    };
    {
      id = "relay_heuristic";
      description = "Relay token estimation and task cost heuristics (not calibrated)";
      risk = "low";
      param_keys = [
        "relay.tokens_per_user_msg"; "relay.tokens_per_assistant_msg";
        "relay.tokens_per_tool_call"; "relay.tokens_per_tool_result";
        "relay.cost_large_file_read"; "relay.cost_per_file_edit";
        "relay.cost_long_running"; "relay.cost_exploration"; "relay.cost_simple";
      ];
    };
    {
      id = "drift_guard";
      description = "Handoff drift classification thresholds (initial estimates, not corpus-calibrated)";
      risk = "low";
      param_keys = [
        "drift.factual_coverage_floor";
        "drift.factual_size_ratio_floor";
        "drift.structural_divergence_threshold";
      ];
    };
    {
      id = "keeper_turn";
      description = "Keeper LLM turn parameters: temperature, tokens, tools, slots";
      risk = "medium";
      param_keys = [
        "keeper.turn.temperature";
        "keeper.turn.max_output_tokens";
        "keeper.turn.max_tools_per_turn";
        "keeper.turn.board_event_limit";
        "keeper.turn.tool_cost_max_usd";
        "keeper.turn.llm_rerank";
        "keeper.turn.llama_slots";
        "keeper.turn.tool_search_top_k";
        "keeper.turn.batch_limit";
      ];
    };
    {
      id = "keeper_compaction";
      description = "Keeper context compaction thresholds and cooldown";
      risk = "medium";
      param_keys = [
        "keeper.compaction.ratio";
        "keeper.compaction.max_messages";
        "keeper.compaction.max_tokens";
        "keeper.compaction.cooldown_sec";
      ];
    };
    {
      id = "keeper_proactive";
      description = "Keeper proactive turn scheduling and bootstrap timing";
      risk = "low";
      param_keys = [
        "keeper.proactive.warmup_sec";
        "keeper.proactive.stagger_step_sec";
        "keeper.proactive.min_cooldown_sec";
        "keeper.proactive.task_cooldown_divisor";
        "keeper.proactive.task_min_cooldown_sec";
      ];
    };
    {
      id = "keeper_rules";
      description = "Keeper rule engine thresholds (reflect, plan, guardrail)";
      risk = "low";
      param_keys = [
        "keeper.rule.reflect_repetition";
        "keeper.rule.plan_goal_alignment_max";
        "keeper.rule.plan_response_alignment_max";
        "keeper.rule.guardrail_repetition";
        "keeper.rule.guardrail_goal_alignment_max";
        "keeper.rule.guardrail_response_alignment_max";
        "keeper.rule.guardrail_context_min";
      ];
    };
    {
      id = "dashboard";
      description = "Dashboard rendering — truncation lengths, row limits, borders, status thresholds";
      risk = "low";
      param_keys = [
        "dashboard.max_path_length";
        "dashboard.max_message_length";
        "dashboard.max_pending_tasks";
        "dashboard.max_recent_messages";
        "dashboard.min_border_length";
        "dashboard.agent_quiet_threshold_sec";
        "dashboard.agent_stuck_threshold_sec";
      ];
    };
  ]

(* ── initialization ─────────────────────────────────────────── *)

(** Force module initialization to guarantee all params are registered
    before [Runtime_params.restore]. Call from server bootstrap. *)
let ensure_init () =
  let (_ : _) = Runtime_params.get message_max_count in
  let (_ : _) = Runtime_params.get dashboard_max_path_length in
  let (_ : _) = Runtime_params.get dashboard_max_message_length in
  let (_ : _) = Runtime_params.get dashboard_max_pending_tasks in
  let (_ : _) = Runtime_params.get dashboard_max_recent_messages in
  let (_ : _) = Runtime_params.get dashboard_min_border_length in
  let (_ : _) = Runtime_params.get dashboard_agent_quiet_threshold_sec in
  let (_ : _) = Runtime_params.get dashboard_agent_stuck_threshold_sec in
  let (_ : _) = Runtime_params.get drift_factual_coverage_floor in
  let (_ : _) = Runtime_params.get drift_factual_size_ratio_floor in
  let (_ : _) = Runtime_params.get drift_structural_divergence_threshold in
  Keeper_config.ensure_runtime_params_init ()

let surfaces_json () =
  `List
    (List.map
       (fun s ->
         `Assoc
           [
             ("id", `String s.id);
             ("description", `String s.description);
             ("risk", `String s.risk);
             ("param_keys", `List (List.map (fun k -> `String k) s.param_keys));
           ])
       surfaces)
