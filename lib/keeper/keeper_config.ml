(** Keeper configuration — defaults, environment variable parsing, profiles. *)

open Tool_args
include Keeper_config_rp_helpers

(** Upper bound for keeper time configs expressed in seconds.  Repeated
    seven times as the bare literal [172800] across this file before
    the extraction; [Masc_time_constants.day_int * 2] makes the "2 days"
    intent explicit and satisfies sw-dev §"Magic Number 금지". *)
let two_days_seconds_int = Masc_time_constants.day_int * 2

(** One-day upper bound expressed in seconds for goal observation windows. *)
(* runtime→Runtime 숙청: per-phase runtime name 구분 제거. runtime 세계의
   phase_recovery / phase_buffer / tool_action / routing 은 서로 다른 route
   였으나, Runtime 모델에서는 모든 phase 가 동일한 default Runtime 을 쓴다 —
   넷 다 default_runtime_id () 으로 수렴하는 죽은 구분이었다. 단일 함수로
   collapse 하고, eager 모듈-레벨 baking(module-init 시점 미초기화 싱글톤 읽기)
   도 함께 제거한다. *)
let default_runtime_id () = Runtime.get_default_runtime_id ()

(** Minimum context window (tokens) for any keeper turn.
    64k-class local models are valid keeper backends; do not clamp them upward
    to 65,536, which can exceed the discovered provider ceiling. *)
let min_keeper_context_tokens = 64_000

(** Maximum context window (tokens) accepted for [max_context_override] on
    keeper turn-up args (#9953).  Matches the largest published context
    window among supported providers (largest published = 1M).
    Bumps to a 2M-class model must update this constant alongside the
    provider registry entry. *)
let max_keeper_context_tokens = 1_000_000

(* ── Alert preview truncation lengths ─────────────────────── *)
(* Invariant: excerpt_min < message_max < reply_max.
   Violating this makes the min/max logic in keeper_alerting.ml degenerate. *)

(** Error detail truncation for alert messages. *)
let alert_error_detail_max_chars = 280

(** Floor for excerpt cap (minimum preview length). *)
let alert_excerpt_min_chars = 240

(** Message preview cap for alert formatting. *)
let alert_message_preview_max_chars = 300

(** Reply preview cap for alert formatting. *)
let alert_reply_preview_max_chars = 420

let () =
  if not
       (alert_excerpt_min_chars < alert_message_preview_max_chars
       && alert_message_preview_max_chars < alert_reply_preview_max_chars)
  then
    invalid_arg
      "Keeper_config alert preview lengths must satisfy excerpt < message < reply";
  if alert_error_detail_max_chars <= 0 then
    invalid_arg "Keeper_config alert_error_detail_max_chars must be positive"

include Keeper_config_text


let keeper_status_fast_default () : bool =
  bool_of_env_default "MASC_KEEPER_STATUS_FAST_DEFAULT" ~default:false

(* #11111: was 0.5, which fired ContextOverflowImminent at half-window
   on every keeper turn (18 events / 2d, all in 0.50–0.55 band).
   OAS pipeline applies a hard floor of 0.9 when this is unset; we
   stay just below that so compaction has workspace to run before the
   upstream guard triggers. *)
let keeper_compact_ratio_rp =
  _rp_float ~key:"keeper.compaction.ratio"
    ~default:(fun () -> float_of_env_default "MASC_KEEPER_COMPACT_RATIO"
                          ~default:0.85 ~min_v:0.1 ~max_v:0.98)
    ~min_v:0.1 ~max_v:0.98
    ~description:"Compaction ratio gate" ()
let keeper_compact_ratio () : float =
  Runtime_params.get keeper_compact_ratio_rp

let keeper_compact_max_messages_rp =
  _rp_int ~key:"keeper.compaction.max_messages"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_COMPACT_MAX_MESSAGES"
                          ~default:0 ~min_v:0 ~max_v:5000)
    ~min_v:0 ~max_v:5000
    ~description:"Compaction message gate (0=disabled)" ()
let keeper_compact_max_messages () : int =
  Runtime_params.get keeper_compact_max_messages_rp

let keeper_compact_max_tokens_rp =
  _rp_int ~key:"keeper.compaction.max_tokens"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_COMPACT_MAX_TOKENS"
                          ~default:196608 ~min_v:0 ~max_v:5000000)
    ~min_v:0 ~max_v:5000000
    ~description:"Compaction token gate (75%% of 262k context)" ()
let keeper_compact_max_tokens () : int =
  Runtime_params.get keeper_compact_max_tokens_rp

(** Cooldown between compaction attempts.  Previous default (90s) exceeded
    the proactive heartbeat interval (30s), permanently blocking compaction
    for proactive keepers.  15s allows compaction to fire every other cycle. *)
let keeper_compaction_cooldown_sec_rp =
  _rp_int ~key:"keeper.compaction.cooldown_sec"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_COMPACTION_COOLDOWN_SEC"
                          ~default:15 ~min_v:0 ~max_v:two_days_seconds_int)
    ~min_v:0 ~max_v:two_days_seconds_int
    ~description:"Compaction cooldown (seconds)" ()
let keeper_compaction_cooldown_sec () : int =
  Runtime_params.get keeper_compaction_cooldown_sec_rp

let keeper_bootstrap_proactive_warmup_sec_rp =
  _rp_int ~key:"keeper.proactive.warmup_sec"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_BOOTSTRAP_PROACTIVE_WARMUP_SEC"
                          ~default:60 ~min_v:0 ~max_v:two_days_seconds_int)
    ~min_v:0 ~max_v:two_days_seconds_int
    ~description:"Bootstrap proactive warmup delay (seconds)" ()
let keeper_bootstrap_proactive_warmup_sec () : int =
  Runtime_params.get keeper_bootstrap_proactive_warmup_sec_rp

let keeper_bootstrap_stagger_step_sec_rp =
  _rp_int ~key:"keeper.proactive.stagger_step_sec"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_BOOTSTRAP_STAGGER_STEP_SEC"
                          ~default:15 ~min_v:0 ~max_v:120)
    ~min_v:0 ~max_v:120
    ~description:"Bootstrap warmup deterministic jitter window (seconds)" ()
let keeper_bootstrap_stagger_step_sec () : int =
  Runtime_params.get keeper_bootstrap_stagger_step_sec_rp

let keeper_bootstrap_retry_interval_sec_rp =
  _rp_int ~key:"keeper.bootstrap.retry_interval_sec"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_BOOTSTRAP_RETRY_INTERVAL_SEC"
                          ~default:30 ~min_v:5 ~max_v:300)
    ~min_v:5 ~max_v:300
    ~description:"Delay between autoboot retry rounds (seconds)" ()
let keeper_bootstrap_retry_interval_sec () : int =
  Runtime_params.get keeper_bootstrap_retry_interval_sec_rp

let keeper_compaction_policy_from_env () : (float * int * int) =
  ( keeper_compact_ratio (),
    keeper_compact_max_messages (),
    keeper_compact_max_tokens () )

let normalize_compaction_ratio_gate (v : float) : float =
  max 0.1 (min 0.98 v)

let normalize_compaction_message_gate (v : int) : int =
  clamp_int v ~min_v:0 ~max_v:5000

let normalize_compaction_token_gate (v : int) : int =
  clamp_int v ~min_v:0 ~max_v:5000000

let normalize_compaction_cooldown_sec (v : int) : int =
  clamp_int v ~min_v:0 ~max_v:two_days_seconds_int

let default_compaction_profile = "custom"

(* RFC-0313-adjacent compaction summarizer strategy selector.
   [profile] decides WHEN to compact (the gate); [mode] decides HOW the
   checkpoint is summarized. Orthogonal axes, so a separate closed variant
   rather than another [profile] string.

   [Llm] = provider-backed summarizer on the librarian lane; the default,
   because what to keep/summarize/drop is a judgment call and judgment goes
   through an LLM boundary. Missing or invalid output preserves the original
   checkpoint.
   [Deterministic] is retained only as a persisted-config compatibility value;
   MASC applies no local content reducer for it. *)
type compaction_mode =
  | Deterministic
  | Llm

let default_compaction_mode = Llm

let compaction_mode_to_string = function
  | Deterministic -> "deterministic"
  | Llm -> "llm"

(* Unknown → error, NOT a permissive default. Mirrors the
   MASC_RUNTIME_ATTEMPT_LIVENESS canonical-or-config-error precedent
   (env_config_snapshot.ml): explicit values must be canonical, so a
   typo cannot silently pick a mode the operator did not intend
   (CLAUDE.md "Unknown → Permissive Default" antipattern). *)
let compaction_mode_of_string raw : (compaction_mode, string) result =
  match String.lowercase_ascii (String.trim raw) with
  | "deterministic" | "extractive" -> Ok Deterministic
  | "llm" | "summarizer" -> Ok Llm
  | other ->
    Error
      (Printf.sprintf
         "invalid compaction_mode '%s' (allowed: deterministic, llm)"
         other)

(* Global default mode from env. Unset → [default_compaction_mode]; set but
   non-canonical → [invalid_arg] (fail-closed at load, not a silent default),
   matching the MASC_RUNTIME_ATTEMPT_LIVENESS precedent. Read at call time so
   tests can set the env; there is no per-turn hot-path caller. *)
let keeper_compaction_mode_env_key = "MASC_KEEPER_COMPACTION_MODE"

let keeper_compaction_mode_default () : compaction_mode =
  match Sys.getenv_opt keeper_compaction_mode_env_key with
  | None -> default_compaction_mode
  | Some raw ->
    (match compaction_mode_of_string raw with
     | Ok mode -> mode
     | Error msg ->
       invalid_arg
         (Printf.sprintf "%s: %s" keeper_compaction_mode_env_key msg))

let canonical_compaction_profile raw =
  match String.lowercase_ascii (String.trim raw) with
  | "aggressive" | "tight" -> Some "aggressive"
  | "balanced" | "default" -> Some "balanced"
  | "conservative" | "loose" -> Some "conservative"
  | "custom" | "manual" | "env" -> Some "custom"
  | _ -> None

let parse_compaction_profile_opt args key : (string option, string) result =
  match get_string_opt args key with
  | None -> Ok None
  | Some raw ->
      (match canonical_compaction_profile raw with
       | Some p -> Ok (Some p)
       | None ->
           Error
             (Printf.sprintf
                "invalid compaction_profile '%s' (allowed: aggressive, balanced, conservative, custom)"
                raw))

let compaction_policy_of_profile (profile : string) : (float * int * int) =
  match canonical_compaction_profile profile |> Option.value ~default:default_compaction_profile with
  | "aggressive" -> (0.35, 120, 60_000)
  | "balanced" -> (0.50, 240, 120_000)
  | "conservative" -> (0.70, 480, 250_000)
  | _ -> keeper_compaction_policy_from_env ()

let resolve_compaction_policy
    ~(profile_opt : string option)
    ~(ratio_opt : float option)
    ~(message_opt : int option)
    ~(token_opt : int option)
    ~(fallback_profile : string)
    ~(fallback_ratio : float)
    ~(fallback_message : int)
    ~(fallback_token : int) : string * float * int * int =
  let has_explicit_gate =
    Option.is_some ratio_opt || Option.is_some message_opt || Option.is_some token_opt
  in
  let base_profile =
    match profile_opt with
    | Some p -> p
    | None ->
        if has_explicit_gate then "custom" else fallback_profile
  in
  let (base_ratio, base_message, base_token) =
    match profile_opt with
    | Some p -> compaction_policy_of_profile p
    | None ->
        if has_explicit_gate then (fallback_ratio, fallback_message, fallback_token)
        else (fallback_ratio, fallback_message, fallback_token)
  in
  let ratio =
    Option.value ~default:base_ratio ratio_opt
    |> normalize_compaction_ratio_gate
  in
  let message_gate =
    Option.value ~default:base_message message_opt
    |> normalize_compaction_message_gate
  in
  let token_gate =
    Option.value ~default:base_token token_opt
    |> normalize_compaction_token_gate
  in
  (base_profile, ratio, message_gate, token_gate)

let keeper_batch_limit_rp =
  _rp_int ~key:"keeper.turn.batch_limit"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_BATCH_LIMIT"
                          ~default:200 ~min_v:10 ~max_v:2000)
    ~min_v:10 ~max_v:2000
    ~description:"Max batch size per keeper cycle" ()
let keeper_batch_limit () : int =
  Runtime_params.get keeper_batch_limit_rp





(* ================================================================ *)
(* Keeper execution — previously hardcoded magic numbers             *)
(* ================================================================ *)

(* ================================================================ *)
(* Unified Keeper Turn parameters                                   *)
(* ================================================================ *)

let keeper_unified_temperature_rp =
  _rp_float ~key:"keeper.turn.temperature"
    ~default:(fun () -> float_of_env_default "MASC_KEEPER_UNIFIED_TEMP"
                          ~default:0.4 ~min_v:0.0 ~max_v:2.0)
    ~min_v:0.0 ~max_v:2.0
    ~description:"Keeper turn temperature" ()
let keeper_unified_temperature () : float =
  Runtime_params.get keeper_unified_temperature_rp

let keeper_unified_max_tokens_rp =
  _rp_int ~key:"keeper.turn.max_output_tokens"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_UNIFIED_MAX_TOKENS"
                          ~default:65536 ~min_v:256 ~max_v:262144)
    ~min_v:256 ~max_v:262144
    ~description:"Keeper turn max output tokens fallback (runtime.toml may override in production)" ()
let keeper_unified_max_tokens () : int =
  Runtime_params.get keeper_unified_max_tokens_rp

(* ── HITL context-summary worker policy ─────────────────────── *)

(** Timeout for the HITL summary LLM call. Kept short because the summary
    is advisory and must not block operator attention. *)
let hitl_summary_timeout_sec_rp =
  _rp_float ~key:"keeper.hitl_summary.timeout_sec"
    ~default:(fun () -> float_of_env_default "MASC_KEEPER_HITL_SUMMARY_TIMEOUT_SEC"
                          ~default:30.0 ~min_v:1.0 ~max_v:300.0)
    ~min_v:1.0 ~max_v:300.0
    ~description:"HITL context-summary LLM timeout (seconds)" ()
let hitl_summary_timeout_sec () : float =
  Runtime_params.get hitl_summary_timeout_sec_rp

(** Temperature for the HITL summary LLM call. Deterministic by default. *)
let hitl_summary_temperature_rp =
  _rp_float ~key:"keeper.hitl_summary.temperature"
    ~default:(fun () -> float_of_env_default "MASC_KEEPER_HITL_SUMMARY_TEMPERATURE"
                          ~default:0.0 ~min_v:0.0 ~max_v:2.0)
    ~min_v:0.0 ~max_v:2.0
    ~description:"HITL context-summary sampling temperature" ()
let hitl_summary_temperature () : float =
  Runtime_params.get hitl_summary_temperature_rp

(** Force module initialization to guarantee all runtime params are registered
    before [Runtime_params.restore]. Call from server bootstrap. *)
let ensure_runtime_params_init () =
  let (_ : float) = Runtime_params.get keeper_unified_temperature_rp in
  let (_ : float) = Runtime_params.get hitl_summary_timeout_sec_rp in
  let (_ : float) = Runtime_params.get hitl_summary_temperature_rp in
  ()

let keeper_enable_thinking_rp =
  _rp_bool ~key:"keeper.turn.enable_thinking"
    ~default:(fun () -> bool_of_env_default "MASC_KEEPER_ENABLE_THINKING" ~default:false)
    ~description:"Pass enable_thinking to OAS (default: false; Ollama+Qwen3.5 consumes all tokens in thinking mode)" ()

let keeper_enable_thinking () : bool =
  Runtime_params.get keeper_enable_thinking_rp
