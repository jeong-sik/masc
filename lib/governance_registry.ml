(** Governance_registry — Governable parameter surface declarations.

    Declares which runtime parameters can be changed by governance decisions.
    Each parameter is registered with [Runtime_params] with validation bounds.

    Surfaces:
    - [board_policy]:      default TTL, message max count (Low risk)
    - [inference_config]:        default model, timeout (High risk)

    De-hexagonalized: [register_int], [register_float], [register_bool], and
    [register_string] combinators eliminate the per-parameter serialisation /
    deserialisation boilerplate, reducing each registration to three lines.

    @since 2.96.0 *)

(* ── validation helpers ──────────────────────────────────────── *)

let validate_float_range ~min ~max key v =
  if v >= min && v <= max then Ok ()
  else Error (Printf.sprintf "%s must be in [%g, %g], got %g" key min max v)

let validate_int_range ~min ~max key v =
  if v >= min && v <= max then Ok ()
  else Error (Printf.sprintf "%s must be in [%d, %d], got %d" key min max v)

(* The four [deserialize_*] helpers are passed to [Runtime_params.register]
   as [~deserialize] callbacks.  Their [Error] strings surface directly
   in governance-dashboard validation failures — operators reading those
   need not only *that* the JSON was wrong-shape but *what kind* they
   actually sent, to correlate against the surface that produced the
   misshapen value.  The previous one-word messages ("expected number",
   "expected integer", "expected string", "expected boolean") discarded
   the received kind. *)

let deserialize_float json =
  match json with
  | `Float f -> Ok f
  | `Int i -> Ok (float_of_int i)
  | other ->
      Error
        (Printf.sprintf
           "deserialize_float: expected JSON number (`Float or `Int), got %s"
           (Json_util.kind_name other))

let deserialize_int json =
  match json with
  | `Int i -> Ok i
  | `Float f ->
      let i = Float.to_int f in
      if Float.equal (Float.of_int i) f then Ok i
      else Error (Printf.sprintf "deserialize_int: expected integer, got %g" f)
  | other ->
      Error
        (Printf.sprintf
           "deserialize_int: expected JSON integer (`Int or whole-valued `Float), got %s"
           (Json_util.kind_name other))

let deserialize_string json =
  match json with
  | `String s -> Ok s
  | other ->
      Error
        (Printf.sprintf "deserialize_string: expected JSON string, got %s"
           (Json_util.kind_name other))

let deserialize_bool json =
  match json with
  | `Bool b -> Ok b
  | other ->
      Error
        (Printf.sprintf "deserialize_bool: expected JSON boolean, got %s"
           (Json_util.kind_name other))

(* ── registration combinators ───────────────────────────────── *)

(** Register a bounded integer parameter.
    Eliminates per-site [serialize]/[deserialize] boilerplate. *)
let register_int ~key ~default ~min ~max ?meta () =
  Runtime_params.register
    ~key
    ~default
    ~validate:(validate_int_range ~min ~max key)
    ~serialize:(fun v -> `Int v)
    ~deserialize:deserialize_int
    ?meta
    ()

(** Register a bounded float parameter. *)
let register_float ~key ~default ~min ~max ?meta () =
  Runtime_params.register
    ~key
    ~default
    ~validate:(validate_float_range ~min ~max key)
    ~serialize:(fun v -> `Float v)
    ~deserialize:deserialize_float
    ?meta
    ()

(** Register an unconstrained boolean parameter. *)
let register_bool ~key ~default ?meta () =
  Runtime_params.register
    ~key
    ~default
    ~validate:(fun _ -> Ok ())
    ~serialize:(fun v -> `Bool v)
    ~deserialize:deserialize_bool
    ?meta
    ()

(** Register a string parameter with a maximum length. *)
let register_string ~key ~default ~max_len ?meta () =
  Runtime_params.register
    ~key
    ~default
    ~validate:(fun v ->
      if String.length v > 0 && String.length v <= max_len then Ok ()
      else Error (Printf.sprintf "%s must be 1-%d chars" key max_len))
    ~serialize:(fun v -> `String v)
    ~deserialize:deserialize_string
    ?meta
    ()


(* ── board_policy surface ────────────────────────────────────── *)

let message_max_count =
  register_int
    ~key:"message.max_count"
    ~default:(fun () -> Env_config_runtime.Message.max_count)
    ~min:10 ~max:10000
    ()

(* ── inference_config surface (High risk) ──────────────────────────── *)

let inference_default_model =
  register_string
    ~key:"inference.default_model"
    ~default:(fun () -> "auto")
    ~max_len:100
    ()

let inference_timeout =
  register_float
    ~key:"inference.timeout_seconds"
    ~default:(fun () -> Env_config_governance.Inference.timeout_seconds)
    ~min:5.0 ~max:300.0

    ()

(* ── dashboard surface (Low risk, display-only) ──────────────── *)

(** Maximum path length before truncation in dashboard output. *)
let dashboard_max_path_length =
  register_int
    ~key:"dashboard.max_path_length"
    ~default:(fun () -> 30)
    ~min:10 ~max:200
    ~meta:{ description = "대시보드 경로 출력 최대 길이 (문자)";
            value_type = "int";
            min_value = Some (`Int 10); max_value = Some (`Int 200) }
    ()

(** Maximum message body length before truncation. *)
let dashboard_max_message_length =
  register_int
    ~key:"dashboard.max_message_length"
    ~default:(fun () -> 35)
    ~min:10 ~max:500
    ~meta:{ description = "대시보드 메시지 출력 최대 길이 (문자)";
            value_type = "int";
            min_value = Some (`Int 10); max_value = Some (`Int 500) }
    ()

(** Maximum number of pending tasks to show in dashboard. *)
let dashboard_max_pending_tasks =
  register_int
    ~key:"dashboard.max_pending_tasks"
    ~default:(fun () -> 5)
    ~min:1 ~max:50
    ~meta:{ description = "대시보드 pending task 표시 최대 개수";
            value_type = "int";
            min_value = Some (`Int 1); max_value = Some (`Int 50) }
    ()

(** Maximum number of recent messages to show. *)
let dashboard_max_recent_messages =
  register_int
    ~key:"dashboard.max_recent_messages"
    ~default:(fun () -> 5)
    ~min:1 ~max:50
    ~meta:{ description = "대시보드 recent message 표시 최대 개수";
            value_type = "int";
            min_value = Some (`Int 1); max_value = Some (`Int 50) }
    ()

(** Minimum section border length. *)
let dashboard_min_border_length =
  register_int
    ~key:"dashboard.min_border_length"
    ~default:(fun () -> 45)
    ~min:20 ~max:200
    ~meta:{ description = "대시보드 섹션 경계선 최소 길이";
            value_type = "int";
            min_value = Some (`Int 20); max_value = Some (`Int 200) }
    ()

(** Threshold for surfacing a quiet-agent warning in dashboard labels. *)
let dashboard_agent_quiet_threshold_sec =
  register_float
    ~key:"dashboard.agent_quiet_threshold_sec"
    ~default:(fun () -> Env_config_runtime.InternalTimers.label_quiet_threshold_sec)
    ~min:30.0 ~max:Masc_time_constants.day
    ~meta:{
      description = "대시보드 quiet 상태 임계값(초)";
      value_type = "float";
      min_value = Some (`Float 30.0);
      max_value = Some (`Float Masc_time_constants.day);
    }
    ()

(** Threshold for surfacing a stuck-agent warning in dashboard labels. *)
let dashboard_agent_stuck_threshold_sec =
  register_float
    ~key:"dashboard.agent_stuck_threshold_sec"
    ~default:(fun () -> Env_config_runtime.InternalTimers.label_stuck_threshold_sec)
    ~min:60.0 ~max:(7.0 *. Masc_time_constants.day)
    ~meta:{
      description = "대시보드 STUCK 상태 임계값(초)";
      value_type = "float";
      min_value = Some (`Float 60.0);
      max_value = Some (`Float (7.0 *. Masc_time_constants.day));
    }
    ()

(* ── cost_policy surface ──────────────────────────────────────── *)

(** Per-session advisory cost threshold in USD.
    Default 0.50: based on observed keeper sessions averaging $0.02-0.15
    (local llama + GLM fallback). 0.50 is ~3x worst-case observed session cost.
    Used for reporting/warnings only; it must not gate execution. *)
let _cost_max_session_usd =
  register_float
    ~key:"cost.max_session_usd"
    ~default:(fun () -> 0.50)
    ~min:0.01 ~max:50.0
    ()

(* ── keeper_lifecycle surface (Medium risk) ─────────────────── *)

let keeper_max_hb_failures =
  register_int
    ~key:"keeper.max_consecutive_hb_failures"
    ~default:(fun () -> Env_config_keeper.KeeperKeepalive.max_consecutive_failures)
    ~min:2 ~max:50
    ~meta:{ description = "Heartbeat 연속 실패 허용 횟수";
            value_type = "int";
            min_value = Some (`Int 2); max_value = Some (`Int 50) }
    ()

let keeper_max_turn_failures =
  register_int
    ~key:"keeper.max_consecutive_turn_failures"
    ~default:(fun () -> Env_config_keeper.KeeperKeepalive.max_consecutive_turn_failures)
    ~min:3 ~max:100
    ~meta:{ description = "Turn 연속 실패 허용 횟수";
            value_type = "int";
            min_value = Some (`Int 3); max_value = Some (`Int 100) }
    ()

let keeper_supervisor_sweep_sec =
  register_float
    ~key:"keeper.supervisor_sweep_sec"
    ~default:(fun () -> Env_config_keeper.KeeperSupervisor.sweep_interval_sec)
    ~min:10.0 ~max:120.0
    ~meta:{ description = "Supervisor sweep 주기(초)";
            value_type = "float";
            min_value = Some (`Float 10.0); max_value = Some (`Float 120.0) }
    ()

let keeper_supervisor_max_restarts =
  register_int
    ~key:"keeper.supervisor_max_restarts"
    ~default:(fun () -> Env_config_keeper.KeeperSupervisor.max_restarts)
    ~min:1 ~max:50
    ~meta:{ description = "Crash 후 재시작 예산";
            value_type = "int";
            min_value = Some (`Int 1); max_value = Some (`Int 50) }
    ()

let keeper_keepalive_interval_sec =
  register_int
    ~key:"keeper.keepalive_interval_sec"
    ~default:(fun () -> Env_config_keeper.KeeperKeepalive.interval_sec)
    ~min:5 ~max:300
    ~meta:{ description = "Heartbeat 주기(초)";
            value_type = "int";
            min_value = Some (`Int 5); max_value = Some (`Int 300) }
    ()

let keeper_dead_ttl_sec =
  register_float
    ~key:"keeper.dead_ttl_sec"
    ~default:(fun () -> Env_config_keeper.KeeperSupervisor.dead_ttl_sec)
    ~min:60.0 ~max:Masc_time_constants.day
    ~meta:{ description = "Dead 상태 유지 시간(초)";
            value_type = "float";
            min_value = Some (`Float 60.0); max_value = Some (`Float Masc_time_constants.day) }
    ()

(* ── keeper_handoff surface (Medium risk) ─────────────────────── *)

(** Default handoff threshold (context_ratio).
    When context ratio exceeds this, automatic handoff is considered. *)
let keeper_handoff_threshold =
  register_float
    ~key:"keeper.handoff_threshold"
    ~default:(fun () -> 0.85)
    ~min:0.5 ~max:0.99
    ~meta:{ description = "Handoff context ratio 임계값";
            value_type = "float";
            min_value = Some (`Float 0.5); max_value = Some (`Float 0.99) }
    ()

(** Handoff cooldown in seconds.
    After a handoff, suppress further handoffs for this duration. *)
let keeper_handoff_cooldown_sec =
  register_int
    ~key:"keeper.handoff_cooldown_sec"
    ~default:(fun () -> 300)
    ~min:30 ~max:Masc_time_constants.hour_int
    ~meta:{ description = "Handoff 쿨다운(초)";
            value_type = "int";
            min_value = Some (`Int 30);
            max_value = Some (`Int Masc_time_constants.hour_int) }
    ()

(** Context ratio above which handoff pressure alert fires. *)
let keeper_handoff_pressure_threshold =
  register_float
    ~key:"keeper.handoff_pressure_threshold"
    ~default:(fun () -> 0.88)
    ~min:0.5 ~max:0.99
    ~meta:{ description = "Handoff pressure 알림 임계값";
            value_type = "float";
            min_value = Some (`Float 0.5); max_value = Some (`Float 0.99) }
    ()

(* ── keeper_diagnostics surface (Medium risk) ─────────────────── *)

let keeper_snapshot_sec =
  register_int
    ~key:"keeper.snapshot_sec"
    ~default:(fun () -> Env_config_keeper.KeeperRuntime.snapshot_sec)
    ~min:15 ~max:Masc_time_constants.hour_int
    ~meta:{ description = "Snapshot 캡처 주기(초)";
            value_type = "int";
            min_value = Some (`Int 15);
            max_value = Some (`Int Masc_time_constants.hour_int) }
    ()

let keeper_work_as_hb_enabled =
  register_bool
    ~key:"keeper.work_as_hb_enabled"
    ~default:(fun () -> Env_config_keeper.WorkAsHeartbeat.enabled)
    ~meta:{ description = "Work-as-heartbeat 활성화 여부";
            value_type = "bool";
            min_value = None; max_value = None }
    ()

let keeper_work_as_hb_max_silence_sec =
  register_float
    ~key:"keeper.work_as_hb_max_silence_sec"
    ~default:(fun () -> Env_config_keeper.WorkAsHeartbeat.max_silence_sec)
    ~min:10.0 ~max:600.0
    ~meta:{ description = "Work-as-heartbeat 최대 침묵 시간(초)";
            value_type = "float";
            min_value = Some (`Float 10.0); max_value = Some (`Float 600.0) }
    ()

let keeper_smart_hb_enabled =
  register_bool
    ~key:"keeper.smart_hb_enabled"
    ~default:(fun () -> Env_config_keeper.SmartHeartbeat.enabled)
    ~meta:{ description = "Smart heartbeat 적응형 스케줄링 활성화";
            value_type = "bool";
            min_value = None; max_value = None }
    ()

let keeper_stage_timing_ring_size =
  register_int
    ~key:"keeper.stage_timing_ring_size"
    ~default:(fun () -> Env_config_keeper.KeeperProactive.stage_timing_ring_size)
    ~min:10 ~max:1000
    ~meta:{ description = "Stage timing ring buffer 크기 (fiber restart 시 적용)";
            value_type = "int";
            min_value = Some (`Int 10); max_value = Some (`Int 1000) }
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
        "keeper.proactive.min_interval_sec";
        "keeper.proactive.task_cooldown_divisor";
        "keeper.proactive.task_min_cooldown_sec";
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
