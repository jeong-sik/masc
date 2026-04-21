type source =
  | Env
  | Toml
  | Default
  | Derived

type 'a field = {
  value : 'a;
  source : source;
}

type t = {
  bootstrap_max_active_keepers : int field;
  reactive_max_turns_per_call : int field;
  autonomous_max_turns_per_call : int field;
  reactive_max_idle_turns : int field;
  autonomous_max_idle_turns : int field;
  turn_timeout_sec : float field;
  admission_wait_timeout_sec : float field;
  oas_timeout_override_sec : float option field;
  oas_timeout_per_1k : float field;
  oas_timeout_per_turn : float field;
}

let source_of_env_name name =
  match Config_boot_overrides.source name with
  | "env" -> Env
  | "boot_override" -> Toml
  | _ -> Default

let source_to_string = function
  | Env -> "env"
  | Toml -> "toml"
  | Default -> "default"
  | Derived -> "derived"

let get_int = Env_config_core.get_int
let get_float = Env_config_core.get_float

let bootstrap_max_active_keepers_live () =
  get_int ~default:10000 "MASC_KEEPER_BOOTSTRAP_MAX_ACTIVE_KEEPERS"

let reactive_max_turns_per_call_live () =
  max 1 (min 50 (get_int ~default:15 "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL"))

let autonomous_max_turns_per_call_live () =
  let global_cap = reactive_max_turns_per_call_live () in
  let default = min global_cap 2 in
  max 1
    (min global_cap
       (min 50
          (get_int ~default
             "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL_SCHEDULED_AUTONOMOUS")))

let reactive_max_idle_turns_live () =
  max 2 (min 50 (get_int ~default:15 "MASC_KEEPER_MAX_IDLE_TURNS_REACTIVE"))

let autonomous_max_idle_turns_live () =
  max 2 (min 50 (get_int ~default:10 "MASC_KEEPER_MAX_IDLE_TURNS_AUTONOMOUS"))

let turn_timeout_sec_live () =
  Float.max 60.0
    (Float.min 3600.0
       (get_float ~default:1200.0 "MASC_KEEPER_TURN_TIMEOUT_SEC"))

let admission_wait_timeout_sec_live () =
  Float.max 5.0
    (Float.min 1200.0
       (get_float ~default:180.0 "MASC_KEEPER_ADMISSION_WAIT_TIMEOUT_SEC"))

let oas_timeout_override_sec_live ~turn_timeout_sec =
  match Env_config_core.raw_value_opt "MASC_KEEPER_OAS_TIMEOUT_SEC" with
  | Some raw ->
      Some
        (Float.max 30.0
           (Float.min turn_timeout_sec
              (Option.value ~default:300.0
                 (Float.of_string_opt (String.trim raw)))))
  | None -> None

let freeze_from_current () =
  let source_field name value = { value; source = source_of_env_name name } in
  let turn_timeout_sec_value = turn_timeout_sec_live () in
  let bootstrap_max_active_keepers =
    source_field
      "MASC_KEEPER_BOOTSTRAP_MAX_ACTIVE_KEEPERS"
      (bootstrap_max_active_keepers_live ())
  in
  let reactive_max_turns_per_call =
    source_field
      "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL"
      (reactive_max_turns_per_call_live ())
  in
  let autonomous_max_turns_per_call =
    let source =
      match source_of_env_name "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL_SCHEDULED_AUTONOMOUS" with
      | Default -> Derived
      | other -> other
    in
    {
      value = autonomous_max_turns_per_call_live ();
      source;
    }
  in
  let reactive_max_idle_turns =
    source_field
      "MASC_KEEPER_MAX_IDLE_TURNS_REACTIVE"
      (reactive_max_idle_turns_live ())
  in
  let autonomous_max_idle_turns =
    source_field
      "MASC_KEEPER_MAX_IDLE_TURNS_AUTONOMOUS"
      (autonomous_max_idle_turns_live ())
  in
  let turn_timeout_sec =
    source_field
      "MASC_KEEPER_TURN_TIMEOUT_SEC"
      turn_timeout_sec_value
  in
  let admission_wait_timeout_sec =
    source_field
      "MASC_KEEPER_ADMISSION_WAIT_TIMEOUT_SEC"
      (admission_wait_timeout_sec_live ())
  in
  let oas_timeout_override_sec =
    {
      value = oas_timeout_override_sec_live ~turn_timeout_sec:turn_timeout_sec_value;
      source = source_of_env_name "MASC_KEEPER_OAS_TIMEOUT_SEC";
    }
  in
  let oas_timeout_per_1k =
    source_field
      "MASC_KEEPER_OAS_TIMEOUT_PER_1K"
      (Env_config_core.get_float ~default:1.5 "MASC_KEEPER_OAS_TIMEOUT_PER_1K")
  in
  let oas_timeout_per_turn =
    source_field
      "MASC_KEEPER_OAS_TIMEOUT_PER_TURN"
      (Env_config_core.get_float ~default:30.0 "MASC_KEEPER_OAS_TIMEOUT_PER_TURN")
  in
  {
    bootstrap_max_active_keepers;
    reactive_max_turns_per_call;
    autonomous_max_turns_per_call;
    reactive_max_idle_turns;
    autonomous_max_idle_turns;
    turn_timeout_sec;
    admission_wait_timeout_sec;
    oas_timeout_override_sec;
    oas_timeout_per_1k;
    oas_timeout_per_turn;
  }

let frozen : t option Atomic.t = Atomic.make None

let init () =
  match Atomic.get frozen with
  | Some _ -> ()
  | None -> Atomic.set frozen (Some (freeze_from_current ()))

let reset_for_tests () =
  Atomic.set frozen None

let current () =
  match Atomic.get frozen with
  | Some snapshot -> snapshot
  | None -> freeze_from_current ()

let field_to_yojson value_to_yojson (field : 'a field) =
  `Assoc
    [
      ("value", value_to_yojson field.value);
      ("source", `String (source_to_string field.source));
    ]

let option_float_to_yojson = function
  | Some value -> `Float value
  | None -> `Null

let to_yojson (runtime : t) =
  `Assoc
    [
      ("bootstrap_max_active_keepers", field_to_yojson (fun value -> `Int value) runtime.bootstrap_max_active_keepers);
      ("reactive_max_turns_per_call", field_to_yojson (fun value -> `Int value) runtime.reactive_max_turns_per_call);
      ("autonomous_max_turns_per_call", field_to_yojson (fun value -> `Int value) runtime.autonomous_max_turns_per_call);
      ("reactive_max_idle_turns", field_to_yojson (fun value -> `Int value) runtime.reactive_max_idle_turns);
      ("autonomous_max_idle_turns", field_to_yojson (fun value -> `Int value) runtime.autonomous_max_idle_turns);
      ("turn_timeout_sec", field_to_yojson (fun value -> `Float value) runtime.turn_timeout_sec);
      ("admission_wait_timeout_sec", field_to_yojson (fun value -> `Float value) runtime.admission_wait_timeout_sec);
      ("oas_timeout_override_sec", field_to_yojson option_float_to_yojson runtime.oas_timeout_override_sec);
      ("oas_timeout_per_1k", field_to_yojson (fun value -> `Float value) runtime.oas_timeout_per_1k);
      ("oas_timeout_per_turn", field_to_yojson (fun value -> `Float value) runtime.oas_timeout_per_turn);
    ]

let bootstrap_max_active_keepers () =
  (current ()).bootstrap_max_active_keepers.value

let reactive_max_turns_per_call () =
  (current ()).reactive_max_turns_per_call.value

let autonomous_max_turns_per_call () =
  (current ()).autonomous_max_turns_per_call.value

let reactive_max_idle_turns () =
  (current ()).reactive_max_idle_turns.value

let autonomous_max_idle_turns () =
  (current ()).autonomous_max_idle_turns.value

let turn_timeout_sec () =
  (current ()).turn_timeout_sec.value

let admission_wait_timeout_sec () =
  (current ()).admission_wait_timeout_sec.value

let oas_timeout_for_context_with_turn_budget ~(max_context : int)
    ~(max_turns : int) : float =
  let runtime = current () in
  match runtime.oas_timeout_override_sec.value with
  | Some value -> value
  | None ->
      let base = 120.0 in
      let context_time =
        Float.of_int max_context /. 1000.0 *. runtime.oas_timeout_per_1k.value
      in
      let effective_turns =
        Float.of_int (min max_turns 40)
      in
      let turn_time = effective_turns *. runtime.oas_timeout_per_turn.value in
      Float.max 30.0
        (Float.min runtime.turn_timeout_sec.value (base +. context_time +. turn_time))

let oas_timeout_for_context ~(max_context : int) : float =
  oas_timeout_for_context_with_turn_budget ~max_context
    ~max_turns:(reactive_max_turns_per_call ())
