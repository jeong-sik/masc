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
  reactive_max_idle_turns : int field;
  autonomous_max_idle_turns : int field;
  idle_skip_threshold : int field;
  turn_timeout_sec : float field;
  admission_wait_timeout_sec : float field;
  oas_timeout_override_sec : float option field;
  stream_idle_timeout_sec : float field;
  execution_idle_timeout_sec : float option field;
  body_timeout_override_sec : float option field;
  oas_timeout_per_1k : float field;
  oas_timeout_per_turn : float field;
}

(** Sound-partial classifier for the string label returned by
    {!Config_boot_overrides.source}. Returns [None] for any label
    that is not one of the two values the underlying override
    machinery actually emits — callers choose the default policy at
    the use site instead of the parser silently coercing garbage.
    See [scripts/lint/no-unknown-permissive-default.sh]. *)
let source_of_env_name name : source option =
  match Config_boot_overrides.source name with
  | "env" -> Some Env
  | "boot_override" -> Some Toml
  | _ -> None

let source_to_string = function
  | Env -> "env"
  | Toml -> "toml"
  | Default -> "default"
  | Derived -> "derived"

let get_int = Env_config_core.get_int
let get_float = Env_config_core.get_float

let bootstrap_max_active_keepers_live () =
  get_int ~default:10000 "MASC_KEEPER_BOOTSTRAP_MAX_ACTIVE_KEEPERS"
  |> Keeper_fd_pressure.cap_active_keepers_for_nofile

let idle_skip_threshold_live () =
  max 2 (min 20 (get_int ~default:4 "MASC_KEEPER_IDLE_SKIP_THRESHOLD"))

(* The idle loop guard must sit strictly above the graduated idle hook's
   skip threshold ([idle_skip_threshold_live ()],
   default 4): the hook ends an idle run gracefully (Skip) at skip_at,
   while the OAS guard aborts the run with IdleDetected at the guard
   value. A guard <= skip_at makes Skip unreachable and turns die as
   errors instead (the 2026-06-12 sangsu kmsg kills). The floor enforces
   that contract at resolution time, so an env override cannot silently
   reintroduce the dead zone. *)
let idle_guard_floor () =
  idle_skip_threshold_live () + 1

let reactive_max_idle_turns_live () =
  max (idle_guard_floor ())
    (min 50 (get_int ~default:15 "MASC_KEEPER_MAX_IDLE_TURNS_REACTIVE"))

let autonomous_max_idle_turns_live () =
  max (idle_guard_floor ())
    (min 50 (get_int ~default:10 "MASC_KEEPER_MAX_IDLE_TURNS_AUTONOMOUS"))

let turn_timeout_sec_live () =
  (* SSOT: must match Env_config_keeper.KeeperKeepalive.turn_timeout_sec
     (range [60, timeout_hard_ceiling_sec=900], default 600). Drift here
     was the mathematical root of #10388 (1200 - 30 oas_guard = 1170 s
     budget). The 900 s ceiling was lifted from 600 in PR #13861 along
     with the RFC-0012/0022 permission for per-runtime overrides. *)
  Float.max 60.0
    (Float.min 900.0
       (get_float ~default:600.0 "MASC_KEEPER_TURN_TIMEOUT_SEC"))

let admission_wait_timeout_sec_live () =
  Float.max 5.0
    (Float.min 1200.0
       (get_float ~default:180.0 "MASC_KEEPER_ADMISSION_WAIT_TIMEOUT_SEC"))

let stream_idle_timeout_sec_live () =
  Float.max 5.0
    (Float.min 600.0
       (get_float ~default:120.0 "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC"))

let execution_idle_timeout_sec_of_raw = function
  | None -> None
  | Some raw -> (
      match Float.of_string_opt (String.trim raw) with
      | Some value when Float.is_finite value && value <= 0.0 -> None
      | Some value when Float.is_finite value ->
          Some (Float.max 5.0 (Float.min 600.0 value))
      | Some _ | None -> None)

let execution_idle_timeout_sec_live () =
  execution_idle_timeout_sec_of_raw
    (Env_config_core.raw_value_opt "MASC_KEEPER_EXECUTION_IDLE_TIMEOUT_SEC")

(* Per-call CLI subprocess idle timeout. Read fresh each turn rather than
   frozen at server boot — the value sits outside the keepalive budget
   contract enforced by the [t] snapshot. Range [10, 600] mirrors
   [stream_idle_timeout_sec_live] but allows lower floors for CLI
   transports that should fail faster than HTTP streaming providers.

   SSOT: must match Env_config_keeper.KeeperKeepalive.cli_subprocess_idle_sec
   (same default 120, same range [10, 600]). *)
let cli_subprocess_idle_sec_live () =
  Float.max 10.0
    (Float.min 600.0
       (get_float ~default:120.0 "MASC_KEEPER_CLI_SUBPROCESS_IDLE_SEC"))

let cli_subprocess_idle_sec = cli_subprocess_idle_sec_live

let oas_timeout_override_sec_live ~turn_timeout_sec =
  match Env_config_core.raw_value_opt "MASC_KEEPER_OAS_TIMEOUT_SEC" with
  | Some raw ->
      (* DET-OK: env override is parsed at the keeper runtime boundary;
         malformed values resolve to the turn budget for compatibility with
         previous behavior. *)
      (match Float.of_string_opt (String.trim raw) with
       | Some parsed -> Some (Float.max 30.0 (Float.min turn_timeout_sec parsed))
       | None -> Some turn_timeout_sec)
  | None -> None

(* SSOT: Env_config_keeper.KeeperKeepalive.body_timeout_sec_override
   (same env var, same clamp [10, 600]). Mirrors the
   [oas_timeout_override_sec_live] / [stream_idle_timeout_sec_live]
   idiom: read raw env, clamp, return option. Opt-in: unset → None.
   OAS applies this only to non-streaming sync body reads; streaming
   liveness is progress-based. *)
let body_timeout_override_sec_live () =
  match Env_config_core.raw_value_opt "MASC_KEEPER_BODY_TIMEOUT_SEC" with
  | Some raw ->
      (match Float.of_string_opt (String.trim raw) with
       | Some v -> Some (Float.max 10.0 (Float.min 600.0 v))
       | None -> None)
  | None -> None

let freeze_from_current () =
  let source_field name value =
    { value;
      source = Option.value ~default:Default (source_of_env_name name) }
  in
  let turn_timeout_sec_value = turn_timeout_sec_live () in
  let bootstrap_max_active_keepers =
    source_field
      "MASC_KEEPER_BOOTSTRAP_MAX_ACTIVE_KEEPERS"
      (bootstrap_max_active_keepers_live ())
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
  let idle_skip_threshold =
    source_field
      "MASC_KEEPER_IDLE_SKIP_THRESHOLD"
      (idle_skip_threshold_live ())
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
      source =
        Option.value ~default:Default
          (source_of_env_name "MASC_KEEPER_OAS_TIMEOUT_SEC");
    }
  in
  let stream_idle_timeout_sec =
    source_field
      "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC"
      (stream_idle_timeout_sec_live ())
  in
  let execution_idle_timeout_sec =
    {
      value = execution_idle_timeout_sec_live ();
      source =
        (match source_of_env_name "MASC_KEEPER_EXECUTION_IDLE_TIMEOUT_SEC" with
         | Some source -> source
         | None -> Default);
    }
  in
  let body_timeout_override_sec =
    {
      value = body_timeout_override_sec_live ();
      source =
        Option.value ~default:Default
          (source_of_env_name "MASC_KEEPER_BODY_TIMEOUT_SEC");
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
    reactive_max_idle_turns;
    autonomous_max_idle_turns;
    idle_skip_threshold;
    turn_timeout_sec;
    admission_wait_timeout_sec;
    oas_timeout_override_sec;
    stream_idle_timeout_sec;
    execution_idle_timeout_sec;
    body_timeout_override_sec;
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
      ("reactive_max_idle_turns", field_to_yojson (fun value -> `Int value) runtime.reactive_max_idle_turns);
      ("autonomous_max_idle_turns", field_to_yojson (fun value -> `Int value) runtime.autonomous_max_idle_turns);
      ("idle_skip_threshold", field_to_yojson (fun value -> `Int value) runtime.idle_skip_threshold);
      ("turn_timeout_sec", field_to_yojson (fun value -> `Float value) runtime.turn_timeout_sec);
      ("admission_wait_timeout_sec", field_to_yojson (fun value -> `Float value) runtime.admission_wait_timeout_sec);
      ("oas_timeout_override_sec", field_to_yojson option_float_to_yojson runtime.oas_timeout_override_sec);
      ("stream_idle_timeout_sec", field_to_yojson (fun value -> `Float value) runtime.stream_idle_timeout_sec);
      ("execution_idle_timeout_sec", field_to_yojson option_float_to_yojson runtime.execution_idle_timeout_sec);
      ("body_timeout_override_sec", field_to_yojson option_float_to_yojson runtime.body_timeout_override_sec);
      ("oas_timeout_per_1k", field_to_yojson (fun value -> `Float value) runtime.oas_timeout_per_1k);
      ("oas_timeout_per_turn", field_to_yojson (fun value -> `Float value) runtime.oas_timeout_per_turn);
    ]

let bootstrap_max_active_keepers () =
  (current ()).bootstrap_max_active_keepers.value

let reactive_max_idle_turns () =
  (current ()).reactive_max_idle_turns.value

let autonomous_max_idle_turns () =
  (current ()).autonomous_max_idle_turns.value

let idle_skip_threshold () =
  (current ()).idle_skip_threshold.value

let turn_timeout_sec () =
  (current ()).turn_timeout_sec.value

let admission_wait_timeout_sec () =
  (current ()).admission_wait_timeout_sec.value

let stream_idle_timeout_sec () =
  (current ()).stream_idle_timeout_sec.value

let execution_idle_timeout_sec () =
  (current ()).execution_idle_timeout_sec.value

let stream_idle_timeout_for_total_timeout ~(total_timeout_s : float) =
  Float.min total_timeout_s (stream_idle_timeout_sec ())

let body_timeout_override_sec () =
  (current ()).body_timeout_override_sec.value

(* RFC-0156/RFC-020x: OAS total timeout removed — turn_timeout_sec is the
   default provider-attempt timeout and first-attempt admission input, not a
   cumulative hard kill for active streams or retry admission.
   stream_idle_timeout is the per-stream idle cap. Kept in lockstep with
   [Env_config.KeeperKeepalive.oas_call_timeout_sec]. Historic names
   ([oas_timeout_for_estimated_input_tokens] /
   [oas_timeout_for_estimated_input_tokens_with_turn_budget]) ignored their
   args — function-name-lying. *)
let oas_call_timeout_sec () : float =
  let runtime = current () in
  match runtime.oas_timeout_override_sec.value with
  | Some value -> value
  | None -> runtime.turn_timeout_sec.value
