type source =
  | Env
  | Toml
  | Default
  | Failsafe_floor

type 'a field = {
  value : 'a;
  source : source;
}

(* Three of the four are floored: an explicit value or the floor, never
   absent, and their type says so. Only the body override has a real
   "not configured", which AGENT_CORE reads as "no override". *)
type t = {
  stream_idle_timeout_sec : float field;
  first_event_timeout_sec : float field;
  body_timeout_override_sec : float option field;
  provider_call_deadline_sec : float field;
}

(* The layer {!Config_boot_overrides.source} names, as this module's
   source; a boot override is the runtime file's value. *)
let source_of_env_name name : source =
  match Config_boot_overrides.source name with
  | Config_boot_overrides.Env -> Env
  | Config_boot_overrides.Boot_override -> Toml
  | Config_boot_overrides.Default -> Default

let source_to_string = function
  | Env -> "env"
  | Toml -> "toml"
  | Default -> "default"
  | Failsafe_floor -> "failsafe_floor"

(* The parse and the range check of the two deadlines belong to Env_config_keeper;
   a second copy here read the same variables and would drift on any change
   to either. AGENT_CORE applies the body override only to non-streaming
   sync body reads and it stays opt-in. Durable channel (#27416):
   runtime.toml [turn.provider_call_deadline_sec] reaches the reader through
   the boot-override layer behind [Env_config_core.raw_value_opt]; a set
   process env var still wins. *)

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
   (RFC-AC-037 §3). An explicit env/toml value overrides it verbatim. *)
let first_event_failsafe_floor_sec =
  Env_config_keeper.KeeperKeepalive.first_event_failsafe_floor_sec
;;

(* Fail-safe no-progress threshold for a provider call attempt (seconds).
   When neither [MASC_KEEPER_PROVIDER_CALL_DEADLINE_SEC] nor runtime.toml
   [turn.provider_call_deadline_sec] is set, the resolved value was [None]:
   the attempt watchdog stayed off and a tool's provider sub-call ran with
   no bound, so an attempt that never produced a token held the keeper until
   an operator interrupted it. Same magnitude and same rule as the two
   stream floors: a universal liveness ceiling above the longest legitimate
   no-progress gap (see [Env_config_keeper] for the measurement), not a
   per-provider tuning. An explicit env/toml value overrides it. *)
let provider_call_deadline_failsafe_floor_sec =
  Env_config_keeper.KeeperKeepalive.provider_call_deadline_failsafe_floor_sec
;;

let freeze_from_current () =
  let stream_idle_timeout_sec =
    match Env_config_keeper.KeeperKeepalive.stream_idle_timeout_sec () with
    | Some seconds ->
      (* Explicit env or runtime.toml value: honoured verbatim, no floor. *)
      {
        value = seconds;
        source = source_of_env_name Env_config_keeper.KeeperKeepalive.stream_idle_timeout_env_key;
      }
    | None ->
      (* Unset: substitute the fail-safe liveness floor so a hung provider stream
         cannot freeze the keeper chat lane forever (RFC-0345, #25128). Sourced
         as [Failsafe_floor] so telemetry and the boot log distinguish it from an
         operator-supplied value. *)
      {
        value = stream_idle_failsafe_floor_sec;
        source = Failsafe_floor;
      }
  in
  let first_event_timeout_sec =
    match Env_config_keeper.KeeperKeepalive.first_event_timeout_sec () with
    | Some seconds ->
      (* Explicit env or runtime.toml value: honoured verbatim, no floor. *)
      {
        value = seconds;
        source = source_of_env_name Env_config_keeper.KeeperKeepalive.first_event_timeout_env_key;
      }
    | None ->
      (* Unset: substitute the silent-prefill liveness ceiling so the
         first-event wait is never governed by the much shorter inter-line
         idle knob (RFC-AC-037; see [first_event_failsafe_floor_sec]).
         Sourced as [Failsafe_floor] so telemetry and the boot log
         distinguish it from an operator-supplied value. *)
      {
        value = first_event_failsafe_floor_sec;
        source = Failsafe_floor;
      }
  in
  let body_timeout_override_sec =
    {
      value = Env_config_keeper.KeeperKeepalive.body_timeout_sec_override ();
      source = source_of_env_name Env_config_keeper.KeeperKeepalive.body_timeout_env_key;
    }
  in
  let provider_call_deadline_sec =
    match Env_config_keeper.KeeperKeepalive.provider_call_deadline_sec_override () with
    | Some seconds ->
      (* Explicit env or runtime.toml value: honoured verbatim. *)
      {
        value = seconds;
        source = source_of_env_name Env_config_keeper.KeeperKeepalive.provider_call_deadline_env_key;
      }
    | None ->
      (* Unset: substitute the no-progress floor so a default install has an
         attempt watchdog and a bounded sub-call. Sourced as [Failsafe_floor]
         so telemetry and the boot log distinguish it from an operator value. *)
      {
        value = provider_call_deadline_failsafe_floor_sec;
        source = Failsafe_floor;
      }
  in
  (* The no-progress threshold ends an attempt that has been silent for
     that long. A stream budget the operator declared longer than it can
     never be reached: the watchdog cuts the silent prefill (or the silent
     gap) the operator meant to allow, and rotates the lane. That pair is
     refused where it is read, with both values and their sources named. A
     floor is not an allowance the operator asked for -- it is the ceiling
     used when nothing was declared -- so an explicit threshold shorter
     than a floored budget stands: the operator asked for the earlier cut
     and nothing they declared is negated by it. *)
  let describe (name : string) (field : float field) =
    Printf.sprintf "turn.%s (%g, %s)" name field.value (source_to_string field.source)
  in
  let declared (field : float field) =
    match field.source with
    | Env | Toml -> true
    | Default | Failsafe_floor -> false
  in
  let refuse_shorter_than ~budget_name (budget : float field) =
    if declared budget && provider_call_deadline_sec.value < budget.value
    then
      raise
        (Env_config_core.Config_error
           (Printf.sprintf
              "%s is shorter than %s: the no-progress threshold would end a silence \
               that budget still allows; declare turn.provider_call_deadline_sec >= %g"
              (describe "provider_call_deadline_sec" provider_call_deadline_sec)
              (describe budget_name budget)
              budget.value))
  in
  refuse_shorter_than ~budget_name:"first_event_timeout_sec" first_event_timeout_sec;
  refuse_shorter_than ~budget_name:"stream_idle_timeout_sec" stream_idle_timeout_sec;
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

let float_to_yojson value = `Float value

let option_float_to_yojson = function
  | Some value -> `Float value
  | None -> `Null

let to_yojson (runtime : t) =
  `Assoc
    [
      ("stream_idle_timeout_sec", field_to_yojson float_to_yojson runtime.stream_idle_timeout_sec);
      ("first_event_timeout_sec", field_to_yojson float_to_yojson runtime.first_event_timeout_sec);
      ("body_timeout_override_sec", field_to_yojson option_float_to_yojson runtime.body_timeout_override_sec);
      ("provider_call_deadline_sec", field_to_yojson float_to_yojson runtime.provider_call_deadline_sec);
    ]

let stream_idle_timeout_sec () =
  (current ()).stream_idle_timeout_sec.value

let first_event_timeout_sec () =
  (current ()).first_event_timeout_sec.value

let body_timeout_override_sec () =
  (current ()).body_timeout_override_sec.value

let provider_call_deadline_sec () =
  (current ()).provider_call_deadline_sec.value
