(** Keeper configuration — defaults, environment variable parsing, profiles. *)

open Tool_args

let bool_default_true_of_env name =
  match Sys.getenv_opt name with
  | None -> true
  | Some v ->
      let v = String.trim v |> String.lowercase_ascii in
      not (v = "0" || v = "false" || v = "no" || v = "n")

let bool_of_env_default name ~(default : bool) =
  match Sys.getenv_opt name with
  | None -> default
  | Some raw ->
      let v = String.trim raw |> String.lowercase_ascii in
      if v = "1" || v = "true" || v = "yes" || v = "y" || v = "on" then true
      else if v = "0" || v = "false" || v = "no" || v = "n" || v = "off" then false
      else default

let bool_of_env_opt name =
  match Sys.getenv_opt name with
  | None -> None
  | Some raw ->
      let v = String.trim raw |> String.lowercase_ascii in
      if v = "1" || v = "true" || v = "yes" || v = "y" || v = "on" then Some true
      else if v = "0" || v = "false" || v = "no" || v = "n" || v = "off" then Some false
      else None

let validate_name name =
  (* Same rule as keeper script: conservative handle chars only. *)
  let re = Re.Pcre.re "^[A-Za-z0-9._-]+$" |> Re.compile in
  name <> "" && Re.execp re name

let default_execution_scope = "workspace"
let default_proactive_enabled = true
let default_proactive_idle_sec = 900
let default_proactive_cooldown_sec = 1800
let default_keeper_will = ""
let default_keeper_needs = ""
let default_keeper_desires = ""
let default_room_signal_prompt_enabled = false
let default_goal_horizon_max_chars = 480
let default_drift_max_clauses = 6
let default_drift_max_chars = 320

let keeper_room_signal_prompt_enabled_override () =
  bool_of_env_opt "MASC_KEEPER_ROOM_SIGNAL_PROMPT_ENABLED"


let removed_keeper_input_key_names =
  [
    "models";
    "allowed_models";
    "active_model";
    "presence_keepalive";
    "presence_keepalive_sec";
    "trigger_mode";
    "policy_action_budget";
    "initiative_scope";
    "initiative_enabled";
    "initiative_idle_sec";
    "initiative_cooldown_sec";
    "policy_mode";
    "policy_shell_mode";
    
  ]

let removed_keeper_msg_input_key_names =
  [
    "goal";
    "short_goal";
    "mid_goal";
    "long_goal";
    "instructions";
    
    "will";
    "needs";
    "desires";
    "require_existing";
    "new_goal";
    "new_short_goal";
    "new_mid_goal";
    "new_long_goal";
    "new_instructions";
    
    "new_will";
    "new_needs";
    "new_desires";
  ]

let removed_keeper_meta_key_names =
  "persona_profile_path" :: removed_keeper_input_key_names

let present_json_keys (keys : string list) (json : Yojson.Safe.t) : string list =
  match json with
  | `Assoc fields ->
      keys
      |> List.filter (fun key -> List.mem_assoc key fields)
  | _ -> []

let reject_removed_keeper_input_keys ~tool_name (args : Yojson.Safe.t) =
  let present = present_json_keys removed_keeper_input_key_names args in
  match present with
  | [] -> Ok ()
  | fields ->
      Error
        (Printf.sprintf
           "removed keeper args for %s: %s. Keepers are always-on by definition."
           tool_name
           (String.concat ", " fields))

let reject_removed_keeper_msg_input_keys ~tool_name (args : Yojson.Safe.t) =
  let present = present_json_keys removed_keeper_msg_input_key_names args in
  match present with
  | [] -> Ok ()
  | fields ->
      Error
        (Printf.sprintf
           "removed keeper message args for %s: %s. Use masc_keeper_up for keeper creation or persisted updates."
           tool_name
           (String.concat ", " fields))

let utf8_safe_prefix_bytes (s : string) ~(max_bytes : int) : string =
  if max_bytes <= 0 then ""
  else
    let len = String.length s in
    if len <= max_bytes then s
    else
      let rec loop i last_good =
        if i >= len || i >= max_bytes then last_good
        else
          let dec = String.get_utf_8_uchar s i in
          let dlen = Uchar.utf_decode_length dec in
          if dlen <= 0 then last_good
          else
            let next = i + dlen in
            if next > max_bytes then last_good
            else loop next next
      in
      let cut = loop 0 0 in
      if cut <= 0 then ""
      else String.sub s 0 cut

let utf8_repair_string (s : string) : string =
  let len = String.length s in
  let buf = Buffer.create len in
  let rec loop i =
    if i >= len then ()
    else
      let dec = String.get_utf_8_uchar s i in
      let dlen = Uchar.utf_decode_length dec in
      if dlen > 0 && Uchar.utf_decode_is_valid dec then (
        Buffer.add_substring buf s i dlen;
        loop (i + dlen))
      else (
        Buffer.add_string buf "\xEF\xBF\xBD";
        loop (i + 1))
  in
  loop 0;
  Buffer.contents buf

let normalize_self_model_text ?(max_len = default_drift_max_chars) (raw : string) : string =
  let s = String.trim raw in
  if s = "" then ""
  else utf8_safe_prefix_bytes s ~max_bytes:max_len

let normalize_goal_horizon_text ?(max_len = default_goal_horizon_max_chars) (raw : string) : string =
  let s = String.trim raw in
  if s = "" then ""
  else utf8_safe_prefix_bytes s ~max_bytes:max_len

let normalize_goal_horizon_opt (raw_opt : string option) : string option =
  match raw_opt with
  | None -> None
  | Some raw ->
    let normalized = normalize_goal_horizon_text raw in
    if normalized = "" then None else Some normalized

let parse_goal_horizon_opt args key : string option =
  normalize_goal_horizon_opt (get_string_opt args key)

let resolve_goal_horizons
    ~(goal : string)
    ~(short_goal_opt : string option)
    ~(mid_goal_opt : string option)
    ~(long_goal_opt : string option) : string * string * string =
  let short_goal =
    Option.value ~default:goal short_goal_opt
    |> normalize_goal_horizon_text
  in
  let mid_goal =
    Option.value ~default:goal mid_goal_opt
    |> normalize_goal_horizon_text
  in
  let long_goal =
    Option.value ~default:goal long_goal_opt
    |> normalize_goal_horizon_text
  in
  (short_goal, mid_goal, long_goal)

let split_semicolon_clauses (raw : string) : string list =
  raw
  |> String.split_on_char ';'
  |> List.map String.trim
  |> List.filter (fun s -> s <> "")

let take_last n xs =
  if n <= 0 then []
  else
    let len = List.length xs in
    if len <= n then xs
    else
      let rec drop k ys =
        if k <= 0 then ys
        else
          match ys with
          | [] -> []
          | _ :: tl -> drop (k - 1) tl
      in
      drop (len - n) xs

let compact_self_model_text
    ?(max_clauses = default_drift_max_clauses)
    ?(max_chars = default_drift_max_chars)
    (raw : string) : string =
  raw
  |> split_semicolon_clauses
  |> take_last max_clauses
  |> String.concat "; "
  |> normalize_self_model_text ~max_len:max_chars

let parse_self_model_opt args key : string option =
  match get_string_opt args key with
  | None -> None
  | Some raw -> Some (normalize_self_model_text raw)

let clamp_int v ~min_v ~max_v =
  max min_v (min max_v v)

let int_of_env_default name ~default ~min_v ~max_v =
  match Sys.getenv_opt name with
  | None -> default
  | Some raw ->
      let v =
        try int_of_string (String.trim raw)
        with Failure _ -> default
      in
      clamp_int v ~min_v ~max_v

let float_of_env_default name ~default ~min_v ~max_v =
  match Sys.getenv_opt name with
  | None -> default
  | Some raw ->
      let v =
        try float_of_string (String.trim raw)
        with Failure _ -> default
      in
      max min_v (min max_v v)

let keeper_status_fast_default () : bool =
  bool_of_env_default "MASC_KEEPER_STATUS_FAST_DEFAULT" ~default:false

let keeper_compact_ratio () : float =
  float_of_env_default
    "MASC_KEEPER_COMPACT_RATIO"
    ~default:0.5
    ~min_v:0.1
    ~max_v:0.98

let keeper_compact_max_messages () : int =
  int_of_env_default
    "MASC_KEEPER_COMPACT_MAX_MESSAGES"
    ~default:240
    ~min_v:0
    ~max_v:5000

let keeper_compact_max_tokens () : int =
  int_of_env_default
    "MASC_KEEPER_COMPACT_MAX_TOKENS"
    ~default:8000
    ~min_v:0
    ~max_v:5000000

(** Cooldown between compaction attempts.  Previous default (90s) exceeded
    the proactive heartbeat interval (30s), permanently blocking compaction
    for proactive keepers.  15s allows compaction to fire every other cycle. *)
let keeper_continuity_compaction_cooldown_sec () : int =
  int_of_env_default
    "MASC_KEEPER_CONTINUITY_COMPACTION_COOLDOWN_SEC"
    ~default:15
    ~min_v:0
    ~max_v:172800

let keeper_bootstrap_proactive_warmup_sec () : int =
  int_of_env_default
    "MASC_KEEPER_BOOTSTRAP_PROACTIVE_WARMUP_SEC"
    ~default:60
    ~min_v:0
    ~max_v:172800

let keeper_bootstrap_stagger_step_sec () : int =
  int_of_env_default
    "MASC_KEEPER_BOOTSTRAP_STAGGER_STEP_SEC"
    ~default:15
    ~min_v:0
    ~max_v:120

let keeper_proactive_min_cooldown_sec () : int =
  int_of_env_default
    "MASC_KEEPER_PROACTIVE_MIN_COOLDOWN_SEC"
    ~default:300
    ~min_v:60
    ~max_v:1800

let keeper_proactive_task_cooldown_divisor () : int =
  int_of_env_default
    "MASC_KEEPER_PROACTIVE_TASK_COOLDOWN_DIVISOR"
    ~default:3
    ~min_v:1
    ~max_v:12

let keeper_proactive_task_min_cooldown_sec () : int =
  int_of_env_default
    "MASC_KEEPER_PROACTIVE_TASK_MIN_COOLDOWN_SEC"
    ~default:60
    ~min_v:1
    ~max_v:1800

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
  clamp_int v ~min_v:0 ~max_v:172800

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
  clamp_int v ~min_v:0 ~max_v:172800

let normalize_proactive_cooldown_sec (v : int) : int =
  clamp_int v ~min_v:0 ~max_v:172800


let keeper_batch_limit () : int =
  int_of_env_default
    "MASC_KEEPER_BATCH_LIMIT"
    ~default:200
    ~min_v:10
    ~max_v:2000

let keeper_tool_cost_max_usd () : float =
  float_of_env_default
    "MASC_KEEPER_TOOL_COST_MAX_USD"
    ~default:0.50
    ~min_v:0.01
    ~max_v:50.0

let keeper_max_tools_per_turn () : int =
  int_of_env_default
    "MASC_KEEPER_MAX_TOOLS_PER_TURN"
    ~default:40
    ~min_v:5
    ~max_v:200

let keeper_retry_max_tools_per_turn () : int =
  min 8 (keeper_max_tools_per_turn ())

(** Max board events presented to a keeper per turn.
    Higher values let keepers see more discussion context but
    increase prompt size. Env: [MASC_KEEPER_BOARD_EVENT_LIMIT]. *)
let keeper_board_event_limit () : int =
  int_of_env_default
    "MASC_KEEPER_BOARD_EVENT_LIMIT"
    ~default:10
    ~min_v:1
    ~max_v:50

(** Enable LLM reranking of BM25 tool retrieval results.
    When enabled, confident BM25 results are re-ordered by a small LLM
    call before progressive disclosure. Disabled by default.
    Env: [MASC_KEEPER_LLM_RERANK]. *)
let keeper_llm_rerank_enabled () : bool =
  bool_of_env_default "MASC_KEEPER_LLM_RERANK" ~default:false

(** Named cascade profile for the LLM reranker.
    Env: [MASC_KEEPER_LLM_RERANK_CASCADE]. Default: "tool_rerank". *)
let keeper_llm_rerank_cascade () : string =
  match Sys.getenv_opt "MASC_KEEPER_LLM_RERANK_CASCADE" with
  | Some v when String.trim v <> "" -> String.trim v
  | _ -> "tool_rerank"

(* ================================================================ *)
(* Rule engine thresholds                                           *)
(* ================================================================ *)

let keeper_rule_reflect_repetition_threshold () : float =
  float_of_env_default
    "MASC_KEEPER_RULE_REFLECT_REPETITION"
    ~default:0.86
    ~min_v:0.0
    ~max_v:1.0

let keeper_rule_plan_goal_alignment_threshold () : float =
  float_of_env_default
    "MASC_KEEPER_RULE_PLAN_GOAL_ALIGNMENT_MAX"
    ~default:0.06
    ~min_v:0.0
    ~max_v:1.0

let keeper_rule_plan_response_alignment_threshold () : float =
  float_of_env_default
    "MASC_KEEPER_RULE_PLAN_RESPONSE_ALIGNMENT_MAX"
    ~default:0.10
    ~min_v:0.0
    ~max_v:1.0

let keeper_rule_guardrail_repetition_threshold () : float =
  float_of_env_default
    "MASC_KEEPER_RULE_GUARDRAIL_REPETITION"
    ~default:0.90
    ~min_v:0.0
    ~max_v:1.0

let keeper_rule_guardrail_goal_alignment_threshold () : float =
  float_of_env_default
    "MASC_KEEPER_RULE_GUARDRAIL_GOAL_ALIGNMENT_MAX"
    ~default:0.04
    ~min_v:0.0
    ~max_v:1.0

let keeper_rule_guardrail_response_alignment_threshold () : float =
  float_of_env_default
    "MASC_KEEPER_RULE_GUARDRAIL_RESPONSE_ALIGNMENT_MAX"
    ~default:0.08
    ~min_v:0.0
    ~max_v:1.0

let keeper_rule_guardrail_context_threshold () : float =
  float_of_env_default
    "MASC_KEEPER_RULE_GUARDRAIL_CONTEXT_MIN"
    ~default:0.70
    ~min_v:0.0
    ~max_v:1.0

(* ================================================================ *)
(* Keeper execution — previously hardcoded magic numbers             *)
(* ================================================================ *)

(* ================================================================ *)
(* Unified Keeper Turn parameters                                   *)
(* ================================================================ *)

(** Temperature for unified keeper turns.
    Env: [MASC_KEEPER_UNIFIED_TEMP]. Default: 0.4. *)
let keeper_unified_temperature () : float =
  float_of_env_default
    "MASC_KEEPER_UNIFIED_TEMP"
    ~default:0.4
    ~min_v:0.0
    ~max_v:2.0

(** Max output tokens for unified keeper turns.
    Env: [MASC_KEEPER_UNIFIED_MAX_TOKENS]. Default: 2048. *)
let keeper_unified_max_tokens () : int =
  int_of_env_default
    "MASC_KEEPER_UNIFIED_MAX_TOKENS"
    ~default:2048
    ~min_v:256
    ~max_v:16000

(** Max agent turns (tool loops) for unified keeper turns.
    Env: [MASC_KEEPER_UNIFIED_MAX_TURNS]. Default: 3.
    Previous default (1000) caused 787s+ latency per turn.
    20 caused 6.7GB RSS in 2 minutes with 3 concurrent keepers.
    This value is the fallback; channel-aware functions below are preferred. *)
let keeper_unified_max_turns () : int =
  int_of_env_default
    "MASC_KEEPER_UNIFIED_MAX_TURNS"
    ~default:3
    ~min_v:1
    ~max_v:50

(** Max turns for reactive channel (responding to mentions, board events, messages).
    Reactive turns need more budget: read context -> reason -> act -> report.
    Env: [MASC_KEEPER_REACTIVE_MAX_TURNS]. Default: 8. *)
let keeper_reactive_max_turns () : int =
  int_of_env_default
    "MASC_KEEPER_REACTIVE_MAX_TURNS"
    ~default:8
    ~min_v:2
    ~max_v:30

(** Max turns for scheduled autonomous channel (proactive check-ins).
    Autonomous turns are "observe one thing, do one thing" cycles.
    Env: [MASC_KEEPER_AUTONOMOUS_MAX_TURNS]. Default: 5. *)
let keeper_autonomous_max_turns () : int =
  int_of_env_default
    "MASC_KEEPER_AUTONOMOUS_MAX_TURNS"
    ~default:5
    ~min_v:1
    ~max_v:20
