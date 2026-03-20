(** Governance_registry — Governable parameter surface declarations.

    Declares which runtime parameters can be changed by governance decisions.
    Each parameter is registered with [Runtime_params] with validation bounds.

    Surfaces:
    - [lodge_behavior]:    tick interval, agents per tick, quiet hours (Low risk)
    - [lodge_limits]:      daily action / post caps (Low risk)
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

(* ── lodge_behavior surface ──────────────────────────────────── *)

let lodge_tick_interval =
  Runtime_params.register
    ~key:"lodge.tick_interval_seconds"
    ~default:(fun () -> Env_config_governance.LodgeV2.tick_interval_seconds)
    ~validate:(validate_float_range ~min:60.0 ~max:14400.0 "tick_interval")
    ~serialize:(fun v -> `Float v)
    ~deserialize:deserialize_float

let lodge_agents_per_tick =
  Runtime_params.register
    ~key:"lodge.agents_per_tick"
    ~default:(fun () -> Env_config_governance.LodgeV2.agents_per_tick)
    ~validate:(validate_int_range ~min:1 ~max:20 "agents_per_tick")
    ~serialize:(fun v -> `Int v)
    ~deserialize:deserialize_int

let lodge_quiet_start =
  Runtime_params.register
    ~key:"lodge.quiet_start"
    ~default:(fun () -> Env_config_governance.LodgeV2.quiet_start)
    ~validate:(validate_int_range ~min:0 ~max:23 "quiet_start")
    ~serialize:(fun v -> `Int v)
    ~deserialize:deserialize_int

let lodge_quiet_end =
  Runtime_params.register
    ~key:"lodge.quiet_end"
    ~default:(fun () -> Env_config_governance.LodgeV2.quiet_end)
    ~validate:(validate_int_range ~min:0 ~max:23 "quiet_end")
    ~serialize:(fun v -> `Int v)
    ~deserialize:deserialize_int

(* ── lodge_limits surface ────────────────────────────────────── *)

let lodge_max_daily_actions =
  Runtime_params.register
    ~key:"lodge.max_daily_actions"
    ~default:(fun () -> Env_config_governance.LodgeV2.max_daily_actions)
    ~validate:(validate_int_range ~min:1 ~max:100 "max_daily_actions")
    ~serialize:(fun v -> `Int v)
    ~deserialize:deserialize_int

let lodge_max_posts_per_day =
  Runtime_params.register
    ~key:"lodge.max_posts_per_day"
    ~default:(fun () -> Env_config_governance.LodgeV2.max_posts_per_day)
    ~validate:(validate_int_range ~min:1 ~max:50 "max_posts_per_day")
    ~serialize:(fun v -> `Int v)
    ~deserialize:deserialize_int

(* ── board_policy surface ────────────────────────────────────── *)

let message_max_count =
  Runtime_params.register
    ~key:"message.max_count"
    ~default:(fun () -> Env_config_runtime.Message.max_count)
    ~validate:(validate_int_range ~min:10 ~max:10000 "message_max_count")
    ~serialize:(fun v -> `Int v)
    ~deserialize:deserialize_int

(* ── inference_config surface (High risk) ──────────────────────────── *)

let inference_default_model =
  Runtime_params.register
    ~key:"inference.default_model"
    ~default:(fun () -> Env_config_governance.Glm.default_model)
    ~validate:(fun v ->
      if String.length v > 0 && String.length v <= 100 then Ok ()
      else Error "model name must be 1-100 chars")
    ~serialize:(fun v -> `String v)
    ~deserialize:deserialize_string

let inference_timeout =
  Runtime_params.register
    ~key:"inference.timeout_seconds"
    ~default:(fun () -> Env_config_governance.Inference.timeout_seconds)
    ~validate:(validate_float_range ~min:5.0 ~max:300.0 "inference_timeout")
    ~serialize:(fun v -> `Float v)
    ~deserialize:deserialize_float

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
      id = "lodge_behavior";
      description = "Lodge tick interval, agents per tick, quiet hours";
      risk = "low";
      param_keys =
        [
          "lodge.tick_interval_seconds";
          "lodge.agents_per_tick";
          "lodge.quiet_start";
          "lodge.quiet_end";
        ];
    };
    {
      id = "lodge_limits";
      description = "Lodge daily action and post caps";
      risk = "low";
      param_keys =
        [
          "lodge.max_daily_actions";
          "lodge.max_posts_per_day";
        ];
    };
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
  ]

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
