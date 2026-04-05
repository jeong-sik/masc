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
  else Error (Printf.sprintf "%s must be in [%.1f, %.1f], got %.1f" key min max v)

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
    ~validate:(validate_float_range ~min:60.0 ~max:86400.0 "keeper_dead_ttl_sec")
    ~serialize:(fun v -> `Float v)
    ~meta:{ description = "Dead 상태 유지 시간(초)";
            value_type = "float";
            min_value = Some (`Float 60.0); max_value = Some (`Float 86400.0) }
    ~deserialize:deserialize_float
    ()

(* ── keeper_context surface (Medium risk) ─────────────────────── *)

(** Maximum messages to retain in checkpoints.
    Caps both load-time deserialization and save-time persistence.
    The context_reducer (keep_last 30) trims further during Agent.run,
    so 60 gives the reducer room to operate. *)
let keeper_max_checkpoint_messages =
  Runtime_params.register
    ~key:"keeper.max_checkpoint_messages"
    ~default:(fun () -> 60)
    ~validate:(validate_int_range ~min:10 ~max:500 "keeper_max_checkpoint_messages")
    ~serialize:(fun v -> `Int v)
    ~meta:{ description = "Checkpoint 메시지 보존 상한";
            value_type = "int";
            min_value = Some (`Int 10); max_value = Some (`Int 500) }
    ~deserialize:deserialize_int
    ()

(** Safety buffer ratio for token estimation errors.
    Applied as a multiplier to raw estimates (e.g., 1.15 = 15% buffer). *)
let keeper_safety_buffer_ratio =
  Runtime_params.register
    ~key:"keeper.safety_buffer_ratio"
    ~default:(fun () -> 1.15)
    ~validate:(validate_float_range ~min:1.0 ~max:2.0 "keeper_safety_buffer_ratio")
    ~serialize:(fun v -> `Float v)
    ~meta:{ description = "토큰 추정 안전 버퍼 비율 (1.15 = 15%)";
            value_type = "float";
            min_value = Some (`Float 1.0); max_value = Some (`Float 2.0) }
    ~deserialize:deserialize_float
    ()

(** Keeper staleness detection threshold in seconds.
    If last_seen_ago exceeds this, the keeper is considered stale/zombie. *)
let keeper_stale_threshold_sec =
  Runtime_params.register
    ~key:"keeper.stale_threshold_sec"
    ~default:(fun () -> 120.0)
    ~validate:(validate_float_range ~min:30.0 ~max:600.0 "keeper_stale_threshold_sec")
    ~serialize:(fun v -> `Float v)
    ~meta:{ description = "Keeper stale 판정 임계값(초)";
            value_type = "float";
            min_value = Some (`Float 30.0); max_value = Some (`Float 600.0) }
    ~deserialize:deserialize_float
    ()

(** Startup window in seconds for newly-created keepers.
    During this window, zero-turn keepers are classified as "startup"
    rather than "never_started". *)
let keeper_startup_window_sec =
  Runtime_params.register
    ~key:"keeper.startup_window_sec"
    ~default:(fun () -> 120.0)
    ~validate:(validate_float_range ~min:30.0 ~max:600.0 "keeper_startup_window_sec")
    ~serialize:(fun v -> `Float v)
    ~meta:{ description = "신규 keeper startup 판정 윈도우(초)";
            value_type = "float";
            min_value = Some (`Float 30.0); max_value = Some (`Float 600.0) }
    ~deserialize:deserialize_float
    ()

(** Recovery window in seconds after keepalive fiber restart.
    During this window, the keeper is classified as "recovering". *)
let keeper_recovery_window_sec =
  Runtime_params.register
    ~key:"keeper.recovery_window_sec"
    ~default:(fun () -> 60.0)
    ~validate:(validate_float_range ~min:10.0 ~max:300.0 "keeper_recovery_window_sec")
    ~serialize:(fun v -> `Float v)
    ~meta:{ description = "Keepalive 복구 윈도우(초)";
            value_type = "float";
            min_value = Some (`Float 10.0); max_value = Some (`Float 300.0) }
    ~deserialize:deserialize_float
    ()

(** Recency threshold for pipeline stage derivation.
    Activity within this window is considered "recent" for stage inference. *)
let keeper_recency_threshold_sec =
  Runtime_params.register
    ~key:"keeper.recency_threshold_sec"
    ~default:(fun () -> 30.0)
    ~validate:(validate_float_range ~min:5.0 ~max:120.0 "keeper_recency_threshold_sec")
    ~serialize:(fun v -> `Float v)
    ~meta:{ description = "파이프라인 스테이지 최근성 임계값(초)";
            value_type = "float";
            min_value = Some (`Float 5.0); max_value = Some (`Float 120.0) }
    ~deserialize:deserialize_float
    ()

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
      id = "keeper_context";
      description = "Keeper context estimation, checkpoint, and status thresholds";
      risk = "medium";
      param_keys = [
        "keeper.max_checkpoint_messages";
        "keeper.safety_buffer_ratio";
        "keeper.stale_threshold_sec";
        "keeper.startup_window_sec";
        "keeper.recovery_window_sec";
        "keeper.recency_threshold_sec";
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
  ]

(* ── initialization ─────────────────────────────────────────── *)

(** Force module initialization to guarantee all params are registered
    before [Runtime_params.restore]. Call from server bootstrap. *)
let ensure_init () =
  ignore (Runtime_params.get message_max_count)

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
