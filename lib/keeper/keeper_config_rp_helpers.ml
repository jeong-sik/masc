(** Keeper_config_rp_helpers — Shared Runtime_params registration helpers.

    Extracted from [Keeper_config] so that config sub-modules
    (e.g. [Keeper_config_rule_thresholds]) can call [_rp_float]
    without circular dependencies.

    @since God file decomposition *)

let clamp_int v ~min_v ~max_v =
  max min_v (min max_v v)

let int_of_env_default name ~default ~min_v ~max_v =
  Env_config_core.get_int ~default name |> clamp_int ~min_v ~max_v

let float_of_env_default name ~default ~min_v ~max_v =
  match Env_config_core.raw_value_opt name with
  | None -> default
  | Some raw ->
    let v =
      Option.value ~default (float_of_string_opt (String.trim raw))
    in
    max min_v (min max_v v)

let _rp_validate_int ~min ~max key v =
  if v >= min && v <= max then Ok ()
  else Error (Printf.sprintf "%s must be in [%d, %d], got %d" key min max v)

let _rp_validate_float ~min ~max key v =
  if v >= min && v <= max then Ok ()
  else Error (Printf.sprintf "%s must be in [%g, %g], got %g" key min max v)

let _rp_deser_int json =
  match json with
  | `Int i -> Ok i
  | `Float f ->
    let i = Float.to_int f in
    if Float.equal (Float.of_int i) f then Ok i
    else Error (Printf.sprintf "expected integer, got %g" f)
  | _ -> Error "expected integer"

let _rp_deser_float json =
  match json with
  | `Float f -> Ok f
  | `Int i -> Ok (float_of_int i)
  | _ -> Error "expected number"

let _rp_deser_bool json =
  match json with
  | `Bool b -> Ok b
  | _ -> Error "expected boolean"

let _rp_int ~key ~default ~min_v ~max_v ~description () =
  Runtime_params.register ~key
    ~default
    ~validate:(_rp_validate_int ~min:min_v ~max:max_v key)
    ~serialize:(fun v -> `Int v)
    ~meta:{ Runtime_params.description; value_type = "int";
            min_value = Some (`Int min_v); max_value = Some (`Int max_v) }
    ~deserialize:_rp_deser_int ()

let _rp_float ~key ~default ~min_v ~max_v ~description () =
  Runtime_params.register ~key
    ~default
    ~validate:(_rp_validate_float ~min:min_v ~max:max_v key)
    ~serialize:(fun v -> `Float v)
    ~meta:{ Runtime_params.description; value_type = "float";
            min_value = Some (`Float min_v); max_value = Some (`Float max_v) }
    ~deserialize:_rp_deser_float ()

let _rp_bool ~key ~default ~description () =
  Runtime_params.register ~key
    ~default
    ~validate:(fun _ -> Ok ())
    ~serialize:(fun v -> `Bool v)
    ~meta:{ Runtime_params.description; value_type = "bool";
            min_value = None; max_value = None }
    ~deserialize:_rp_deser_bool ()
