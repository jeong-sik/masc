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

let validate_max_context_override_value value =
  if value > 0
  then Ok value
  else
    Error
      (Printf.sprintf
         "max_context_override must be positive (received %d)"
         value)
;;

include Keeper_config_text


let keeper_status_fast_default () : bool =
  bool_of_env_default "MASC_KEEPER_STATUS_FAST_DEFAULT" ~default:false

(* masc#25052 P1: Memory OS recall selection budget. Before this,
   Keeper_memory_os_recall.render_context_exn injected the keeper's ENTIRE
   current fact/episode store into every turn's prompt -- no selection
   contract existed, so a keeper that accumulated facts/episodes without
   bound (no retention existed either -- see the episode retention wired
   into Keeper_memory_os_gc below) grew its per-turn prompt injection
   without limit. These three knobs are the boundary: how many facts, how
   many episodes, and how many rendered bytes recall may inject per turn.

   Defaults are set at/above the largest volume observed in the 2026-07-17
   lane analysis that diagnosed this (~300 facts, ~380 episode summaries,
   ~1.5MB rendered per keeper turn), so a typical keeper today is truncated
   by NONE of these -- this establishes a ceiling, not a retroactive
   downsizing. Operators tune live via Runtime_params (no restart) as real
   volumes grow. Truncation, when it does trigger, is always logged and
   counted (Keeper_metrics.MemoryOsRecallFactsTruncated /
   RecallEpisodesTruncated / RecallBytesOverBudget) -- never silent. *)
let keeper_memory_os_recall_max_facts_rp =
  _rp_int ~key:"keeper.memory_os.recall.max_facts"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_MEMORY_OS_RECALL_MAX_FACTS"
                          ~default:500 ~min_v:0 ~max_v:100_000)
    ~min_v:0 ~max_v:100_000
    ~description:"Max facts Memory OS recall injects per turn (0 = inject none)" ()
let keeper_memory_os_recall_max_facts () : int =
  Runtime_params.get keeper_memory_os_recall_max_facts_rp

let keeper_memory_os_recall_max_episodes_rp =
  _rp_int ~key:"keeper.memory_os.recall.max_episodes"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_MEMORY_OS_RECALL_MAX_EPISODES"
                          ~default:500 ~min_v:0 ~max_v:100_000)
    ~min_v:0 ~max_v:100_000
    ~description:"Max episodes Memory OS recall injects per turn (0 = inject none)" ()
let keeper_memory_os_recall_max_episodes () : int =
  Runtime_params.get keeper_memory_os_recall_max_episodes_rp

(* Observability-only for now: logged and counted
   (MemoryOsRecallBytesOverBudget) when the rendered block exceeds this, but
   not itself used to drop additional facts/episodes -- max_facts/
   max_episodes above are the enforced boundary. A byte-accurate secondary
   truncation is a reasonable follow-up once real overage data exists;
   scope-cut here rather than adding untested incremental-trim logic. 0
   disables the check (unbounded). *)
let keeper_memory_os_recall_max_bytes_rp =
  _rp_int ~key:"keeper.memory_os.recall.max_bytes"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_MEMORY_OS_RECALL_MAX_BYTES"
                          ~default:2_000_000 ~min_v:0 ~max_v:50_000_000)
    ~min_v:0 ~max_v:50_000_000
    ~description:"Rendered recall block byte threshold to log/count as over-budget (0 = disabled)" ()
let keeper_memory_os_recall_max_bytes () : int =
  Runtime_params.get keeper_memory_os_recall_max_bytes_rp
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

(** Force module initialization to guarantee all runtime params are registered
    before [Runtime_params.restore]. Call from server bootstrap. *)
let ensure_runtime_params_init () =
  let (_ : float) = Runtime_params.get keeper_unified_temperature_rp in
  let (_ : float) = Runtime_params.get hitl_summary_temperature_rp in
  ()

let keeper_enable_thinking_rp =
  _rp_bool ~key:"keeper.turn.enable_thinking"
    ~default:(fun () -> bool_of_env_default "MASC_KEEPER_ENABLE_THINKING" ~default:false)
    ~description:"Pass enable_thinking to OAS (default: false; Ollama+Qwen3.5 consumes all tokens in thinking mode)" ()

let keeper_enable_thinking () : bool =
  Runtime_params.get keeper_enable_thinking_rp
