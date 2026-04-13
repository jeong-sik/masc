(** Keeper configuration — defaults, environment variable parsing, profiles. *)

open Tool_args

(** Default cascade name for keeper turns. SSOT — all keeper code must
    reference this constant instead of using the string literal. *)
let default_cascade_name = Keeper_cascade_profile.default_name

(** Minimum context window (tokens) for any keeper turn.
    64k-class local models are valid keeper backends; do not clamp them upward
    to 65,536, which can exceed the discovered provider ceiling. *)
let min_keeper_context_tokens = 64_000

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
let default_proactive_idle_sec = 120
let default_proactive_cooldown_sec = 300
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
  [
    "persona_profile_path";
    "active_team_session_id";
    "last_team_session_started_at";
    "team_session_start_count_total";
  ]
  @ removed_keeper_input_key_names

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
        Option.value ~default:default (int_of_string_opt (String.trim raw))
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

(* ================================================================ *)
(* Runtime_params helpers — serialization/validation for dashboard   *)
(* ================================================================ *)

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

let keeper_status_fast_default () : bool =
  bool_of_env_default "MASC_KEEPER_STATUS_FAST_DEFAULT" ~default:false

let keeper_compact_ratio_rp =
  _rp_float ~key:"keeper.compaction.ratio"
    ~default:(fun () -> float_of_env_default "MASC_KEEPER_COMPACT_RATIO"
                          ~default:0.5 ~min_v:0.1 ~max_v:0.98)
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
                          ~default:15 ~min_v:0 ~max_v:172800)
    ~min_v:0 ~max_v:172800
    ~description:"Compaction cooldown (seconds)" ()
let keeper_continuity_compaction_cooldown_sec () : int =
  Runtime_params.get keeper_continuity_compaction_cooldown_sec_rp

let keeper_bootstrap_proactive_warmup_sec_rp =
  _rp_int ~key:"keeper.proactive.warmup_sec"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_BOOTSTRAP_PROACTIVE_WARMUP_SEC"
                          ~default:60 ~min_v:0 ~max_v:172800)
    ~min_v:0 ~max_v:172800
    ~description:"Bootstrap proactive warmup delay (seconds)" ()
let keeper_bootstrap_proactive_warmup_sec () : int =
  Runtime_params.get keeper_bootstrap_proactive_warmup_sec_rp

let keeper_bootstrap_stagger_step_sec_rp =
  _rp_int ~key:"keeper.proactive.stagger_step_sec"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_BOOTSTRAP_STAGGER_STEP_SEC"
                          ~default:15 ~min_v:0 ~max_v:120)
    ~min_v:0 ~max_v:120
    ~description:"Bootstrap stagger interval between keepers (seconds)" ()
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


let keeper_batch_limit_rp =
  _rp_int ~key:"keeper.turn.batch_limit"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_BATCH_LIMIT"
                          ~default:200 ~min_v:10 ~max_v:2000)
    ~min_v:10 ~max_v:2000
    ~description:"Max batch size per keeper cycle" ()
let keeper_batch_limit () : int =
  Runtime_params.get keeper_batch_limit_rp

let keeper_tool_cost_max_usd_rp =
  _rp_float ~key:"keeper.turn.tool_cost_max_usd"
    ~default:(fun () -> float_of_env_default "MASC_KEEPER_TOOL_COST_MAX_USD"
                          ~default:0.50 ~min_v:0.01 ~max_v:50.0)
    ~min_v:0.01 ~max_v:50.0
    ~description:"Per-tool cost ceiling (USD)" ()
let keeper_tool_cost_max_usd () : float =
  Runtime_params.get keeper_tool_cost_max_usd_rp

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
    Env: [MASC_KEEPER_LLM_RERANK_CASCADE]. Default: "tool_rerank". *)
let keeper_llm_rerank_cascade () : string =
  match Sys.getenv_opt "MASC_KEEPER_LLM_RERANK_CASCADE" with
  | Some v when String.trim v <> "" -> String.trim v
  | _ -> "tool_rerank"

(* ================================================================ *)
(* Rule engine thresholds                                           *)
(* ================================================================ *)

let keeper_rule_reflect_repetition_rp =
  _rp_float ~key:"keeper.rule.reflect_repetition"
    ~default:(fun () -> float_of_env_default "MASC_KEEPER_RULE_REFLECT_REPETITION"
                          ~default:0.86 ~min_v:0.0 ~max_v:1.0)
    ~min_v:0.0 ~max_v:1.0
    ~description:"Reflect rule: repetition similarity threshold" ()
let keeper_rule_reflect_repetition_threshold () : float =
  Runtime_params.get keeper_rule_reflect_repetition_rp

let keeper_rule_plan_goal_alignment_rp =
  _rp_float ~key:"keeper.rule.plan_goal_alignment_max"
    ~default:(fun () -> float_of_env_default "MASC_KEEPER_RULE_PLAN_GOAL_ALIGNMENT_MAX"
                          ~default:0.06 ~min_v:0.0 ~max_v:1.0)
    ~min_v:0.0 ~max_v:1.0
    ~description:"Plan rule: goal alignment max distance" ()
let keeper_rule_plan_goal_alignment_threshold () : float =
  Runtime_params.get keeper_rule_plan_goal_alignment_rp

let keeper_rule_plan_response_alignment_rp =
  _rp_float ~key:"keeper.rule.plan_response_alignment_max"
    ~default:(fun () -> float_of_env_default "MASC_KEEPER_RULE_PLAN_RESPONSE_ALIGNMENT_MAX"
                          ~default:0.10 ~min_v:0.0 ~max_v:1.0)
    ~min_v:0.0 ~max_v:1.0
    ~description:"Plan rule: response alignment max distance" ()
let keeper_rule_plan_response_alignment_threshold () : float =
  Runtime_params.get keeper_rule_plan_response_alignment_rp

let keeper_rule_guardrail_repetition_rp =
  _rp_float ~key:"keeper.rule.guardrail_repetition"
    ~default:(fun () -> float_of_env_default "MASC_KEEPER_RULE_GUARDRAIL_REPETITION"
                          ~default:0.90 ~min_v:0.0 ~max_v:1.0)
    ~min_v:0.0 ~max_v:1.0
    ~description:"Guardrail rule: repetition similarity threshold" ()
let keeper_rule_guardrail_repetition_threshold () : float =
  Runtime_params.get keeper_rule_guardrail_repetition_rp

let keeper_rule_guardrail_goal_alignment_rp =
  _rp_float ~key:"keeper.rule.guardrail_goal_alignment_max"
    ~default:(fun () -> float_of_env_default "MASC_KEEPER_RULE_GUARDRAIL_GOAL_ALIGNMENT_MAX"
                          ~default:0.04 ~min_v:0.0 ~max_v:1.0)
    ~min_v:0.0 ~max_v:1.0
    ~description:"Guardrail rule: goal alignment max distance" ()
let keeper_rule_guardrail_goal_alignment_threshold () : float =
  Runtime_params.get keeper_rule_guardrail_goal_alignment_rp

let keeper_rule_guardrail_response_alignment_rp =
  _rp_float ~key:"keeper.rule.guardrail_response_alignment_max"
    ~default:(fun () -> float_of_env_default "MASC_KEEPER_RULE_GUARDRAIL_RESPONSE_ALIGNMENT_MAX"
                          ~default:0.08 ~min_v:0.0 ~max_v:1.0)
    ~min_v:0.0 ~max_v:1.0
    ~description:"Guardrail rule: response alignment max distance" ()
let keeper_rule_guardrail_response_alignment_threshold () : float =
  Runtime_params.get keeper_rule_guardrail_response_alignment_rp

let keeper_rule_guardrail_context_rp =
  _rp_float ~key:"keeper.rule.guardrail_context_min"
    ~default:(fun () -> float_of_env_default "MASC_KEEPER_RULE_GUARDRAIL_CONTEXT_MIN"
                          ~default:0.70 ~min_v:0.0 ~max_v:1.0)
    ~min_v:0.0 ~max_v:1.0
    ~description:"Guardrail rule: minimum context ratio" ()
let keeper_rule_guardrail_context_threshold () : float =
  Runtime_params.get keeper_rule_guardrail_context_rp

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
    ~description:"Keeper turn max output tokens fallback (cascade.json overrides to 16384 in production)" ()
let keeper_unified_max_tokens () : int =
  Runtime_params.get keeper_unified_max_tokens_rp

let keeper_tool_search_top_k_rp =
  _rp_int ~key:"keeper.turn.tool_search_top_k"
    ~default:(fun () -> 20)
    ~min_v:3 ~max_v:50
    ~description:"BM25 tool search top-k results per query" ()
let keeper_tool_search_top_k () : int =
  Runtime_params.get keeper_tool_search_top_k_rp

(* max_turns is set in keeper_agent_run.ml (default: 50).
   Known constraints (retain for future tuning):
   - 1000 turns caused 787s+ latency per turn
   - 20 turns caused 6.7GB RSS in 2 minutes with 3 concurrent keepers
   - 3 turns left keepers unable to do meaningful work (board_post x3 only)
   - 10 turns was insufficient for multi-step tasks (PR creation, web search)
   - 50 turns balances completion rate vs resource usage *)

(** Force module initialization to guarantee all runtime params are registered
    before [Runtime_params.restore]. Call from server bootstrap. *)
let ensure_runtime_params_init () =
  ignore (Runtime_params.get keeper_unified_temperature_rp)

let keeper_llama_slots_rp =
  _rp_int ~key:"keeper.turn.llama_slots"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_LLAMA_SLOTS"
                          ~default:4 ~min_v:0 ~max_v:32)
    ~min_v:0 ~max_v:32
    ~description:"llama-server KV cache slots for keeper pinning (0=disabled)" ()
let keeper_llama_slots () : int =
  Runtime_params.get keeper_llama_slots_rp

(** Compute a deterministic slot_id for a keeper name.
    Returns [None] when slot pinning is disabled (num_slots = 0). *)
let keeper_slot_id (name : string) : int option =
  let num_slots = keeper_llama_slots () in
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
