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
(** Temperature for the HITL summary LLM call. Deterministic by default. *)
let hitl_summary_temperature_rp =
  _rp_float ~key:"keeper.hitl_summary.temperature"
    ~default:(fun () -> float_of_env_default "MASC_KEEPER_HITL_SUMMARY_TEMPERATURE"
                          ~default:0.0 ~min_v:0.0 ~max_v:2.0)
    ~min_v:0.0 ~max_v:2.0
    ~description:"HITL context-summary sampling temperature" ()
let hitl_summary_temperature () : float =
  Runtime_params.get hitl_summary_temperature_rp

(** Maximum number of request-local Auto Judge calls that may be in flight.
    A bounded queue prevents an operator recovery of a large durable backlog
    from turning into an unbounded provider burst. *)
let hitl_summary_max_concurrency_rp =
  _rp_int ~key:"keeper.hitl_summary.max_concurrency"
    ~default:(fun () ->
      int_of_env_default
        "MASC_KEEPER_HITL_SUMMARY_MAX_CONCURRENCY"
        ~default:4
        ~min_v:1
        ~max_v:32)
    ~min_v:1
    ~max_v:32
    ~description:"Maximum concurrent HITL Auto Judge calls" ()
let hitl_summary_max_concurrency () : int =
  Runtime_params.get hitl_summary_max_concurrency_rp

(** Force module initialization to guarantee all runtime params are registered
    before [Runtime_params.restore]. Call from server bootstrap. *)
let ensure_runtime_params_init () =
  let (_ : float) = Runtime_params.get keeper_unified_temperature_rp in
  let (_ : float) = Runtime_params.get hitl_summary_temperature_rp in
  let (_ : int) = Runtime_params.get hitl_summary_max_concurrency_rp in
  ()

let keeper_enable_thinking_rp =
  _rp_bool ~key:"keeper.turn.enable_thinking"
    ~default:(fun () -> bool_of_env_default "MASC_KEEPER_ENABLE_THINKING" ~default:false)
    ~description:"Pass enable_thinking to OAS (default: false; Ollama+Qwen3.5 consumes all tokens in thinking mode)" ()

let keeper_enable_thinking () : bool =
  Runtime_params.get keeper_enable_thinking_rp
