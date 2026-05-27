(** Keeper configuration — defaults, environment variable parsing, profiles. *)

open Tool_args
include Keeper_config_rp_helpers

(** Upper bound for keeper time configs expressed in seconds.  Repeated
    seven times as the bare literal [172800] across this file before
    the extraction; [Masc_time_constants.day_int * 2] makes the "2 days"
    intent explicit and satisfies sw-dev §"Magic Number 금지". *)
let two_days_seconds_int = Masc_time_constants.day_int * 2

(** Default cascade name for keeper turns. Resolved through the live
    [Cascade_catalog_runtime] snapshot so the answer reflects the
    currently-installed catalog rather than module-init state. Falls
    back to [Cascade_routes.cascade_name_for_use Keeper_turn] (canonical
    route path) when the snapshot is not yet available, which matches
    pre-RFC-0066 behavior during early boot.

    RFC-0066 Phase 1: was a string value evaluated at module init,
    freezing to the static fallback when the catalog was empty at
    init time. See issue #14624. *)
let default_cascade_name () =
  match Cascade_catalog_runtime.resolve_declared_name ~raw_name:"" () with
  | Ok name -> Cascade_name.to_string name
  | Error _ ->
    Keeper_cascade_profile.cascade_name_for_use
      Keeper_cascade_profile.Keeper_turn


(** Cascade name for recovery turns when keeper is in Failing phase.
    Two-profile deployments no longer maintain a separate local recovery lane;
    recovery reuses the canonical keeper cascade. *)
let phase_recovery_cascade_name =
  Keeper_cascade_profile.cascade_name_for_use
    Keeper_cascade_profile.Phase_recovery

(** Cascade name for buffer operations (compacting, handing off). *)
let phase_buffer_cascade_name =
  Keeper_cascade_profile.cascade_name_for_use
    Keeper_cascade_profile.Phase_buffer

let phase_routing_cascade_names =
  [ phase_buffer_cascade_name; phase_recovery_cascade_name ]
  |> List.sort_uniq String.compare
;;

(** Cascade name for turns that must use a tool-capable provider lane. *)
let tool_required_cascade_name =
  Keeper_cascade_profile.cascade_name_for_use
    Keeper_cascade_profile.Tool_required

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

(* ── Tool policy display thresholds ───────────────────────── *)

(** Warn when tool policy allows more than this many schemas. *)
let tool_policy_count_warn_threshold = 100

(** Truncate tool description auto-hints at this many chars.
    150 chars preserves op enums and parameter hints that
    9B models need to call tools correctly on the first attempt. *)
let tool_first_sentence_max_chars = 150

let () =
  if not
       (alert_excerpt_min_chars < alert_message_preview_max_chars
       && alert_message_preview_max_chars < alert_reply_preview_max_chars)
  then
    invalid_arg
      "Keeper_config alert preview lengths must satisfy excerpt < message < reply";
  if alert_error_detail_max_chars <= 0 then
    invalid_arg "Keeper_config alert_error_detail_max_chars must be positive";
  if tool_policy_count_warn_threshold <= 0 then
    invalid_arg
      "Keeper_config tool_policy_count_warn_threshold must be positive";
  if tool_first_sentence_max_chars <= 0 then
    invalid_arg "Keeper_config tool_first_sentence_max_chars must be positive"

include Keeper_config_text


let keeper_status_fast_default () : bool =
  bool_of_env_default "MASC_KEEPER_STATUS_FAST_DEFAULT" ~default:false

(* #11111: was 0.5, which fired ContextOverflowImminent at half-window
   on every keeper turn (18 events / 2d, all in 0.50–0.55 band).
   OAS pipeline applies a hard floor of 0.9 when this is unset; we
   stay just below that so compaction has room to run before the
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
let keeper_continuity_compaction_cooldown_sec_rp =
  _rp_int ~key:"keeper.compaction.cooldown_sec"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_CONTINUITY_COMPACTION_COOLDOWN_SEC"
                          ~default:15 ~min_v:0 ~max_v:two_days_seconds_int)
    ~min_v:0 ~max_v:two_days_seconds_int
    ~description:"Compaction cooldown (seconds)" ()
let keeper_continuity_compaction_cooldown_sec () : int =
  Runtime_params.get keeper_continuity_compaction_cooldown_sec_rp

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

let keeper_bootstrap_retry_max_rp =
  _rp_int ~key:"keeper.bootstrap.retry_max"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_BOOTSTRAP_RETRY_MAX"
                          ~default:5 ~min_v:0 ~max_v:20)
    ~min_v:0 ~max_v:20
    ~description:"Maximum retry rounds for keepers that fail initial boot" ()
let keeper_bootstrap_retry_max () : int =
  Runtime_params.get keeper_bootstrap_retry_max_rp

let keeper_bootstrap_retry_interval_sec_rp =
  _rp_int ~key:"keeper.bootstrap.retry_interval_sec"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_BOOTSTRAP_RETRY_INTERVAL_SEC"
                          ~default:30 ~min_v:5 ~max_v:300)
    ~min_v:5 ~max_v:300
    ~description:"Delay between autoboot retry rounds (seconds)" ()
let keeper_bootstrap_retry_interval_sec () : int =
  Runtime_params.get keeper_bootstrap_retry_interval_sec_rp

let keeper_proactive_min_cooldown_sec_rp =
  _rp_int ~key:"keeper.proactive.min_cooldown_sec"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_PROACTIVE_MIN_COOLDOWN_SEC"
                          ~default:300 ~min_v:60 ~max_v:1800)
    ~min_v:60 ~max_v:1800
    ~description:"Proactive turn minimum cooldown (seconds)" ()
let keeper_proactive_min_cooldown_sec () : int =
  Runtime_params.get keeper_proactive_min_cooldown_sec_rp

let keeper_proactive_min_interval_sec_rp =
  _rp_int ~key:"keeper.proactive.min_interval_sec"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_PROACTIVE_MIN_INTERVAL_SEC"
                          ~default:900 ~min_v:60 ~max_v:86400)
    ~min_v:60 ~max_v:86400
    ~description:"Minimum proactive turn interval (seconds). Keeper fires a \
                  housekeeping turn at least this often, even with no observable \
                  work signals." ()
let keeper_proactive_min_interval_sec () : int =
  Runtime_params.get keeper_proactive_min_interval_sec_rp

let keeper_proactive_task_cooldown_divisor_rp =
  _rp_int ~key:"keeper.proactive.task_cooldown_divisor"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_PROACTIVE_TASK_COOLDOWN_DIVISOR"
                          ~default:3 ~min_v:1 ~max_v:12)
    ~min_v:1 ~max_v:12
    ~description:"Task cooldown = proactive_cooldown / divisor" ()
let keeper_proactive_task_cooldown_divisor () : int =
  Runtime_params.get keeper_proactive_task_cooldown_divisor_rp

let keeper_proactive_task_min_cooldown_sec_rp =
  _rp_int ~key:"keeper.proactive.task_min_cooldown_sec"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_PROACTIVE_TASK_MIN_COOLDOWN_SEC"
                          ~default:60 ~min_v:1 ~max_v:1800)
    ~min_v:1 ~max_v:1800
    ~description:"Task-triggered proactive minimum cooldown (seconds)" ()
let keeper_proactive_task_min_cooldown_sec () : int =
  Runtime_params.get keeper_proactive_task_min_cooldown_sec_rp

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

let normalize_continuity_compaction_cooldown_sec (v : int) : int =
  clamp_int v ~min_v:0 ~max_v:two_days_seconds_int

(** Default number of recent tool results to keep verbatim during
    OAS context compaction (consumed by
    [Agent_sdk.Context_reducer.stub_tool_results ~keep_recent]).
    Preserves prior hardcoded behavior in [keeper_compact_policy.ml]. *)
let default_keep_recent_tool_results = 2

(** Default message-count floor for the tool-heavy compaction gate.
    Mirrors the prior global constant in [keeper_compact_policy.ml].
    Per-keeper override lives at [compaction_policy.tool_heavy_msg_threshold];
    wired into [decide_compaction] by PR-B.

    Operator override (PR-C, this commit): [MASC_KEEPER_TOOL_HEAVY_MSG_THRESHOLD]
    sets the global default that personas without an explicit value inherit.
    Valid range [1, 10_000]; out-of-range or unparseable values warn and fall
    back to the built-in default 40 (parse-correctness, not silent coercion —
    mirrors [emergency_compact_ratio_threshold] in
    [Keeper_compact_policy]). Read once at module init; restart required. *)
let default_tool_heavy_msg_threshold : int =
  let env_var = "MASC_KEEPER_TOOL_HEAVY_MSG_THRESHOLD" in
  let default_value = 40 in
  let min_valid = 1 in
  let max_valid = 10_000 in
  match Sys.getenv_opt env_var with
  | None -> default_value
  | Some raw ->
    (match int_of_string_opt (String.trim raw) with
     | None ->
       Log.Keeper.warn
         "[keeper_config] %s=%S is not a parseable int; falling back to default \
          %d"
         env_var raw default_value;
       default_value
     | Some parsed when parsed < min_valid || parsed > max_valid ->
       Log.Keeper.warn
         "[keeper_config] %s=%d out of range [%d, %d]; falling back to default \
          %d"
         env_var parsed min_valid max_valid default_value;
       default_value
     | Some parsed -> parsed)

(** Default context-ratio floor for the tool-heavy compaction gate.
    Mirrors the prior global constant in [keeper_compact_policy.ml].
    Per-keeper override lives at [compaction_policy.tool_heavy_ratio_floor];
    wired into [decide_compaction] by PR-B.

    Operator override (PR-C, this commit): [MASC_KEEPER_TOOL_HEAVY_RATIO_FLOOR]
    sets the global default that personas without an explicit value inherit.
    Valid range [0.0, 1.0); out-of-range, non-finite, or unparseable values
    warn and fall back to the built-in default 0.15 (parse-correctness;
    mirrors [emergency_compact_ratio_threshold]). Read once at module init. *)
let default_tool_heavy_ratio_floor : float =
  let env_var = "MASC_KEEPER_TOOL_HEAVY_RATIO_FLOOR" in
  let default_value = 0.15 in
  let min_valid = 0.0 in
  let max_valid = 1.0 in
  match Sys.getenv_opt env_var with
  | None -> default_value
  | Some raw ->
    (match Float.of_string_opt (String.trim raw) with
     | None ->
       Log.Keeper.warn
         "[keeper_config] %s=%S is not a parseable float; falling back to \
          default %.2f"
         env_var raw default_value;
       default_value
     | Some parsed when not (Float.is_finite parsed) ->
       Log.Keeper.warn
         "[keeper_config] %s=%s parsed to non-finite %f; falling back to \
          default %.2f"
         env_var raw parsed default_value;
       default_value
     | Some parsed when parsed < min_valid || parsed >= max_valid ->
       Log.Keeper.warn
         "[keeper_config] %s=%f out of range [%.2f, %.2f); falling back to \
          default %.2f"
         env_var parsed min_valid max_valid default_value;
       default_value
     | Some parsed -> parsed)

(** Hard upper bound for operator-supplied [keep_recent_tool_results].
    Values above this likely indicate operator typos (e.g. 5000); we
    log a warn and clamp back to the safe default so a typo does not
    silently disable compaction.  Lower bound is 0 (keep none). *)
let keep_recent_tool_results_max = 50

(** Validate and normalize [keep_recent_tool_results].
    Returns the in-range value untouched, or [default_keep_recent_tool_results]
    after logging a warn when the operator-supplied value is out of
    [0, keep_recent_tool_results_max].  Caller context (keeper name)
    is included in the warn for triage. *)
let normalize_keep_recent_tool_results ?keeper_name (v : int) : int =
  if v >= 0 && v <= keep_recent_tool_results_max
  then v
  else begin
    let ctx =
      match keeper_name with
      | Some n -> Printf.sprintf " keeper=%s" n
      | None -> ""
    in
    Log.Keeper.warn
      "[compaction] keep_recent_tool_results=%d out of range [0,%d];%s \
       clamping to default %d"
      v
      keep_recent_tool_results_max
      ctx
      default_keep_recent_tool_results;
    default_keep_recent_tool_results
  end

let default_compaction_profile = "custom"

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

let normalize_proactive_idle_sec (v : int) : int =
  clamp_int v ~min_v:0 ~max_v:two_days_seconds_int

let normalize_proactive_cooldown_sec (v : int) : int =
  clamp_int v ~min_v:0 ~max_v:two_days_seconds_int


let keeper_batch_limit_rp =
  _rp_int ~key:"keeper.turn.batch_limit"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_BATCH_LIMIT"
                          ~default:200 ~min_v:10 ~max_v:2000)
    ~min_v:10 ~max_v:2000
    ~description:"Max batch size per keeper cycle" ()
let keeper_batch_limit () : int =
  Runtime_params.get keeper_batch_limit_rp

let keeper_board_debounce_window_sec_rp =
  _rp_float ~key:"keeper.board.debounce_window_sec"
    ~default:(fun () -> float_of_env_default "MASC_KEEPER_BOARD_DEBOUNCE_SEC"
                          ~default:2.0 ~min_v:0.0 ~max_v:30.0)
    ~min_v:0.0 ~max_v:30.0
    ~description:"Time window to coalesce board signals into one turn (seconds)" ()
let keeper_board_debounce_window_sec () : float =
  Runtime_params.get keeper_board_debounce_window_sec_rp

let keeper_tool_cost_max_usd_rp =
  _rp_float ~key:"keeper.turn.tool_cost_max_usd"
    ~default:(fun () -> float_of_env_default "MASC_KEEPER_TOOL_COST_MAX_USD"
                          ~default:0.0 ~min_v:0.0 ~max_v:50.0)
    ~min_v:0.0 ~max_v:50.0
    ~description:"Per-tool cost ceiling (USD, 0=disabled)" ()
let keeper_tool_cost_max_usd () : float option =
  match Runtime_params.get keeper_tool_cost_max_usd_rp with
  | v when Float.compare v 0.0 <= 0 -> None
  | v -> Some v

let keeper_max_tools_per_turn_rp =
  _rp_int ~key:"keeper.turn.max_tools_per_turn"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_MAX_TOOLS_PER_TURN"
                          ~default:40 ~min_v:5 ~max_v:200)
    ~min_v:5 ~max_v:200
    ~description:"Max tools visible per turn (progressive disclosure cap)" ()
let keeper_max_tools_per_turn () : int =
  Runtime_params.get keeper_max_tools_per_turn_rp

let keeper_retry_max_tools_per_turn () : int =
  min 15 (keeper_max_tools_per_turn ())

let keeper_board_event_limit_rp =
  _rp_int ~key:"keeper.turn.board_event_limit"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_BOARD_EVENT_LIMIT"
                          ~default:10 ~min_v:1 ~max_v:50)
    ~min_v:1 ~max_v:50
    ~description:"Max board events injected per turn" ()
let keeper_board_event_limit () : int =
  Runtime_params.get keeper_board_event_limit_rp

let keeper_llm_rerank_enabled_rp =
  _rp_bool ~key:"keeper.turn.llm_rerank"
    ~default:(fun () -> bool_of_env_default "MASC_KEEPER_LLM_RERANK" ~default:false)
    ~description:"Enable LLM reranking of BM25 tool search results" ()
let keeper_llm_rerank_enabled () : bool =
  Runtime_params.get keeper_llm_rerank_enabled_rp

(** Named cascade profile for the LLM reranker.
    Env: [MASC_KEEPER_LLM_RERANK_CASCADE]. Default: [routes.llm_rerank]. *)
let keeper_llm_rerank_cascade () : string =
  match Env_config_core.raw_value_opt "MASC_KEEPER_LLM_RERANK_CASCADE" with
  | Some v when String.trim v <> "" -> (
      let trimmed = String.trim v in
      match Keeper_cascade_profile.logical_use_of_string_opt trimmed with
      | Some use -> Keeper_cascade_profile.cascade_name_for_use use
      | None -> trimmed)
  | _ ->
      Keeper_cascade_profile.cascade_name_for_use
        Keeper_cascade_profile.Tool_rerank_use

include Keeper_config_rule_thresholds

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
    ~description:"Keeper turn max output tokens fallback (cascade.toml may override in production)" ()
let keeper_unified_max_tokens () : int =
  Runtime_params.get keeper_unified_max_tokens_rp

let keeper_tool_search_top_k_rp =
  _rp_int ~key:"keeper.turn.tool_search_top_k"
    ~default:(fun () -> 20)
    ~min_v:3 ~max_v:50
    ~description:"BM25 tool search top-k results per query" ()
let keeper_tool_search_top_k () : int =
  Runtime_params.get keeper_tool_search_top_k_rp

(* max_turns is set in keeper_agent_run.ml from keeper runtime config.
   Known constraints (retain for future tuning):
   - 1000 turns caused 787s+ latency per turn
   - 20 turns caused 6.7GB RSS in 2 minutes with 3 concurrent keepers
   - 3 turns left keepers unable to do meaningful work (board_post x3 only)
   - 10 turns was insufficient for multi-step tasks (PR creation, web search)
   - historical 50-turn experiments balanced completion rate vs resource usage *)

(** Force module initialization to guarantee all runtime params are registered
    before [Runtime_params.restore]. Call from server bootstrap. *)
let ensure_runtime_params_init () =
  ignore (Runtime_params.get keeper_unified_temperature_rp)

let keeper_slot_pool_size_rp =
  _rp_int ~key:"keeper.turn.slot_pool_size"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_SLOT_POOL_SIZE"
                          ~default:4 ~min_v:0 ~max_v:32)
    ~min_v:0 ~max_v:32
    ~description:"slot pool size for keeper deterministic pinning (0=disabled)" ()
let keeper_slot_pool_size () : int =
  Runtime_params.get keeper_slot_pool_size_rp

(** Compute a deterministic slot_id for a keeper name.
    Returns [None] when slot pinning is disabled (num_slots = 0). *)
let keeper_slot_id (name : string) : int option =
  let num_slots = keeper_slot_pool_size () in
  if num_slots <= 0 then None
  else
    let h = Hashtbl.hash name in
    Some (h mod num_slots)

let keeper_enable_thinking_rp =
  _rp_bool ~key:"keeper.turn.enable_thinking"
    ~default:(fun () -> bool_of_env_default "MASC_KEEPER_ENABLE_THINKING" ~default:false)
    ~description:"Pass enable_thinking to OAS (default: false; Ollama+Qwen3.5 consumes all tokens in thinking mode)" ()

let keeper_enable_thinking () : bool =
  Runtime_params.get keeper_enable_thinking_rp

let keeper_adaptive_thinking_enabled_rp =
  _rp_bool ~key:"keeper.turn.adaptive_thinking"
    ~default:(fun () -> bool_of_env_default "MASC_KEEPER_ADAPTIVE_THINKING" ~default:false)
    ~description:"Enable pipeline signal-based per-turn adaptive thinking" ()

let keeper_adaptive_thinking_enabled () : bool =
  Runtime_params.get keeper_adaptive_thinking_enabled_rp

(* Separate flag from [adaptive_thinking_enabled] (which only tunes the
   thinking BUDGET via [adaptive_thinking_budget]). This flag toggles a
   per-turn BOOLEAN override of [enable_thinking] based on turn intent
   classification (see [Keeper_turn_intent]). When both are true, users
   get dynamic budget AND dynamic on/off. When only this is true, the
   budget stays static but on/off adapts.

   Precedence: when this flag is on, per-turn classification can set
   [enable_thinking = Some true/false] which overrides the static
   [MASC_KEEPER_ENABLE_THINKING] base. When off, falls back to the
   static base (unchanged legacy behavior). *)
let keeper_adaptive_thinking_mode_rp =
  _rp_bool ~key:"keeper.turn.adaptive_thinking_mode"
    ~default:(fun () -> bool_of_env_default "MASC_KEEPER_ADAPTIVE_THINKING_MODE" ~default:true)
    ~description:"Enable per-turn boolean enable_thinking override driven by \
                  Keeper_turn_intent classification (Mechanical → false, \
                  Cognitive → true). Independent of adaptive_thinking budget \
                  flag. Default: on (set MASC_KEEPER_ADAPTIVE_THINKING_MODE=false \
                  to opt out)." ()

let keeper_adaptive_thinking_mode () : bool =
  Runtime_params.get keeper_adaptive_thinking_mode_rp
