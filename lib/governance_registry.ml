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
        "keeper.keepalive_interval_sec";
        "keeper.dead_ttl_sec";
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
