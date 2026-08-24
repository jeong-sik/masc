type source =
  | Env
  | Toml
  | Default
  | Failsafe_floor

type 'a field = {
  value : 'a;
  source : source;
}

type t = {
  stream_idle_timeout_sec : float option field;
  first_event_timeout_sec : float option field;
  body_timeout_override_sec : float option field;
  provider_call_deadline_sec : float option field;
}

(** Exhaustive boundary for the labels emitted by
    {!Config_boot_overrides.source}. Unknown labels are an internal contract
    violation and must not be displayed as a fabricated default source. *)
let source_of_env_name name : source =
  match Config_boot_overrides.source name with
  | "env" -> Env
  | "boot_override" -> Toml
  | "default" -> Default
  | label ->
    raise
      (Env_config_core.Config_error
         (Printf.sprintf "unknown config source for %s: %S" name label))

let source_to_string = function
  | Env -> "env"
  | Toml -> "toml"
  | Default -> "default"
  | Failsafe_floor -> "failsafe_floor"

(* AGENT_CORE applies this only to non-streaming sync body reads; streaming
   liveness is progress-based. The parse and the clamp belong to
   Env_config_keeper — a second copy here read the same variable and would
   drift on any change to either. *)
let body_timeout_override_sec_live =
  Env_config_keeper.KeeperKeepalive.body_timeout_sec_override_live

(* SSOT: Env_config_keeper.KeeperKeepalive.provider_call_deadline_sec_override
   (same env var, same clamp [30, 3600]). Opt-in: unset -> None, no failsafe
   floor (#27349 -- deliberately different from stream_idle_timeout_sec's
   RFC-0345 fallback below: a total-call ceiling depends on provider and
   workload, so MASC does not substitute a guessed value).
   Durable channel (#27416): runtime.toml [turn.provider_call_deadline_sec]
   reaches this reader through the boot-override layer behind
   [Env_config_core.raw_value_opt]; a set process env var still wins. *)
let provider_call_deadline_sec_live =
  Env_config_keeper.KeeperKeepalive.provider_call_deadline_sec_override_live

(* Fail-safe liveness floor for the streaming inter-line idle timeout
   (seconds). When neither [MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC] nor runtime.toml
   [turn.stream_idle_timeout_sec] is set, the resolved value would be [None] and
   AGENT_CORE would apply no inter-line idle bound, letting a hung provider stream
   freeze the keeper chat lane indefinitely (#25128, measured 30+ min). This is a
   single universal liveness ceiling — NOT a per-provider tuned default
   (RFC-0345 §3.1) — an order of magnitude above any legitimate inter-token gap
   (sub-second to low-seconds), so it fires only on genuine hangs. An explicit
   env/toml value still overrides it verbatim. RFC-0345 §3.2 (Option A) / §3.4;
   revisitable (a floor, not a tuning). *)
let stream_idle_failsafe_floor_sec =
  Env_config_keeper.KeeperKeepalive.stream_idle_failsafe_floor_sec
;;

(* Fail-safe bound for the silent first-event (TTFT/prefill) wait (seconds).
   When neither [MASC_KEEPER_FIRST_EVENT_TIMEOUT_SEC] nor runtime.toml
   [turn.first_event_timeout_sec] is set, AGENT_CORE's first-event resolver
   falls back to [body_timeout_s] (unset on streaming keeper paths) and then
   to the inter-line idle value — a bound an order of magnitude below real
   silent prefill (measured: 152s mimo 1M-context turn 2026-07-20; ~200-525s
   local MLX 20.7K-token keeper prompts 2026-08-16, 9/9 canary failures at
   the 120s idle cut). Same magnitude as the RFC-0345 idle floor: a single
   universal liveness ceiling, NOT a per-provider tuned default
   (RFC-OAS-037 §3). An explicit env/toml value overrides it verbatim. *)
let first_event_failsafe_floor_sec =
  Env_config_keeper.KeeperKeepalive.first_event_failsafe_floor_sec
;;

let freeze_from_current () =
  let stream_idle_timeout_sec =
    match Env_config_keeper.KeeperKeepalive.stream_idle_timeout_sec () with
    | Some seconds ->
      (* Explicit env or runtime.toml value: honoured verbatim, no floor. *)
      {
        value = Some seconds;
        source = source_of_env_name "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC";
      }
    | None ->
      (* Unset: substitute the fail-safe liveness floor so a hung provider stream
         cannot freeze the keeper chat lane forever (RFC-0345, #25128). Sourced
         as [Failsafe_floor] so telemetry and the boot log distinguish it from an
         operator-supplied value. *)
      {
        value = Some stream_idle_failsafe_floor_sec;
        source = Failsafe_floor;
      }
  in
  let first_event_timeout_sec =
    match Env_config_keeper.KeeperKeepalive.first_event_timeout_sec () with
    | Some seconds ->
      (* Explicit env or runtime.toml value: honoured verbatim, no floor. *)
      {
        value = Some seconds;
        source = source_of_env_name "MASC_KEEPER_FIRST_EVENT_TIMEOUT_SEC";
      }
    | None ->
      (* Unset: substitute the silent-prefill liveness ceiling so the
         first-event wait is never governed by the much shorter inter-line
         idle knob (RFC-OAS-037; see [first_event_failsafe_floor_sec]).
         Sourced as [Failsafe_floor] so telemetry and the boot log
         distinguish it from an operator-supplied value. *)
      {
        value = Some first_event_failsafe_floor_sec;
        source = Failsafe_floor;
      }
  in
  let body_timeout_override_sec =
    {
      value = body_timeout_override_sec_live ();
      source = source_of_env_name "MASC_KEEPER_BODY_TIMEOUT_SEC";
    }
  in
  let provider_call_deadline_sec =
    {
      value = provider_call_deadline_sec_live ();
      source = source_of_env_name "MASC_KEEPER_PROVIDER_CALL_DEADLINE_SEC";
    }
  in
  {
    stream_idle_timeout_sec;
    first_event_timeout_sec;
    body_timeout_override_sec;
    provider_call_deadline_sec;
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
      ("stream_idle_timeout_sec", field_to_yojson option_float_to_yojson runtime.stream_idle_timeout_sec);
      ("first_event_timeout_sec", field_to_yojson option_float_to_yojson runtime.first_event_timeout_sec);
      ("body_timeout_override_sec", field_to_yojson option_float_to_yojson runtime.body_timeout_override_sec);
      ("provider_call_deadline_sec", field_to_yojson option_float_to_yojson runtime.provider_call_deadline_sec);
    ]

let stream_idle_timeout_sec () =
  (current ()).stream_idle_timeout_sec.value

let first_event_timeout_sec () =
  (current ()).first_event_timeout_sec.value

let body_timeout_override_sec () =
  (current ()).body_timeout_override_sec.value

let provider_call_deadline_sec () =
  (current ()).provider_call_deadline_sec.value
