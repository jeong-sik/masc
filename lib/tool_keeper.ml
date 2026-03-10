(** Tool_keeper — MCP-native persistent "keeper" agents.

    Goal: Make long-lived assistants easy to use via MCP without external scripts.

    Design:
    - Event-driven: no autonomous tight loop (avoids burning tokens when idle).
    - Persistent context: stored under .masc/perpetual/<trace_id>/ via Context_manager checkpoints.
    - Automatic succession: when context_ratio crosses threshold, hydrate a successor context
      using Succession DNA and rotate trace_id.
    - Optional presence keepalive: periodically touch Room.heartbeat for the keeper's agent name.

    Tools:
    - masc_keeper_up: create/update keeper + start keepalive
    - masc_keeper_status: inspect keeper meta + current context stats
    - masc_keeper_msg: append message, run one LLM turn, persist, auto-handoff if needed
    - masc_keeper_down: stop keepalive + optionally remove meta/session dirs
    - masc_keeper_list: list all keepers
*)

open Types
open Tool_args

let keeper_debug =
  try Sys.getenv "MASC_KEEPER_DEBUG" = "1" with Not_found -> false

type 'a context = {
  config: Room.config;
  sw: Eio.Switch.t;
  clock: 'a Eio.Time.clock;
}

type tool_result = bool * string

let schemas = Keeper_schema.schemas

(* Configuration: see Keeper_config *)
include Keeper_config

let short_preview ?(max_len = 220) (s : string) : string =
  let s = String.trim s in
  if String.length s <= max_len then s
  else utf8_safe_prefix_bytes s ~max_bytes:max_len ^ "..."

let normalize_similarity_text (s : string) : string =
  let len = String.length s in
  let buf = Bytes.create len in
  for i = 0 to len - 1 do
    let c = Char.lowercase_ascii s.[i] in
    let keep =
      (c >= 'a' && c <= 'z')
      || (c >= '0' && c <= '9')
      || c = ' '
    in
    Bytes.set buf i (if keep then c else ' ')
  done;
  Bytes.to_string buf

let similarity_tokens (s : string) : string list =
  s
  |> normalize_similarity_text
  |> Str.split (Str.regexp "[ \t\r\n]+")
  |> List.filter (fun t -> String.length t >= 2)

let jaccard_similarity (a : string list) (b : string list) : float =
  let to_set xs =
    List.fold_left (fun acc x ->
      if List.mem x acc then acc else x :: acc
    ) [] xs
  in
  let sa = to_set a in
  let sb = to_set b in
  if sa = [] && sb = [] then 1.0
  else
    let inter =
      List.fold_left (fun n x -> if List.mem x sb then n + 1 else n) 0 sa
    in
    let union = List.length sa + List.length sb - inter in
    if union <= 0 then 0.0 else float_of_int inter /. float_of_int union

let proactive_similarity_score ~(candidate : string) ~(previous : string) : float =
  let a = similarity_tokens candidate in
  let b = similarity_tokens previous in
  jaccard_similarity a b

let soul_profile_policy profile =
  match profile with
  | "safety" ->
      "SOUL profile: safety-first.\n\
       Preserve first: user safety boundaries, explicit consent constraints, unresolved risks, and trust continuity.\n\
       Keep policy/guardrail decisions before optimization details."
  | "delivery" ->
      "SOUL profile: delivery.\n\
       Preserve first: concrete goal progress, accepted decisions, blockers, and next executable steps.\n\
       Keep implementation tradeoffs and done/not-done boundaries."
  | "research" ->
      "SOUL profile: research.\n\
       Preserve first: hypotheses, evidence, source-backed findings, and confidence/uncertainty.\n\
       Keep why conclusions changed, not just final statements."
  | "relationship" ->
      "SOUL profile: relationship.\n\
       Preserve first: user preferences, tone cues, collaboration style, and long-lived context about expectations.\n\
       Keep agreements and communication constraints."
  | "minimal" ->
      "SOUL profile: minimal.\n\
       Preserve only high-signal continuity: current goal, single most important decision, top blocker, and next action.\n\
       Aggressively drop low-value historical detail."
  | _ ->
      "SOUL profile: balanced.\n\
       Preserve in this order: safety/trust continuity, goal progress & decisions, unresolved risks, tool outcomes, style preferences."

let proactive_seed_for_soul_profile (profile : string) : string =
  match canonical_soul_profile profile |> Option.value ~default:default_soul_profile with
  | "safety" ->
      "Safety hint: prioritize current risk signals and mitigations."
  | "delivery" ->
      "Delivery hint: prioritize concrete next actions and execution momentum."
  | "research" ->
      "Research hint: prioritize hypotheses, evidence, and validation steps."
  | "relationship" ->
      "Relationship hint: prioritize user intent alignment and collaboration continuity."
  | "minimal" ->
      "Minimal hint: keep only high-signal continuity and next move."
  | _ ->
      "Balanced hint: keep a practical mix of risk, progress, and next step."

let take n xs =
  let rec go i acc = function
    | [] -> List.rev acc
    | _ when i <= 0 -> List.rev acc
    | x :: rest -> go (i - 1) (x :: acc) rest
  in
  go n [] xs

let mkdir_p path =
  let rec go p =
    if p = "" || p = "/" then ()
    else if Sys.file_exists p then ()
    else begin
      go (Filename.dirname p);
      (try Unix.mkdir p 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
    end
  in
  go path

let keeper_dir (config : Room.config) =
  (* Keepers are global — never scoped to cluster/room.
     Use base_path directly, consistent with perpetual_loop.ml. *)
  let d = Filename.concat (Filename.concat config.base_path ".masc") "perpetual-keepers" in
  mkdir_p d;
  d

let keeper_meta_path config name =
  Filename.concat (keeper_dir config) (name ^ ".json")

let session_base_dir (config : Room.config) =
  (* Cluster-independent, consistent with Perpetual_loop.default_config. *)
  Filename.concat (Filename.concat config.base_path ".masc") "perpetual"

let keeper_agent_name name =
  (* Make it look like a generated nickname so Room.join uses it as-is. *)
  Printf.sprintf "keeper-%s-agent" name

type keeper_meta = {
  name: string;
  agent_name: string;
  trace_id: string;
  trace_history: string list;
  goal: string;
  short_goal: string;
  mid_goal: string;
  long_goal: string;
  soul_profile: string;
  will: string;
  needs: string;
  desires: string;
  instructions: string;
  models: string list;
  generation: int;
  verify: bool;
  presence_keepalive: bool;
  presence_keepalive_sec: int;
  proactive_enabled: bool;
  proactive_idle_sec: int;
  proactive_cooldown_sec: int;
  drift_enabled: bool;
  drift_min_turn_gap: int;
  drift_count_total: int;
  last_drift_turn: int;
  last_drift_reason: string;
  compaction_profile: string;
  compaction_ratio_gate: float;
  compaction_message_gate: int;
  compaction_token_gate: int;
  continuity_compaction_cooldown_sec: int;
  auto_handoff: bool;
  handoff_threshold: float;
  handoff_cooldown_sec: int;
  context_budget: float;
  last_handoff_ts: float;
  created_at: string;
  updated_at: string;
  total_turns: int;
  total_input_tokens: int;
  total_output_tokens: int;
  total_tokens: int;
  total_cost_usd: float;
  last_turn_ts: float;
  last_model_used: string;
  last_input_tokens: int;
  last_output_tokens: int;
  last_total_tokens: int;
  last_latency_ms: int;
  compaction_count: int;
  last_compaction_ts: float;
  last_compaction_before_tokens: int;
  last_compaction_after_tokens: int;
  proactive_count_total: int;
  last_proactive_ts: float;
  last_proactive_reason: string;
  last_proactive_preview: string;
  last_compaction_check_ts: float;
  last_compaction_decision: string;
  last_continuity_update_ts: float;
  continuity_summary: string;
  (* Autonomy fields (Phase 2: Keeper Autonomy Engine) *)
  autonomy_level: string;  (** L1_Reactive..L5_Independent, stored as string for JSON compat *)
  active_goal_ids: string list;  (** goal_store goal IDs this keeper pursues *)
  last_autonomous_action_at: string;  (** ISO timestamp of last autonomous action *)
  autonomous_action_count: int;  (** total autonomous actions taken *)
}

let now_iso () = Types.now_iso ()

let meta_to_json (m : keeper_meta) : Yojson.Safe.t =
  `Assoc [
    ("name", `String m.name);
    ("agent_name", `String m.agent_name);
    ("trace_id", `String m.trace_id);
    ("trace_history", `List (List.map (fun s -> `String s) m.trace_history));
    ("goal", `String m.goal);
    ("short_goal", `String m.short_goal);
    ("mid_goal", `String m.mid_goal);
    ("long_goal", `String m.long_goal);
    ("soul_profile", `String m.soul_profile);
    ("will", `String m.will);
    ("needs", `String m.needs);
    ("desires", `String m.desires);
    ("instructions", `String m.instructions);
    ("models", `List (List.map (fun s -> `String s) m.models));
    ("generation", `Int m.generation);
    ("verify", `Bool m.verify);
    ("presence_keepalive", `Bool m.presence_keepalive);
    ("presence_keepalive_sec", `Int m.presence_keepalive_sec);
    ("proactive_enabled", `Bool m.proactive_enabled);
    ("proactive_idle_sec", `Int m.proactive_idle_sec);
    ("proactive_cooldown_sec", `Int m.proactive_cooldown_sec);
    ("drift_enabled", `Bool m.drift_enabled);
    ("drift_min_turn_gap", `Int m.drift_min_turn_gap);
    ("drift_count_total", `Int m.drift_count_total);
    ("last_drift_turn", `Int m.last_drift_turn);
    ("last_drift_reason", `String m.last_drift_reason);
    ("compaction_profile", `String m.compaction_profile);
    ("compaction_ratio_gate", `Float m.compaction_ratio_gate);
    ("compaction_message_gate", `Int m.compaction_message_gate);
    ("compaction_token_gate", `Int m.compaction_token_gate);
    ("continuity_compaction_cooldown_sec", `Int m.continuity_compaction_cooldown_sec);
    ("auto_handoff", `Bool m.auto_handoff);
    ("handoff_threshold", `Float m.handoff_threshold);
    ("handoff_cooldown_sec", `Int m.handoff_cooldown_sec);
    ("context_budget", `Float m.context_budget);
    ("last_handoff_ts", `Float m.last_handoff_ts);
    ("created_at", `String m.created_at);
    ("updated_at", `String m.updated_at);
    ("total_turns", `Int m.total_turns);
    ("total_input_tokens", `Int m.total_input_tokens);
    ("total_output_tokens", `Int m.total_output_tokens);
    ("total_tokens", `Int m.total_tokens);
    ("total_cost_usd", `Float m.total_cost_usd);
    ("last_turn_ts", `Float m.last_turn_ts);
    ("last_model_used", `String m.last_model_used);
    ("last_input_tokens", `Int m.last_input_tokens);
    ("last_output_tokens", `Int m.last_output_tokens);
    ("last_total_tokens", `Int m.last_total_tokens);
    ("last_latency_ms", `Int m.last_latency_ms);
    ("compaction_count", `Int m.compaction_count);
    ("last_compaction_ts", `Float m.last_compaction_ts);
    ("last_compaction_before_tokens", `Int m.last_compaction_before_tokens);
    ("last_compaction_after_tokens", `Int m.last_compaction_after_tokens);
    ("proactive_count_total", `Int m.proactive_count_total);
    ("last_proactive_ts", `Float m.last_proactive_ts);
    ("last_proactive_reason", `String m.last_proactive_reason);
    ("last_proactive_preview", `String m.last_proactive_preview);
    ("last_compaction_check_ts", `Float m.last_compaction_check_ts);
    ("last_compaction_decision", `String m.last_compaction_decision);
    ("last_continuity_update_ts", `Float m.last_continuity_update_ts);
    ("continuity_summary", `String m.continuity_summary);
    ("autonomy_level", `String m.autonomy_level);
    ("active_goal_ids", `List (List.map (fun s -> `String s) m.active_goal_ids));
    ("last_autonomous_action_at", `String m.last_autonomous_action_at);
    ("autonomous_action_count", `Int m.autonomous_action_count);
  ]

let meta_of_json (json : Yojson.Safe.t) : (keeper_meta, string) result =
  try
    let name = Safe_ops.json_string ~default:"" "name" json in
    let agent_name = Safe_ops.json_string ~default:"" "agent_name" json in
    let trace_id = Safe_ops.json_string ~default:"" "trace_id" json in
    let trace_history =
      Safe_ops.json_string_list "trace_history" json |> List.filter validate_name
    in
    let goal =
      Safe_ops.json_string ~default:"" "goal" json
      |> normalize_goal_horizon_text
    in
    let (short_goal, mid_goal, long_goal) =
      resolve_goal_horizons
        ~goal
        ~short_goal_opt:(normalize_goal_horizon_opt (Safe_ops.json_string_opt "short_goal" json))
        ~mid_goal_opt:(normalize_goal_horizon_opt (Safe_ops.json_string_opt "mid_goal" json))
        ~long_goal_opt:(normalize_goal_horizon_opt (Safe_ops.json_string_opt "long_goal" json))
    in
    let soul_profile =
      Safe_ops.json_string ~default:default_soul_profile "soul_profile" json
      |> canonical_soul_profile
      |> Option.value ~default:default_soul_profile
    in
    let will =
      Safe_ops.json_string ~default:default_keeper_will "will" json
      |> normalize_self_model_text
    in
    let needs =
      Safe_ops.json_string ~default:default_keeper_needs "needs" json
      |> normalize_self_model_text
    in
    let desires =
      Safe_ops.json_string ~default:default_keeper_desires "desires" json
      |> normalize_self_model_text
    in
    let instructions = Safe_ops.json_string ~default:"" "instructions" json in
    let models = Safe_ops.json_string_list "models" json in
    let generation = Safe_ops.json_int ~default:0 "generation" json in
    let verify = Safe_ops.json_bool ~default:false "verify" json in
    let presence_keepalive = Safe_ops.json_bool ~default:true "presence_keepalive" json in
    let presence_keepalive_sec = Safe_ops.json_int ~default:30 "presence_keepalive_sec" json in
    let proactive_enabled =
      Safe_ops.json_bool ~default:default_proactive_enabled "proactive_enabled" json
    in
    let proactive_idle_sec =
      Safe_ops.json_int ~default:default_proactive_idle_sec "proactive_idle_sec" json
      |> normalize_proactive_idle_sec
    in
    let proactive_cooldown_sec =
      Safe_ops.json_int ~default:default_proactive_cooldown_sec "proactive_cooldown_sec" json
      |> normalize_proactive_cooldown_sec
    in
    let drift_enabled =
      Safe_ops.json_bool ~default:default_drift_enabled "drift_enabled" json
    in
    let drift_min_turn_gap =
      Safe_ops.json_int ~default:default_drift_min_turn_gap "drift_min_turn_gap" json
      |> normalize_drift_min_turn_gap
    in
    let drift_count_total = Safe_ops.json_int ~default:0 "drift_count_total" json in
    let last_drift_turn = Safe_ops.json_int ~default:0 "last_drift_turn" json in
    let last_drift_reason = Safe_ops.json_string ~default:"" "last_drift_reason" json in
    let (env_ratio_gate, env_message_gate, env_token_gate) =
      keeper_compaction_policy_from_env ()
    in
    let compaction_profile =
      Safe_ops.json_string ~default:default_compaction_profile "compaction_profile" json
      |> canonical_compaction_profile
      |> Option.value ~default:default_compaction_profile
    in
    let compaction_ratio_gate =
      Safe_ops.json_float ~default:env_ratio_gate "compaction_ratio_gate" json
      |> normalize_compaction_ratio_gate
    in
    let compaction_message_gate =
      Safe_ops.json_int ~default:env_message_gate "compaction_message_gate" json
      |> normalize_compaction_message_gate
    in
    let compaction_token_gate =
      Safe_ops.json_int ~default:env_token_gate "compaction_token_gate" json
      |> normalize_compaction_token_gate
    in
    let continuity_compaction_cooldown_sec =
      Safe_ops.json_int
        ~default:(keeper_continuity_compaction_cooldown_sec ())
        "continuity_compaction_cooldown_sec" json
      |> normalize_continuity_compaction_cooldown_sec
    in
    let auto_handoff = Safe_ops.json_bool ~default:true "auto_handoff" json in
    let handoff_threshold = Safe_ops.json_float ~default:0.85 "handoff_threshold" json in
    let handoff_cooldown_sec = Safe_ops.json_int ~default:300 "handoff_cooldown_sec" json in
    let context_budget = Safe_ops.json_float ~default:0.6 "context_budget" json in
    let last_handoff_ts = Safe_ops.json_float ~default:0.0 "last_handoff_ts" json in
    let created_at = Safe_ops.json_string ~default:"" "created_at" json in
    let updated_at = Safe_ops.json_string ~default:"" "updated_at" json in
    let total_turns = Safe_ops.json_int ~default:0 "total_turns" json in
    let total_input_tokens = Safe_ops.json_int ~default:0 "total_input_tokens" json in
    let total_output_tokens = Safe_ops.json_int ~default:0 "total_output_tokens" json in
    let total_tokens = Safe_ops.json_int ~default:0 "total_tokens" json in
    let total_cost_usd = Safe_ops.json_float ~default:0.0 "total_cost_usd" json in
    let last_turn_ts = Safe_ops.json_float ~default:0.0 "last_turn_ts" json in
    let last_model_used = Safe_ops.json_string ~default:"" "last_model_used" json in
    let last_input_tokens = Safe_ops.json_int ~default:0 "last_input_tokens" json in
    let last_output_tokens = Safe_ops.json_int ~default:0 "last_output_tokens" json in
    let last_total_tokens = Safe_ops.json_int ~default:0 "last_total_tokens" json in
    let last_latency_ms = Safe_ops.json_int ~default:0 "last_latency_ms" json in
    let compaction_count = Safe_ops.json_int ~default:0 "compaction_count" json in
    let last_compaction_ts = Safe_ops.json_float ~default:0.0 "last_compaction_ts" json in
    let last_compaction_before_tokens = Safe_ops.json_int ~default:0 "last_compaction_before_tokens" json in
    let last_compaction_after_tokens = Safe_ops.json_int ~default:0 "last_compaction_after_tokens" json in
    let proactive_count_total = Safe_ops.json_int ~default:0 "proactive_count_total" json in
    let last_proactive_ts = Safe_ops.json_float ~default:0.0 "last_proactive_ts" json in
    let last_proactive_reason = Safe_ops.json_string ~default:"" "last_proactive_reason" json in
    let last_proactive_preview = Safe_ops.json_string ~default:"" "last_proactive_preview" json in
    let last_compaction_check_ts = Safe_ops.json_float ~default:0.0 "last_compaction_check_ts" json in
    let last_compaction_decision =
      Safe_ops.json_string ~default:"uninitialized" "last_compaction_decision" json
    in
    let continuity_summary = Safe_ops.json_string ~default:"" "continuity_summary" json in
    let last_continuity_update_ts =
      let parsed_ts = Safe_ops.json_float ~default:0.0 "last_continuity_update_ts" json in
      if parsed_ts <= 0.0 && String.trim continuity_summary <> "" then
        Time_compat.now ()
      else
        parsed_ts
    in
    let autonomy_level = Safe_ops.json_string ~default:"l1_reactive" "autonomy_level" json in
    let active_goal_ids = Safe_ops.json_string_list "active_goal_ids" json in
    let last_autonomous_action_at = Safe_ops.json_string ~default:"" "last_autonomous_action_at" json in
    let autonomous_action_count = Safe_ops.json_int ~default:0 "autonomous_action_count" json in
    if not (validate_name name) then
      Error "invalid keeper meta (bad name)"
    else if not (validate_name trace_id) then
      Error "invalid keeper meta (bad trace_id)"
    else
      Ok {
        name;
        agent_name = if agent_name = "" then keeper_agent_name name else agent_name;
        trace_id;
        trace_history;
        goal;
        short_goal;
        mid_goal;
        long_goal;
        soul_profile;
        will;
        needs;
        desires;
        instructions;
        models;
        generation;
        verify;
        presence_keepalive;
        presence_keepalive_sec;
        proactive_enabled;
        proactive_idle_sec;
        proactive_cooldown_sec;
        drift_enabled;
        drift_min_turn_gap;
        drift_count_total;
        last_drift_turn;
        last_drift_reason;
        compaction_profile;
        compaction_ratio_gate;
        compaction_message_gate;
        compaction_token_gate;
        continuity_compaction_cooldown_sec;
        auto_handoff;
        handoff_threshold;
        handoff_cooldown_sec;
        context_budget;
        last_handoff_ts;
        created_at = if created_at = "" then now_iso () else created_at;
        updated_at = if updated_at = "" then now_iso () else updated_at;
        total_turns;
        total_input_tokens;
        total_output_tokens;
        total_tokens;
        total_cost_usd;
        last_turn_ts;
        last_model_used;
        last_input_tokens;
        last_output_tokens;
        last_total_tokens;
        last_latency_ms;
        compaction_count;
        last_compaction_ts;
        last_compaction_before_tokens;
        last_compaction_after_tokens;
        proactive_count_total;
        last_proactive_ts;
        last_proactive_reason;
        last_proactive_preview;
        last_compaction_check_ts;
        last_compaction_decision;
        last_continuity_update_ts;
        continuity_summary;
        autonomy_level;
        active_goal_ids;
        last_autonomous_action_at;
        autonomous_action_count;
      }
  with exn ->
    Error (Printf.sprintf "meta parse error: %s" (Printexc.to_string exn))

let write_meta config (m : keeper_meta) : (unit, string) result =
  let path = keeper_meta_path config m.name in
  let content = Yojson.Safe.pretty_to_string (meta_to_json m) in
  try
    let oc = open_out path in
    Common.protect ~module_name:"tool_keeper" ~finally_label:"close_out"
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_string oc content);
    Ok ()
  with exn ->
    Error (Printf.sprintf "failed to write meta %s: %s" path (Printexc.to_string exn))

let read_meta config name : (keeper_meta option, string) result =
  let path = keeper_meta_path config name in
  if keeper_debug then
    Printf.eprintf "[KEEPER-DEBUG] read_meta name=%s path=%s exists=%b\n%!" name path (Sys.file_exists path);
  if not (Sys.file_exists path) then Ok None
  else
    match Safe_ops.read_json_file_safe path with
    | Error e -> Error e
    | Ok json ->
      (match meta_of_json json with
       | Ok m -> Ok (Some m)
       | Error e -> Error e)

let model_specs_of_strings (model_strs : string list) : (Llm_client.model_spec list, string) result =
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | s :: rest ->
      (match Llm_client.model_spec_of_string s with
       | Ok spec -> go (spec :: acc) rest
       | Error e -> Error (Printf.sprintf "Bad model spec %s: %s" s e))
  in
  go [] model_strs

let env_present name =
  match Sys.getenv_opt name with
  | Some value -> String.trim value <> ""
  | None -> false

let ollama_port_listening () =
  try
    let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Fun.protect
      ~finally:(fun () -> (try Unix.close sock with Unix.Unix_error _ -> ()))
      (fun () ->
        Unix.connect sock (Unix.ADDR_INET (Unix.inet_addr_loopback, 11434));
        true)
  with Unix.Unix_error _ -> false

let model_spec_is_local_runtime (model : Llm_client.model_spec) =
  match model.provider with
  | Llm_client.Ollama | Llm_client.Llama -> true
  | _ -> false

let model_spec_is_available (model : Llm_client.model_spec) =
  match model.provider with
  | Llm_client.Ollama -> ollama_port_listening ()
  | Llm_client.Llama -> true
  | _ -> true

let keeper_fallback_model_labels () =
  let gemini_available =
    match Provider_adapter.resolve_gemini_direct_auth () with
    | Provider_adapter.Gemini_api_key
    | Provider_adapter.Gemini_vertex_adc _ -> true
    | Provider_adapter.Gemini_auth_missing _ -> false
  in
  let candidates =
    [
      (env_present "ZAI_API_KEY", "glm:glm-4.7");
      (gemini_available, "gemini:gemini-2.5-pro");
      (env_present "ANTHROPIC_API_KEY", "claude:claude-sonnet-4-5-20250929");
    ]
  in
  candidates
  |> List.filter_map (fun (enabled, label) -> if enabled then Some label else None)

let maybe_append_keeper_fallback_models (models : string list) =
  match model_specs_of_strings models with
  | Error _ -> models
  | Ok specs ->
      let all_local = specs <> [] && List.for_all model_spec_is_local_runtime specs in
      let any_available = List.exists model_spec_is_available specs in
      if (not all_local) || any_available then
        models
      else
        let extra =
          keeper_fallback_model_labels ()
          |> List.filter (fun label -> not (List.mem label models))
        in
        if extra = [] then models else models @ extra

let ensure_api_keys (models : Llm_client.model_spec list) : (unit, string) result =
  let missing =
    List.filter_map (fun (m : Llm_client.model_spec) ->
      match m.api_key_env with
      | None -> None
      | Some env ->
        let v = Sys.getenv_opt env |> Option.value ~default:"" in
        if v = "" then Some env else None
    ) models
  in
  match missing with
  | [] -> Ok ()
  | xs -> Error (Printf.sprintf "Missing API key env vars: %s" (String.concat ", " xs))

let keeper_metrics_path config name =
  Filename.concat (keeper_dir config) (name ^ ".metrics.jsonl")

let keeper_memory_bank_path config name =
  Filename.concat (keeper_dir config) (name ^ ".memory.jsonl")

let keeper_session_dir config trace_id =
  Filename.concat (session_base_dir config) trace_id

let keeper_history_path config trace_id =
  Filename.concat (keeper_session_dir config trace_id) "history.jsonl"

let keeper_alerts_path config =
  Filename.concat (keeper_dir config) "_alerts.jsonl"

let keeper_alert_retry_path config =
  Filename.concat (keeper_dir config) "_alerts.retry.jsonl"

let keeper_alert_deadletter_path config =
  Filename.concat (keeper_dir config) "_alerts.deadletter.jsonl"

let append_jsonl_line path (json : Yojson.Safe.t) =
  let line = utf8_repair_string (Yojson.Safe.to_string json) ^ "\n" in
  let fd = Unix.openfile path
    [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND] 0o644 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
    let _ = Unix.write_substring fd line 0 (String.length line) in
    ())

type alert_channel_result = {
  channel: string;
  attempted: bool;
  success: bool;
  attempts: int;
  detail: string option;
}

type interesting_alert_result = {
  enabled: bool;
  triggered: bool;
  score: float;
  threshold: float;
  reasons: string list;
  keywords: string list;
  alert_id: string option;
  channels: alert_channel_result list;
  retry_queued: bool;
  deadlettered: bool;
}

let empty_interesting_alert_result = {
  enabled = false;
  triggered = false;
  score = 0.0;
  threshold = 0.0;
  reasons = [];
  keywords = [];
  alert_id = None;
  channels = [];
  retry_queued = false;
  deadlettered = false;
}

let alert_channel_result_to_json (r : alert_channel_result) : Yojson.Safe.t =
  `Assoc [
    ("channel", `String r.channel);
    ("attempted", `Bool r.attempted);
    ("success", `Bool r.success);
    ("attempts", `Int r.attempts);
    ("detail",
      match r.detail with
      | Some d when String.trim d <> "" -> `String d
      | _ -> `Null);
  ]

let interesting_alert_result_to_json (r : interesting_alert_result) : Yojson.Safe.t =
  `Assoc [
    ("enabled", `Bool r.enabled);
    ("triggered", `Bool r.triggered);
    ("score", `Float r.score);
    ("threshold", `Float r.threshold);
    ("reasons", `List (List.map (fun s -> `String s) r.reasons));
    ("keywords", `List (List.map (fun s -> `String s) r.keywords));
    ("alert_id",
      match r.alert_id with
      | Some id when String.trim id <> "" -> `String id
      | _ -> `Null);
    ("channels", `List (List.map alert_channel_result_to_json r.channels));
    ("retry_queued", `Bool r.retry_queued);
    ("deadlettered", `Bool r.deadlettered);
  ]

type keeper_state_snapshot = {
  goal: string option;
  progress: string option;
  next_items: string list;
  decisions: string list;
  open_questions: string list;
  constraints: string list;
}

let empty_keeper_state_snapshot = {
  goal = None;
  progress = None;
  next_items = [];
  decisions = [];
  open_questions = [];
  constraints = [];
}

type keeper_memory_line = {
  kind: string;
  text: string;
  priority: int;
  ts_unix: float;
}

type keeper_memory_summary = {
  total_notes: int;
  last_ts_unix: float;
  top_kind: string option;
  kind_counts: (string * int) list;
  recent_notes: keeper_memory_line list;
}

type memory_bank_compaction = {
  performed: bool;
  reason: string option;
  target_notes: int;
  before_notes: int;
  after_notes: int;
  dropped_notes: int;
  dedup_dropped: int;
  invalid_dropped: int;
}

let no_memory_bank_compaction = {
  performed = false;
  reason = None;
  target_notes = 0;
  before_notes = 0;
  after_notes = 0;
  dropped_notes = 0;
  dedup_dropped = 0;
  invalid_dropped = 0;
}

let trim_nonempty (s : string) : string option =
  let t = String.trim s in
  if t = "" then None else Some t

let split_state_items (s : string) : string list =
  s
  |> String.split_on_char ';'
  |> List.map String.trim
  |> List.filter (fun x -> x <> "")
  |> take 6

let strip_prefix_ci ~(prefix : string) (s : string) : string option =
  let s = String.trim s in
  let plen = String.length prefix in
  if String.length s < plen then None
  else
    let head = String.sub s 0 plen |> String.lowercase_ascii in
    if head = String.lowercase_ascii prefix then
      Some (String.sub s plen (String.length s - plen) |> String.trim)
    else
      None

let find_state_block (reply : string) : string option =
  try
    let start_idx = Str.search_forward (Str.regexp_string "[STATE]") reply 0 in
    let body_start = start_idx + String.length "[STATE]" in
    let end_idx =
      Str.search_forward (Str.regexp_string "[/STATE]") reply body_start
    in
    if end_idx <= body_start then None
    else Some (String.sub reply body_start (end_idx - body_start))
  with Not_found ->
    None

let parse_state_snapshot_from_reply (reply : string) : keeper_state_snapshot option =
  match find_state_block reply with
  | None -> None
  | Some body ->
      let lines =
        body
        |> String.split_on_char '\n'
        |> List.map String.trim
        |> List.filter (fun line -> line <> "")
      in
      let snapshot =
        List.fold_left
          (fun acc line ->
            match strip_prefix_ci ~prefix:"Goal:" line with
            | Some v -> { acc with goal = trim_nonempty v }
            | None ->
                (match strip_prefix_ci ~prefix:"Progress:" line with
                | Some v -> { acc with progress = trim_nonempty v }
                | None ->
                    (match strip_prefix_ci ~prefix:"Next:" line with
                    | Some v -> { acc with next_items = split_state_items v }
                    | None ->
                        (match strip_prefix_ci ~prefix:"Decisions:" line with
                        | Some v -> { acc with decisions = split_state_items v }
                        | None ->
                            (match strip_prefix_ci ~prefix:"OpenQuestions:" line with
                            | Some v ->
                                { acc with open_questions = split_state_items v }
                            | None ->
                                (match strip_prefix_ci
                                         ~prefix:"Constraints:" line
                                 with
                                | Some v ->
                                    { acc with constraints = split_state_items v }
                                | None -> acc))))))
          empty_keeper_state_snapshot lines
      in
      if snapshot.goal = None
         && snapshot.progress = None
         && snapshot.next_items = []
         && snapshot.decisions = []
         && snapshot.open_questions = []
         && snapshot.constraints = []
      then
        None
      else
        Some snapshot

let keeper_state_snapshot_to_summary_text (snapshot : keeper_state_snapshot) : string =
  let maybe_line match_fn label =
    match match_fn () with
    | None -> None
    | Some value -> Some (Printf.sprintf "%s: %s" label value)
  in
  let lines =
    [
      maybe_line
        (fun () ->
           match snapshot.goal with
           | Some v when String.trim v <> "" -> Some (String.trim v)
           | _ -> None)
        "Goal";
      maybe_line
        (fun () ->
           match snapshot.progress with
           | Some v when String.trim v <> "" -> Some (String.trim v)
           | _ -> None)
        "Progress";
      maybe_line
        (fun () ->
           match snapshot.next_items with
           | [] -> None
           | items -> Some (String.concat "; " (take 3 (List.map String.trim items))))
        "Next";
      maybe_line
        (fun () ->
           match snapshot.decisions with
           | [] -> None
           | items -> Some (String.concat "; " (take 3 (List.map String.trim items))))
        "Decisions";
      maybe_line
        (fun () ->
           match snapshot.open_questions with
           | [] -> None
           | items -> Some (String.concat "; " (take 3 (List.map String.trim items))))
        "OpenQuestions";
      maybe_line
        (fun () ->
           match snapshot.constraints with
           | [] -> None
           | items -> Some (String.concat "; " (take 3 (List.map String.trim items))))
        "Constraints";
    ]
    |> List.filter_map (fun x -> x)
  in
  if lines = [] then "No continuity snapshot available." else String.concat "\n" lines

let keeper_state_snapshot_to_json (snapshot : keeper_state_snapshot) : Yojson.Safe.t =
  `Assoc [
    ("goal", match snapshot.goal with Some s -> `String s | None -> `Null);
    ("progress", match snapshot.progress with Some s -> `String s | None -> `Null);
    ("next_items", `List (List.map (fun s -> `String s) snapshot.next_items));
    ("decisions", `List (List.map (fun s -> `String s) snapshot.decisions));
    ("open_questions", `List (List.map (fun s -> `String s) snapshot.open_questions));
    ("constraints", `List (List.map (fun s -> `String s) snapshot.constraints));
  ]

let latest_state_snapshot_from_messages (messages : Llm_client.message list) :
    keeper_state_snapshot option =
  let rec loop (msgs : Llm_client.message list) =
    match msgs with
    | [] -> None
    | msg :: rest ->
      match parse_state_snapshot_from_reply msg.content with
      | None -> loop rest
      | Some snapshot -> Some snapshot
  in
  loop (List.rev messages)

let append_continuity_context_prompt
    ~(base_prompt : string)
    (snapshot : keeper_state_snapshot option)
    ~(continuity_summary : string) : string =
  let fallback_summary =
    let trimmed = String.trim continuity_summary in
    if trimmed = "" then "No continuity snapshot available." else trimmed
  in
  let summary =
    match snapshot with
    | None -> fallback_summary
    | Some s -> keeper_state_snapshot_to_summary_text s
  in
  if summary = "No continuity snapshot available." then base_prompt
  else
    Printf.sprintf
      "%s\n\nRecent continuity snapshot:\n%s"
      base_prompt
      summary

let priority_for_kind ~soul_profile ~(kind : string) : int =
  match soul_profile, kind with
  | "safety", "constraints" -> 100
  | "safety", "open_question" -> 88
  | "safety", "decision" -> 82
  | "safety", "goal" -> 76
  | "safety", "next" -> 70
  | "safety", "progress" -> 62
  | "delivery", "next" -> 100
  | "delivery", "decision" -> 90
  | "delivery", "goal" -> 80
  | "delivery", "progress" -> 74
  | "delivery", "open_question" -> 68
  | "delivery", "constraints" -> 62
  | "research", "open_question" -> 100
  | "research", "decision" -> 92
  | "research", "progress" -> 84
  | "research", "goal" -> 76
  | "research", "next" -> 70
  | "research", "constraints" -> 62
  | "relationship", "goal" -> 96
  | "relationship", "progress" -> 90
  | "relationship", "constraints" -> 84
  | "relationship", "decision" -> 78
  | "relationship", "open_question" -> 72
  | "relationship", "next" -> 66
  | "minimal", "goal" -> 100
  | "minimal", "next" -> 92
  | "minimal", "decision" -> 80
  | "minimal", "constraints" -> 74
  | "minimal", "open_question" -> 70
  | "minimal", "progress" -> 60
  | _, "constraints" -> 90
  | _, "decision" -> 86
  | _, "next" -> 80
  | _, "open_question" -> 76
  | _, "goal" -> 72
  | _, "progress" -> 66
  | _ -> 60

let contains_any_ci (text : string) (needles : string list) : bool =
  let hay = String.lowercase_ascii text in
  List.exists
    (fun needle ->
      let n = String.lowercase_ascii needle in
      n <> ""
      &&
      try
        let _ = Str.search_forward (Str.regexp_string n) hay 0 in
        true
      with Not_found -> false)
    needles

let profile_signal_bonus ~(profile : string) ~(kind : string) ~(text : string) : int =
  let safety_words = [
    "risk"; "danger"; "unsafe"; "security"; "privacy"; "consent"; "guardrail";
    "위험"; "보안"; "개인정보"; "동의"; "안전";
  ] in
  let delivery_words = [
    "blocker"; "deadline"; "ship"; "release"; "next step"; "todo"; "must";
    "막힘"; "차단"; "데드라인"; "배포"; "다음 단계"; "필수";
  ] in
  let research_words = [
    "hypothesis"; "evidence"; "experiment"; "measure"; "benchmark"; "assume";
    "가설"; "근거"; "실험"; "측정"; "벤치";
  ] in
  let relationship_words = [
    "preference"; "style"; "tone"; "boundary"; "expectation"; "trust";
    "선호"; "스타일"; "톤"; "경계"; "기대"; "신뢰";
  ] in
  let uncertainty_words = [
    "unknown"; "unclear"; "maybe"; "tbd"; "later"; "todo"; "unsure";
    "모름"; "불명"; "아마"; "추정"; "미정"; "나중";
  ] in
  let profile_bonus =
    match profile with
    | "safety" when kind = "constraints" || contains_any_ci text safety_words -> 14
    | "delivery" when kind = "next" || kind = "decision" || contains_any_ci text delivery_words ->
        12
    | "research" when kind = "open_question" || contains_any_ci text research_words -> 12
    | "relationship" when kind = "goal" || kind = "progress" || contains_any_ci text relationship_words ->
        12
    | "minimal" when kind = "goal" || kind = "next" -> 6
    | _ -> 0
  in
  let global_bonus =
    if contains_any_ci text ["must"; "required"; "필수"; "중요"; "critical"] then 4 else 0
  in
  let uncertainty_penalty =
    if contains_any_ci text uncertainty_words then -8 else 0
  in
  profile_bonus + global_bonus + uncertainty_penalty

let tuned_priority_for_candidate
    ~(soul_profile : string)
    ~(kind : string)
    ~(text : string) : int =
  let base = priority_for_kind ~soul_profile ~kind in
  let bonus = profile_signal_bonus ~profile:soul_profile ~kind ~text in
  max 1 (min 100 (base + bonus))

let profile_total_cap (profile : string) : int =
  match profile with
  | "minimal" -> 4
  | "safety" -> 10
  | "research" -> 11
  | "relationship" -> 11
  | _ -> 12

let profile_kind_caps (profile : string) : (string * int) list =
  match profile with
  | "safety" ->
      [ ("constraints", 3); ("open_question", 2); ("decision", 2); ("goal", 1); ("next", 1); ("progress", 1) ]
  | "delivery" ->
      [ ("next", 3); ("decision", 3); ("goal", 2); ("progress", 2); ("constraints", 1); ("open_question", 1) ]
  | "research" ->
      [ ("open_question", 3); ("decision", 3); ("progress", 2); ("goal", 1); ("next", 1); ("constraints", 1) ]
  | "relationship" ->
      [ ("goal", 2); ("progress", 3); ("constraints", 2); ("decision", 2); ("open_question", 1); ("next", 1) ]
  | "minimal" ->
      [ ("goal", 1); ("next", 1); ("decision", 1); ("constraints", 1); ("open_question", 0); ("progress", 0) ]
  | _ ->
      [ ("constraints", 2); ("decision", 2); ("next", 2); ("goal", 2); ("progress", 2); ("open_question", 2) ]

let cap_for_kind (caps : (string * int) list) (kind : string) : int =
  match List.assoc_opt kind caps with
  | Some v -> v
  | None -> 1

let select_memory_candidates_by_profile
    ~(profile : string)
    (rows : (string * string * int) list) : (string * string * int) list =
  let total_cap = profile_total_cap profile in
  let kind_caps = profile_kind_caps profile in
  let used_by_kind : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let rec go acc = function
    | [] -> List.rev acc
    | _ when List.length acc >= total_cap -> List.rev acc
    | (kind, text, pr) :: rest ->
        let cap = cap_for_kind kind_caps kind in
        let used = Option.value ~default:0 (Hashtbl.find_opt used_by_kind kind) in
        if cap <= 0 || used >= cap then
          go acc rest
        else begin
          Hashtbl.replace used_by_kind kind (used + 1);
          go ((kind, text, pr) :: acc) rest
        end
  in
  go [] rows

let dedup_memory_candidates
    (items : (string * string * int) list) : (string * string * int) list =
  let seen : (string, unit) Hashtbl.t = Hashtbl.create 32 in
  List.filter
    (fun (kind, text, _) ->
      let key =
        String.lowercase_ascii
          (String.trim kind ^ ":" ^ String.trim text)
      in
      if key = "" || Hashtbl.mem seen key then
        false
      else (
        Hashtbl.add seen key ();
        true))
    items

let normalize_memory_text_key (s : string) : string =
  s
  |> String.trim
  |> String.lowercase_ascii
  |> Str.global_replace (Str.regexp "[[:space:][:punct:]]+") ""

let is_meaningful_memory_text (s : string) : bool =
  let key = normalize_memory_text_key s in
  let placeholders = [
    "";
    "none";
    "null";
    "na";
    "nil";
    "없음";
    "없다";
    "없어요";
    "해당없음";
    "무";
    "미정";
  ] in
  not (List.mem key placeholders)

let memory_candidates_from_snapshot
    ~(soul_profile : string)
    (snapshot : keeper_state_snapshot) : (string * string * int) list =
  let profile =
    canonical_soul_profile soul_profile
    |> Option.value ~default:default_soul_profile
  in
  let add_opt kind value acc =
    match value with
    | None -> acc
    | Some text ->
        let text = String.trim text in
        if text = "" || not (is_meaningful_memory_text text) then acc
        else
          ( kind,
            text,
            tuned_priority_for_candidate
              ~soul_profile:profile
              ~kind
              ~text )
          :: acc
  in
  let add_list kind values acc =
    List.fold_left
      (fun acc item ->
        let item = String.trim item in
        if item = "" || not (is_meaningful_memory_text item) then acc
        else
          ( kind,
            item,
            tuned_priority_for_candidate
              ~soul_profile:profile
              ~kind
              ~text:item )
          :: acc)
      acc values
  in
  let raw =
    []
    |> add_opt "goal" snapshot.goal
    |> add_opt "progress" snapshot.progress
    |> add_list "next" snapshot.next_items
    |> add_list "decision" snapshot.decisions
    |> add_list "open_question" snapshot.open_questions
    |> add_list "constraints" snapshot.constraints
    |> dedup_memory_candidates
    |> List.sort (fun (_, ta, pa) (_, tb, pb) ->
         let c = compare pb pa in
         if c <> 0 then c else String.compare ta tb)
  in
  select_memory_candidates_by_profile ~profile raw

type keeper_memory_row_raw = {
  json: Yojson.Safe.t;
  kind: string;
  text: string;
  priority: int;
  ts_unix: float;
}

let parse_memory_bank_row (line : string) : keeper_memory_row_raw option =
  try
    let j = Yojson.Safe.from_string line in
    let kind = Safe_ops.json_string ~default:"" "kind" j |> String.trim in
    let text = Safe_ops.json_string ~default:"" "text" j |> String.trim in
    let priority = Safe_ops.json_int ~default:0 "priority" j in
    let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" j in
    if kind = "" || text = "" || not (is_meaningful_memory_text text) then
      None
    else
      Some { json = j; kind; text; priority; ts_unix }
  with Yojson.Json_error _ ->
    None

let memory_compaction_target_notes ~(profile : string) : int =
  let default_target =
    match profile with
    | "minimal" -> 80
    | "safety" -> 180
    | "delivery" -> 220
    | "research" -> 260
    | "relationship" -> 240
    | _ -> 220
  in
  let raw =
    Safe_ops.get_env_int_logged
      "MASC_KEEPER_MEMORY_MAX_NOTES"
      ~default:default_target
  in
  max 40 (min 4000 raw)

let memory_compaction_trigger_bytes ~(target_notes : int) : int =
  let default_trigger = max 120000 (target_notes * 360) in
  let raw =
    Safe_ops.get_env_int_logged
      "MASC_KEEPER_MEMORY_COMPACT_TRIGGER_BYTES"
      ~default:default_trigger
  in
  max 60000 (min 20000000 raw)

let memory_kind_caps_for_compaction
    ~(profile : string)
    ~(target_notes : int) : (string, int) Hashtbl.t =
  let tbl : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let base_total = max 1 (profile_total_cap profile) in
  let scale = max 6 (target_notes / base_total) in
  List.iter
    (fun (kind, base_cap) ->
      let cap = max 8 ((base_cap * scale) + (scale / 3)) in
      Hashtbl.replace tbl kind cap)
    (profile_kind_caps profile);
  tbl

let memory_row_key (row : keeper_memory_row_raw) : string =
  String.lowercase_ascii (String.trim row.kind)
  ^ ":"
  ^ normalize_memory_text_key row.text

let write_memory_bank_rows
    (path : string)
    (rows : keeper_memory_row_raw list) : (unit, string) result =
  let tmp = path ^ ".tmp" in
  try
    let oc = open_out tmp in
    Common.protect
      ~module_name:"tool_keeper"
      ~finally_label:"close_out"
      ~finally:(fun () -> close_out_noerr oc)
      (fun () ->
        List.iter
          (fun (row : keeper_memory_row_raw) ->
            output_string oc (utf8_repair_string (Yojson.Safe.to_string row.json));
            output_char oc '\n')
          rows);
    Sys.rename tmp path;
    Ok ()
  with exn ->
    Safe_ops.remove_file_logged ~context:"memory_compaction" tmp;
    Error (Printf.sprintf "failed to rewrite memory bank: %s" (Printexc.to_string exn))

let compact_memory_bank_if_needed
    (config : Room.config)
    (meta : keeper_meta) : memory_bank_compaction =
  let profile =
    canonical_soul_profile meta.soul_profile
    |> Option.value ~default:default_soul_profile
  in
  let target_notes = memory_compaction_target_notes ~profile in
  let path = keeper_memory_bank_path config meta.name in
  if not (Sys.file_exists path) then
    { no_memory_bank_compaction with
      target_notes;
      reason = Some "missing_file";
    }
  else
    let size_bytes =
      try (Unix.stat path).st_size
      with Unix.Unix_error _ -> 0
    in
    let trigger_bytes = memory_compaction_trigger_bytes ~target_notes in
    if size_bytes < trigger_bytes then
      { no_memory_bank_compaction with
        target_notes;
        reason = Some "under_trigger_bytes";
      }
    else
      match Safe_ops.read_file_safe path with
      | Error _ ->
          { no_memory_bank_compaction with
            target_notes;
            reason = Some "read_failed";
          }
      | Ok content ->
          let lines =
            content
            |> String.split_on_char '\n'
            |> List.filter (fun s -> String.trim s <> "")
          in
          let parsed_rev = ref [] in
          let invalid = ref 0 in
          List.iter
            (fun line ->
              match parse_memory_bank_row line with
              | Some row -> parsed_rev := row :: !parsed_rev
              | None -> incr invalid)
            lines;
          let parsed = List.rev !parsed_rev in
          let before_notes = List.length parsed in
          if before_notes <= target_notes && !invalid = 0 then
            { no_memory_bank_compaction with
              target_notes;
              before_notes;
              after_notes = before_notes;
              reason = Some "under_target";
            }
          else
            let by_recency =
              List.sort
                (fun (a : keeper_memory_row_raw) (b : keeper_memory_row_raw) ->
                  let c = compare b.ts_unix a.ts_unix in
                  if c <> 0 then c else compare b.priority a.priority)
                parsed
            in
            let dedup_keys : (string, unit) Hashtbl.t = Hashtbl.create 1024 in
            let dedup_rev = ref [] in
            List.iter
              (fun (row : keeper_memory_row_raw) ->
                let key = memory_row_key row in
                if key <> "" && not (Hashtbl.mem dedup_keys key) then begin
                  Hashtbl.add dedup_keys key ();
                  dedup_rev := row :: !dedup_rev
                end)
              by_recency;
            let deduped = List.rev !dedup_rev in
            let dedup_dropped = max 0 (before_notes - List.length deduped) in
            if List.length deduped <= target_notes && dedup_dropped = 0 && !invalid = 0 then
              { no_memory_bank_compaction with
                target_notes;
                before_notes;
                after_notes = before_notes;
                reason = Some "already_compact";
              }
            else
              let kind_caps =
                memory_kind_caps_for_compaction ~profile ~target_notes
              in
              let kind_used : (string, int) Hashtbl.t = Hashtbl.create 16 in
              let selected_keys : (string, unit) Hashtbl.t = Hashtbl.create 1024 in
              let selected_rev = ref [] in
              let selected_count = ref 0 in
              let fallback_kind_cap = max 8 (target_notes / 8) in
              let add_row ~ignore_kind_cap (row : keeper_memory_row_raw) =
                if !selected_count >= target_notes then
                  ()
                else
                  let key = memory_row_key row in
                  if key = "" || Hashtbl.mem selected_keys key then
                    ()
                  else
                    let used =
                      Option.value ~default:0 (Hashtbl.find_opt kind_used row.kind)
                    in
                    let cap =
                      Option.value ~default:fallback_kind_cap
                        (Hashtbl.find_opt kind_caps row.kind)
                    in
                    if ignore_kind_cap || used < cap then begin
                      Hashtbl.add selected_keys key ();
                      Hashtbl.replace kind_used row.kind (used + 1);
                      selected_rev := row :: !selected_rev;
                      incr selected_count
                    end
              in
              let recent_floor = max 16 (min 64 (target_notes / 5)) in
              by_recency
              |> take recent_floor
              |> List.iter (fun row -> add_row ~ignore_kind_cap:false row);
              let by_priority =
                List.sort
                  (fun (a : keeper_memory_row_raw) (b : keeper_memory_row_raw) ->
                    let c = compare b.priority a.priority in
                    if c <> 0 then c else compare b.ts_unix a.ts_unix)
                  deduped
              in
              List.iter (fun row -> add_row ~ignore_kind_cap:false row) by_priority;
              if !selected_count < target_notes then
                List.iter (fun row -> add_row ~ignore_kind_cap:true row) by_recency;
              let selected =
                !selected_rev
                |> List.rev
                |> List.sort
                     (fun (a : keeper_memory_row_raw) (b : keeper_memory_row_raw) ->
                       let c = compare a.ts_unix b.ts_unix in
                       if c <> 0 then c else compare a.priority b.priority)
              in
              let after_notes = List.length selected in
              let dropped_notes = max 0 (before_notes - after_notes) in
              if dropped_notes = 0 && !invalid = 0 then
                { no_memory_bank_compaction with
                  target_notes;
                  before_notes;
                  after_notes;
                  dedup_dropped;
                  reason = Some "no_reduction";
                }
              else
                match write_memory_bank_rows path selected with
                | Error _ ->
                    { no_memory_bank_compaction with
                      target_notes;
                      before_notes;
                      after_notes = before_notes;
                      dedup_dropped;
                      invalid_dropped = !invalid;
                      reason = Some "write_failed";
                    }
                | Ok () ->
                    {
                      performed = true;
                      reason = Some "compacted";
                      target_notes;
                      before_notes;
                      after_notes;
                      dropped_notes;
                      dedup_dropped;
                      invalid_dropped = !invalid;
                    }

let append_memory_notes_from_reply
    (config : Room.config)
    (meta : keeper_meta)
    ~(turn : int)
    ~(reply : string) : (int * string list) =
  match parse_state_snapshot_from_reply reply with
  | None -> (0, [])
  | Some snapshot ->
      let notes =
        memory_candidates_from_snapshot
          ~soul_profile:meta.soul_profile snapshot
      in
      if notes = [] then
        (0, [])
      else
        let now_ts = Time_compat.now () in
        let path = keeper_memory_bank_path config meta.name in
        let kinds_acc = ref [] in
        let seen_kinds : (string, unit) Hashtbl.t = Hashtbl.create 8 in
        List.iter
          (fun (kind, text, priority) ->
            if not (Hashtbl.mem seen_kinds kind) then begin
              Hashtbl.add seen_kinds kind ();
              kinds_acc := kind :: !kinds_acc
            end;
            append_jsonl_line path
              (`Assoc
                [
                  ("ts", `String (now_iso ()));
                  ("ts_unix", `Float now_ts);
                  ("name", `String meta.name);
                  ("trace_id", `String meta.trace_id);
                  ("generation", `Int meta.generation);
                  ("turn", `Int turn);
                  ("soul_profile", `String meta.soul_profile);
                  ("kind", `String kind);
                  ("priority", `Int priority);
                  ("text", `String text);
                ]))
          notes;
        (List.length notes, List.rev !kinds_acc)

let summarize_memory_bank_lines
    (lines : string list)
    ~(recent_limit : int) : keeper_memory_summary =
  let parsed =
    lines
    |> List.filter_map (fun line ->
         try
           let j = Yojson.Safe.from_string line in
           let kind = Safe_ops.json_string ~default:"" "kind" j in
           let text = Safe_ops.json_string ~default:"" "text" j in
           let priority = Safe_ops.json_int ~default:0 "priority" j in
           let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" j in
           let kind = String.trim kind in
           let text = String.trim text in
           if kind = "" || text = "" then None
           else Some { kind; text; priority; ts_unix }
         with Yojson.Json_error _ -> None)
  in
  let total_notes = List.length parsed in
  let last_ts_unix =
    parsed
    |> List.fold_left (fun acc (row : keeper_memory_line) ->
         max acc row.ts_unix)
         0.0
  in
  let kind_counts_tbl : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let kind_priority_tbl : (string, int) Hashtbl.t = Hashtbl.create 16 in
  List.iter
    (fun (row : keeper_memory_line) ->
      let cur = Option.value ~default:0 (Hashtbl.find_opt kind_counts_tbl row.kind) in
      Hashtbl.replace kind_counts_tbl row.kind (cur + 1);
      let pri_cur =
        Option.value ~default:min_int (Hashtbl.find_opt kind_priority_tbl row.kind)
      in
      Hashtbl.replace kind_priority_tbl row.kind (max pri_cur row.priority))
    parsed;
  let kind_counts =
    kind_counts_tbl
    |> Hashtbl.to_seq
    |> List.of_seq
    |> List.sort (fun (ka, va) (kb, vb) ->
         let c = compare vb va in
         if c <> 0 then c
         else
           let pa =
             Option.value ~default:min_int (Hashtbl.find_opt kind_priority_tbl ka)
           in
           let pb =
             Option.value ~default:min_int (Hashtbl.find_opt kind_priority_tbl kb)
           in
           let cp = compare pb pa in
           if cp <> 0 then cp else String.compare ka kb)
  in
  let top_kind =
    match kind_counts with
    | (kind, _) :: _ -> Some kind
    | [] -> None
  in
  let recent_notes =
    parsed
    |> List.rev
    |> take (max 0 recent_limit)
  in
  {
    total_notes;
    last_ts_unix;
    top_kind;
    kind_counts;
    recent_notes;
  }

let memory_summary_to_json (summary : keeper_memory_summary) : Yojson.Safe.t =
  `Assoc
    [
      ("total_notes", `Int summary.total_notes);
      ("last_ts_unix", `Float summary.last_ts_unix);
      ( "top_kind",
        match summary.top_kind with Some kind -> `String kind | None -> `Null );
      ( "kind_counts",
        `List
          (List.map
             (fun (kind, count) ->
               `Assoc [ ("kind", `String kind); ("count", `Int count) ])
             summary.kind_counts) );
      ( "recent_notes",
        `List
          (List.map
             (fun (row : keeper_memory_line) ->
               `Assoc
                 [
                   ("kind", `String row.kind);
                   ("text", `String row.text);
                   ("priority", `Int row.priority);
                   ("ts_unix", `Float row.ts_unix);
                 ])
             summary.recent_notes) );
    ]

let cost_usd_of_usage (usage : Llm_client.token_usage) (model : Llm_client.model_spec) : float =
  let input_cost = float_of_int usage.input_tokens *. model.cost_per_1k_input /. 1000.0 in
  let output_cost = float_of_int usage.output_tokens *. model.cost_per_1k_output /. 1000.0 in
  input_cost +. output_cost

let model_spec_for_used (specs : Llm_client.model_spec list) (model_used : string) :
  Llm_client.model_spec option =
  let used =
    if String.ends_with ~suffix:":latest" model_used then
      String.sub model_used 0 (String.length model_used - String.length ":latest")
    else
      model_used
  in
  List.find_opt (fun (m : Llm_client.model_spec) ->
    m.model_id = model_used || m.model_id = used
  ) specs

let read_file_tail_lines path ~max_bytes ~max_lines : string list =
  if max_lines <= 0 || max_bytes <= 0 then []
  else if not (Sys.file_exists path) then []
  else
    try
      let ic = open_in_bin path in
      Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
        let len = in_channel_length ic in
        let start = max 0 (len - max_bytes) in
        let starts_mid_line =
          if start <= 0 then false
          else (
            seek_in ic (start - 1);
            input_char ic <> '\n')
        in
        seek_in ic start;
        let remaining = len - start in
        let buf = Bytes.create remaining in
        really_input ic buf 0 remaining;
        let chunk = Bytes.to_string buf in
        let lines =
          chunk
          |> String.split_on_char '\n'
          |> List.filter (fun s -> String.trim s <> "")
        in
        let lines =
          match starts_mid_line, lines with
          | true, _ :: rest -> rest
          | _ -> lines
        in
        let n = List.length lines in
        let drop = max 0 (n - max_lines) in
        lines |> List.mapi (fun i s -> (i, s)) |> List.filter (fun (i, _) -> i >= drop) |> List.map snd
      )
    with Sys_error _ | End_of_file ->
      []

let read_keeper_memory_summary
    (config : Room.config)
    ~(name : string)
    ~(max_bytes : int)
    ~(max_lines : int)
    ~(recent_limit : int) : keeper_memory_summary =
  let lines =
    read_file_tail_lines
      (keeper_memory_bank_path config name)
      ~max_bytes
      ~max_lines
  in
  summarize_memory_bank_lines lines ~recent_limit

let is_memory_recall_query (s : string) : bool =
  let q = String.lowercase_ascii s in
  let needles = [
    "what did i ask";
    "first question";
    "before";
    "remember";
    "remembered";
    "do you remember";
    "memory";
    "기억";
    "기억해";
    "기억안나";
    "기억 안나";
    "기억나";
    "기억 나";
    "전에 뭐";
    "이전에";
    "첫 질문";
    "처음 물어";
    "뭐라고 물어봤";
  ] in
  List.exists (fun n ->
    try
      let _ = Str.search_forward (Str.regexp_string n) q 0 in
      true
    with Not_found -> false
  ) needles

let expected_topic_hint (s : string) : string option =
  let q = String.lowercase_ascii s in
  let has_ko needle =
    try let _ = Str.search_forward (Str.regexp_string needle) s 0 in true with Not_found -> false
  in
  let has_en needle =
    try let _ = Str.search_forward (Str.regexp_string needle) q 0 in true with Not_found -> false
  in
  if (try let _ = Str.search_forward (Str.regexp_string "날씨") s 0 in true with Not_found -> false)
     || (try let _ = Str.search_forward (Str.regexp_string "weather") q 0 in true with Not_found -> false)
  then
    Some "weather"
  else if has_ko "첫 질문"
       || has_en "first question"
       || has_en "very first"
       || has_en "earliest"
       || ((has_ko "처음" || has_ko "첫" || has_en "first")
           && (has_ko "질문" || has_ko "물어" || has_en "question" || has_en "ask"))
  then
    Some "first_question"
  else
    None

let normalize_for_similarity (s : string) : string list =
  let s = String.lowercase_ascii s in
  let b = Bytes.of_string s in
  for i = 0 to Bytes.length b - 1 do
    let c = Bytes.get b i in
    let code = Char.code c in
    let keep =
      (c >= 'a' && c <= 'z') ||
      (c >= '0' && c <= '9') ||
      code >= 128
    in
    if not keep then Bytes.set b i ' '
  done;
  let words =
    Bytes.to_string b
    |> String.split_on_char ' '
    |> List.filter (fun w -> String.length w >= 2)
  in
  let tbl : (string, unit) Hashtbl.t = Hashtbl.create 32 in
  List.filter (fun w ->
    if Hashtbl.mem tbl w then false
    else (Hashtbl.add tbl w (); true)
  ) words

let jaccard_similarity (a : string) (b : string) : float =
  let ta = normalize_for_similarity a in
  let tb = normalize_for_similarity b in
  if ta = [] && tb = [] then 1.0
  else if ta = [] || tb = [] then 0.0
  else
    let h : (string, bool) Hashtbl.t = Hashtbl.create 64 in
    List.iter (fun w -> Hashtbl.replace h w false) ta;
    let inter = ref 0 in
    let uniq_b = ref 0 in
    List.iter (fun w ->
      if Hashtbl.mem h w then begin
        if not (Hashtbl.find h w) then begin
          incr inter;
          Hashtbl.replace h w true
        end
      end else
        incr uniq_b
    ) tb;
    let union = (List.length ta) + !uniq_b in
    if union = 0 then 0.0 else float_of_int !inter /. float_of_int union

let latest_message_content_by_role
    ~(role : Llm_client.role)
    (messages : Llm_client.message list) : string option =
  match
    messages
    |> List.rev
    |> List.find_opt (fun (m : Llm_client.message) -> m.role = role)
  with
  | None -> None
  | Some m -> trim_nonempty (String.trim m.content)

let previous_assistant_message_content
    (messages : Llm_client.message list) : string option =
  let assistants =
    messages
    |> List.rev
    |> List.filter_map (fun (m : Llm_client.message) ->
         if m.role = Llm_client.Assistant then trim_nonempty m.content else None)
  in
  match assistants with
  | _latest :: previous :: _ -> Some previous
  | _ -> None

let goal_horizon_candidates (meta : keeper_meta) : string list =
  [meta.short_goal; meta.mid_goal; meta.long_goal; meta.goal]
  |> List.filter_map (fun raw ->
       raw
       |> normalize_goal_horizon_text
       |> trim_nonempty)
  |> List.fold_left
       (fun acc goal ->
         let key = normalize_memory_text_key goal in
         if List.exists (fun existing -> normalize_memory_text_key existing = key) acc then
           acc
         else
           goal :: acc)
       []
  |> List.rev

let best_goal_similarity ~(text : string) ~(goals : string list) : float =
  if goals = [] then 0.0
  else
    let candidate = String.trim text in
    if candidate = "" then 0.0
    else
      goals
      |> List.fold_left
           (fun best goal -> max best (jaccard_similarity candidate goal))
           0.0

let goal_alignment_score
    ~(meta : keeper_meta)
    ~(user_message : string option)
    ~(assistant_reply : string option) : float =
  let goals = goal_horizon_candidates meta in
  if goals = [] then 0.0
  else
    let user_score =
      match user_message with
      | None -> None
      | Some text -> Some (best_goal_similarity ~text ~goals)
    in
    let reply_score =
      match assistant_reply with
      | None -> None
      | Some text -> Some (best_goal_similarity ~text ~goals)
    in
    match user_score, reply_score with
    | None, None -> 0.0
    | Some s, None | None, Some s -> s
    | Some u, Some r -> (u +. r) /. 2.0

let repetition_risk_score
    ~(messages : Llm_client.message list)
    ~(candidate_reply : string option) : float =
  match candidate_reply with
  | Some reply -> (
      match latest_message_content_by_role ~role:Llm_client.Assistant messages with
      | Some prev -> jaccard_similarity reply prev
      | None -> 0.0)
  | None -> (
      match
        previous_assistant_message_content messages,
        latest_message_content_by_role ~role:Llm_client.Assistant messages
      with
      | Some prev, Some latest -> jaccard_similarity latest prev
      | _ -> 0.0)

type keeper_auto_rule_eval = {
  repetition_risk: float;
  goal_alignment: float;
  response_alignment: float;
  goal_drift: float;
  reflect: bool;
  plan: bool;
  compact: bool;
  handoff: bool;
  guardrail_stop: bool;
  guardrail_reason: string option;
  reasons: string list;
}

let keeper_auto_rule_eval_to_json (e : keeper_auto_rule_eval) : Yojson.Safe.t =
  `Assoc [
    ("repetition_risk", `Float e.repetition_risk);
    ("goal_alignment", `Float e.goal_alignment);
    ("response_alignment", `Float e.response_alignment);
    ("goal_drift", `Float e.goal_drift);
    ("reflect", `Bool e.reflect);
    ("plan", `Bool e.plan);
    ("compact", `Bool e.compact);
    ("handoff", `Bool e.handoff);
    ("guardrail_stop", `Bool e.guardrail_stop);
    ("guardrail_reason",
      match e.guardrail_reason with
      | Some reason -> `String reason
      | None -> `Null);
    ("reasons", `List (List.map (fun reason -> `String reason) e.reasons));
  ]

let keeper_reflection_payload_of_auto_rules (e : keeper_auto_rule_eval) : Yojson.Safe.t =
  let actions_rev = [] in
  let actions_rev =
    if e.reflect then `String "reflect" :: actions_rev else actions_rev
  in
  let actions_rev =
    if e.plan then `String "plan" :: actions_rev else actions_rev
  in
  let actions_rev =
    if e.compact then `String "compact" :: actions_rev else actions_rev
  in
  let actions_rev =
    if e.handoff then `String "handoff" :: actions_rev else actions_rev
  in
  let actions_rev =
    if e.guardrail_stop then `String "guardrail_stop" :: actions_rev else actions_rev
  in
  let has_action = actions_rev <> [] in
  `Assoc [
    ("triggered", `Bool has_action);
    ("actions", `List (List.rev actions_rev));
    ("guardrail_stop", `Bool e.guardrail_stop);
    ("guardrail_reason",
      match e.guardrail_reason with
      | Some reason -> `String reason
      | None -> `Null);
    ("goal_drift", `Float e.goal_drift);
    ("repetition_risk", `Float e.repetition_risk);
    ("goal_alignment", `Float e.goal_alignment);
    ("response_alignment", `Float e.response_alignment);
    ("reasons", `List (List.map (fun reason -> `String reason) e.reasons));
  ]

let evaluate_keeper_auto_rules
    ~(meta : keeper_meta)
    ~(context_ratio : float)
    ~(message_count : int)
    ~(token_count : int)
    ~(repetition_risk : float)
    ~(goal_alignment : float)
    ~(response_alignment : float) : keeper_auto_rule_eval =
  let ratio_gate = meta.compaction_ratio_gate in
  let message_gate = meta.compaction_message_gate in
  let token_gate = meta.compaction_token_gate in
  let reflect_threshold = keeper_rule_reflect_repetition_threshold () in
  let plan_goal_alignment_threshold = keeper_rule_plan_goal_alignment_threshold () in
  let plan_response_alignment_threshold = keeper_rule_plan_response_alignment_threshold () in
  let guardrail_repetition_threshold = keeper_rule_guardrail_repetition_threshold () in
  let guardrail_goal_alignment_threshold = keeper_rule_guardrail_goal_alignment_threshold () in
  let guardrail_response_alignment_threshold = keeper_rule_guardrail_response_alignment_threshold () in
  let guardrail_context_threshold =
    max ratio_gate (keeper_rule_guardrail_context_threshold ())
  in
  let goal_drift =
    1.0 -. max 0.0 (min 1.0 (max goal_alignment response_alignment))
    |> max 0.0
    |> min 1.0
  in
  let reflect = repetition_risk >= reflect_threshold in
  let plan =
    goal_alignment <= plan_goal_alignment_threshold
    && response_alignment <= plan_response_alignment_threshold
  in
  let compact =
    context_ratio >= ratio_gate
    || (message_gate > 0 && message_count >= message_gate)
    || (token_gate > 0 && token_count >= token_gate)
  in
  let handoff = meta.auto_handoff && context_ratio >= meta.handoff_threshold in
  let guardrail_stop =
    repetition_risk >= guardrail_repetition_threshold
    && goal_alignment <= guardrail_goal_alignment_threshold
    && response_alignment <= guardrail_response_alignment_threshold
    && context_ratio >= guardrail_context_threshold
  in
  let guardrail_reason =
    if guardrail_stop then
      Some
        (Printf.sprintf
           "guardrail_stop(rep=%.3f>=%.3f,goal=%.3f<=%.3f,response=%.3f<=%.3f,ctx=%.3f>=%.3f)"
           repetition_risk
           guardrail_repetition_threshold
           goal_alignment
           guardrail_goal_alignment_threshold
           response_alignment
           guardrail_response_alignment_threshold
           context_ratio
           guardrail_context_threshold)
    else
      None
  in
  let reasons = [] in
  let reasons =
    if reflect then
      (Printf.sprintf
         "reflect(repetition_risk=%.3f>=%.3f)"
         repetition_risk
         reflect_threshold)
      :: reasons
    else reasons
  in
  let reasons =
    if plan then
      (Printf.sprintf
         "plan(goal_alignment=%.3f<=%.3f,response_alignment=%.3f<=%.3f)"
         goal_alignment
         plan_goal_alignment_threshold
         response_alignment
         plan_response_alignment_threshold)
      :: reasons
    else reasons
  in
  let reasons =
    if compact then
      (Printf.sprintf
         "compact(ctx=%.3f,msg=%d,tokens=%d)"
         context_ratio
         message_count
         token_count)
      :: reasons
    else reasons
  in
  let reasons =
    if handoff then
      (Printf.sprintf
         "handoff(ctx=%.3f>=%.3f)"
         context_ratio
         meta.handoff_threshold)
      :: reasons
    else reasons
  in
  let reasons =
    match guardrail_reason with
    | Some reason -> reason :: reasons
    | None -> reasons
  in
  {
    repetition_risk;
    goal_alignment;
    response_alignment;
    goal_drift;
    reflect;
    plan;
    compact;
    handoff;
    guardrail_stop;
    guardrail_reason;
    reasons = List.rev reasons;
  }

let recent_user_messages (msgs : Llm_client.message list) ~(max_n : int) : string list =
  msgs
  |> List.rev
  |> List.filter_map (fun (m : Llm_client.message) ->
       if m.role = Llm_client.User then
         let c = String.trim m.content in
         if c = "" then None else Some c
       else None)
  |> take max_n

type memory_recall_eval = {
  performed: bool;
  query_kind: string;
  expected_topic: string option;
  candidate_count: int;
  initial_score: float;
  final_score: float;
  threshold: float;
  passed: bool;
  best_match: string option;
}

let evaluate_memory_recall
    ~(user_message : string)
    ~(assistant_reply : string)
    ~(candidates : string list) : memory_recall_eval =
  let recall = is_memory_recall_query user_message in
  let expected_topic = expected_topic_hint user_message in
  let has_weather_word (s : string) =
    let q = String.lowercase_ascii s in
    (try let _ = Str.search_forward (Str.regexp_string "날씨") s 0 in true with Not_found -> false)
    || (try let _ = Str.search_forward (Str.regexp_string "weather") q 0 in true with Not_found -> false)
  in
  let threshold =
    match expected_topic with
    | Some "weather" -> 0.15
    | _ -> 0.18
  in
  if not recall then
    {
      performed = false;
      query_kind = "none";
      expected_topic;
      candidate_count = List.length candidates;
      initial_score = 0.0;
      final_score = 0.0;
      threshold;
      passed = true;
      best_match = None;
    }
  else if candidates = [] then
    {
      performed = true;
      query_kind = Option.value ~default:"recall" expected_topic;
      expected_topic;
      candidate_count = 0;
      initial_score = 0.0;
      final_score = 0.0;
      threshold;
      passed = false;
      best_match = None;
    }
  else
    let weather_candidates = List.filter has_weather_word candidates in
    let candidates_for_general =
      match expected_topic with
      | Some "weather" when weather_candidates <> [] -> weather_candidates
      | _ -> candidates
    in
    let oldest_candidate =
      match List.rev candidates with
      | c :: _ -> Some c
      | [] -> None
    in
    let (best_msg, best_score) =
      match expected_topic, oldest_candidate with
      | Some "first_question", Some target ->
          (Some target, jaccard_similarity assistant_reply target)
      | _ ->
          List.fold_left (fun (best_m, best_s) cand ->
            let score = jaccard_similarity assistant_reply cand in
            if score > best_s then (Some cand, score) else (best_m, best_s)
          ) (None, 0.0) candidates_for_general
    in
    let topic_bonus =
      match expected_topic with
      | Some "weather" ->
          let has_weather_reply = has_weather_word assistant_reply in
          if has_weather_reply then 0.08 else -.0.08
      | Some "first_question" ->
          let has_first =
            (try let _ = Str.search_forward (Str.regexp_string "첫") assistant_reply 0 in true with Not_found -> false)
            || (try let _ = Str.search_forward (Str.regexp_string "first") (String.lowercase_ascii assistant_reply) 0 in true with Not_found -> false)
          in
          if has_first then 0.05 else -.0.05
      | _ -> 0.0
    in
    let final_score = max 0.0 (min 1.0 (best_score +. topic_bonus)) in
    {
      performed = true;
      query_kind = Option.value ~default:"recall" expected_topic;
      expected_topic;
      candidate_count = List.length candidates;
      initial_score = best_score;
      final_score;
      threshold;
      passed = final_score >= threshold;
      best_match = best_msg;
    }

let memory_eval_to_json
    (e : memory_recall_eval)
    ~(correction_applied : bool)
    ~(correction_success : bool)
    ~(correction_skipped_budget : bool)
    ~(prompt_fallback_applied : bool)
    ~(prompt_fallback_success : bool)
    ~(prompt_fallback_skipped_budget : bool)
    ~(postpass_budget_ms : int)
    ~(postpass_budget_remaining_ms : int)
    ~(recall_fallback_applied : bool) : Yojson.Safe.t =
  `Assoc [
    ("performed", `Bool e.performed);
    ("query_kind", `String e.query_kind);
    ("expected_topic", match e.expected_topic with Some t -> `String t | None -> `Null);
    ("candidate_count", `Int e.candidate_count);
    ("initial_score", `Float e.initial_score);
    ("final_score", `Float e.final_score);
    ("threshold", `Float e.threshold);
    ("passed", `Bool e.passed);
    ("best_match", match e.best_match with Some m -> `String m | None -> `Null);
    ("correction_applied", `Bool correction_applied);
    ("correction_success", `Bool correction_success);
    ("correction_skipped_budget", `Bool correction_skipped_budget);
    ("prompt_fallback_applied", `Bool prompt_fallback_applied);
    ("prompt_fallback_success", `Bool prompt_fallback_success);
    ("prompt_fallback_skipped_budget", `Bool prompt_fallback_skipped_budget);
    ("postpass_budget_ms", `Int postpass_budget_ms);
    ("postpass_budget_remaining_ms", `Int postpass_budget_remaining_ms);
    ("deterministic_fallback_applied", `Bool recall_fallback_applied);
    ("recall_fallback_applied", `Bool recall_fallback_applied);
  ]

let work_kind_of_eval (e : memory_recall_eval) : string =
  if e.performed then
    if e.query_kind <> "" && e.query_kind <> "none" then
      e.query_kind
    else
      "memory_recall"
  else
    match e.expected_topic with
    | Some "weather" -> "weather_answer"
    | Some "first_question" -> "first_question_answer"
    | Some topic when topic <> "" -> topic
    | _ -> "general_chat"

(* Tool definitions moved to Tool_shard for dynamic composition.
   This alias maintains backward compatibility. *)
let keeper_llm_tools = Tool_shard.keeper_llm_tools

let merge_usage
    (a : Llm_client.token_usage)
    (b : Llm_client.token_usage) : Llm_client.token_usage =
  {
    Llm_client.input_tokens = a.input_tokens + b.input_tokens;
    output_tokens = a.output_tokens + b.output_tokens;
    total_tokens = a.total_tokens + b.total_tokens;
    cache_creation_input_tokens =
      a.cache_creation_input_tokens + b.cache_creation_input_tokens;
    cache_read_input_tokens =
      a.cache_read_input_tokens + b.cache_read_input_tokens;
  }

let contains_ci (haystack : string) (needle : string) : bool =
  let h = String.lowercase_ascii haystack in
  let n = String.lowercase_ascii needle in
  if n = "" then false
  else
    try
      let _ = Str.search_forward (Str.regexp_string n) h 0 in
      true
    with Not_found -> false

let alert_retryable_error (msg : string) : bool =
  let text = String.lowercase_ascii (String.trim msg) in
  text <> ""
  && (contains_ci text "timeout"
      || contains_ci text "timed out"
      || contains_ci text "429"
      || contains_ci text "502"
      || contains_ci text "503"
      || contains_ci text "504"
      || contains_ci text "connection reset"
      || contains_ci text "connection refused"
      || contains_ci text "temporary"
      || contains_ci text "network")

let alert_retry_delay_seconds (attempt : int) : float =
  let base_ms = max 0 Env_config.KeeperAlert.retry_base_delay_ms in
  let rec pow2 n acc =
    if n <= 0 then acc else pow2 (n - 1) (acc * 2)
  in
  let factor = pow2 (max 0 (attempt - 1)) 1 in
  float_of_int (base_ms * factor) /. 1000.0

let run_alert_channel_with_retry
    (ctx : _ context)
    ~(channel : string)
    ~(enabled : bool)
    ~(send_once : unit -> bool * string option) : alert_channel_result =
  if not enabled then
    {
      channel;
      attempted = false;
      success = false;
      attempts = 0;
      detail = Some "disabled";
    }
  else
    let max_attempts = 1 + max 0 Env_config.KeeperAlert.max_retries in
    let rec loop attempt last_error =
      let (ok, detail_opt) = send_once () in
      let detail =
        match detail_opt with
        | Some s when String.trim s <> "" -> Some (short_preview ~max_len:280 s)
        | _ -> last_error
      in
      if ok then
        { channel; attempted = true; success = true; attempts = attempt; detail }
      else if attempt >= max_attempts then
        {
          channel;
          attempted = true;
          success = false;
          attempts = attempt;
          detail =
            (match detail with
             | Some _ -> detail
             | None -> Some "fanout failed");
        }
      else
        let err_msg = Option.value ~default:"fanout failed" detail in
        if not (alert_retryable_error err_msg) then
          {
            channel;
            attempted = true;
            success = false;
            attempts = attempt;
            detail = Some err_msg;
          }
        else (
          Eio.Time.sleep ctx.clock (alert_retry_delay_seconds attempt);
          loop (attempt + 1) (Some err_msg))
    in
    loop 1 None

let dedup_strings (xs : string list) : string list =
  List.fold_left
    (fun acc x -> if List.mem x acc then acc else acc @ [ x ])
    [] xs

let keeper_alert_signal
    ~(message : string)
    ~(reply : string)
    ~(context_ratio : float)
    ~(goal_alignment : float)
    ~(response_alignment : float)
    ~(tool_call_count : int)
    ~(auto_rules : keeper_auto_rule_eval) : float * string list * string list =
  let corpus = String.lowercase_ascii (message ^ "\n" ^ reply) in
  let keyword_weights = [
    ("장애", 0.35);
    ("사고", 0.30);
    ("롤백", 0.30);
    ("긴급", 0.25);
    ("critical", 0.30);
    ("urgent", 0.22);
    ("incident", 0.25);
    ("outage", 0.38);
    ("oncall", 0.18);
    ("p0", 0.32);
    ("sev1", 0.32);
    ("security", 0.35);
    ("breach", 0.45);
    ("data loss", 0.45);
    ("failover", 0.22);
    ("hotfix", 0.20);
    ("downtime", 0.28);
  ] in
  let keyword_hits =
    keyword_weights
    |> List.filter_map (fun (kw, w) ->
         if contains_ci corpus kw then Some (kw, w) else None)
  in
  let keyword_score =
    keyword_hits
    |> List.fold_left (fun acc (_, w) -> acc +. w) 0.0
    |> min 1.0
  in
  let score = ref keyword_score in
  let reasons = ref [] in
  if keyword_hits <> [] then
    reasons := "critical_keywords" :: !reasons;
  if auto_rules.guardrail_stop then begin
    score := !score +. 0.45;
    reasons := "guardrail_stop" :: !reasons
  end;
  if auto_rules.handoff && context_ratio >= 0.88 then begin
    score := !score +. 0.16;
    reasons := "handoff_pressure" :: !reasons
  end;
  if goal_alignment < 0.20 && response_alignment < 0.16 then begin
    score := !score +. 0.12;
    reasons := "low_alignment" :: !reasons
  end;
  if tool_call_count >= 2 then begin
    score := !score +. 0.06;
    reasons := "multi_tool_action" :: !reasons
  end;
  let score = max 0.0 (min 1.0 !score) in
  let keywords = keyword_hits |> List.map fst |> dedup_strings in
  (score, List.rev !reasons, keywords)

let keeper_alert_text
    ~(meta : keeper_meta)
    ~(score : float)
    ~(reasons : string list)
    ~(keywords : string list)
    ~(message : string)
    ~(reply : string)
    ~(work_kind : string)
    ~(context_ratio : float)
    ~(goal_alignment : float)
    ~(response_alignment : float) : string =
  let reason_text =
    if reasons = [] then "-" else String.concat ", " reasons
  in
  let keyword_text =
    if keywords = [] then "-" else String.concat ", " keywords
  in
  let excerpt_cap = max 240 Env_config.KeeperAlert.max_body_chars in
  let message_preview = short_preview ~max_len:(min excerpt_cap 300) message in
  let reply_preview = short_preview ~max_len:(min excerpt_cap 420) reply in
  Printf.sprintf
    "[keeper-alert] %s score=%.2f\n\
     - trace: %s\n\
     - generation: %d\n\
     - work_kind: %s\n\
     - reasons: %s\n\
     - keywords: %s\n\
     - context_ratio: %.2f\n\
     - goal_alignment: %.2f\n\
     - response_alignment: %.2f\n\
     - user: %s\n\
     - reply: %s"
    meta.name score meta.trace_id meta.generation work_kind
    reason_text keyword_text context_ratio goal_alignment response_alignment
    message_preview reply_preview

let post_keeper_alert_board
    ~(alert_text : string) : bool * string option =
  let author =
    let v = String.trim Env_config.KeeperAlert.board_author in
    if v = "" then "keeper-alert-bot" else v
  in
  let hearth_opt =
    let v = String.trim Env_config.KeeperAlert.board_hearth in
    if v = "" then None else Some v
  in
  let visibility =
    let v = String.trim Env_config.KeeperAlert.board_visibility in
    if v = "" then "internal" else v
  in
  let fields = ref [
    ("author", `String author);
    ("content", `String alert_text);
    ("visibility", `String visibility);
  ] in
  (match hearth_opt with
   | Some h -> fields := ("hearth", `String h) :: !fields
   | None -> ());
  let (ok, res) = Tool_board.handle_tool "masc_board_post" (`Assoc (List.rev !fields)) in
  if ok then (true, Some "board_posted") else (false, Some res)

let post_keeper_alert_slack
    ~(alert_text : string) : bool * string option =
  let webhook = String.trim Env_config.KeeperAlert.slack_webhook_url in
  if webhook = "" then
    (false, Some "missing_webhook")
  else
    let payload = `Assoc [ ("text", `String alert_text) ] |> Yojson.Safe.to_string in
    let argv = [
      "curl";
      "-sS";
      "--fail";
      "--max-time"; "10";
      "-X"; "POST";
      "-H"; "Content-Type: application/json";
      "--data-binary"; "@-";
      webhook;
    ] in
    let (status, out) =
      Process_eio.run_argv_with_stdin_and_status
        ~timeout_sec:15.0
        ~stdin_content:payload
        argv
    in
    match status with
    | Unix.WEXITED 0 -> (true, Some "slack_posted")
    | Unix.WEXITED n ->
        (false, Some (Printf.sprintf "curl_exit_%d: %s" n (short_preview ~max_len:200 out)))
    | Unix.WSIGNALED n ->
        (false, Some (Printf.sprintf "curl_signaled_%d" n))
    | Unix.WSTOPPED n ->
        (false, Some (Printf.sprintf "curl_stopped_%d" n))

let slack_alert_token () : string option =
  let pick name =
    match Sys.getenv_opt name with
    | Some v when String.trim v <> "" -> Some (String.trim v)
    | _ -> None
  in
  match pick "SLACK_BOT_TOKEN" with
  | Some _ as tok -> tok
  | None ->
      (match pick "SLACK_USER_TOKEN" with
       | Some _ as tok -> tok
       | None -> pick "SLACK_TOKEN")

let slack_api_post_json
    ~(token : string)
    ~(endpoint : string)
    ~(payload : Yojson.Safe.t) : (Yojson.Safe.t, string) result =
  let url = Printf.sprintf "https://slack.com/api/%s" endpoint in
  let body = Yojson.Safe.to_string payload in
  let argv = [
    "curl";
    "-sS";
    "--fail";
    "--max-time"; "12";
    "-X"; "POST";
    "-H"; "Content-Type: application/json; charset=utf-8";
    "-H"; ("Authorization: Bearer " ^ token);
    "--data-binary"; "@-";
    url;
  ] in
  let (status, out) =
    Process_eio.run_argv_with_stdin_and_status
      ~timeout_sec:15.0
      ~stdin_content:body
      argv
  in
  match status with
  | Unix.WEXITED 0 ->
      (try
         Ok (Yojson.Safe.from_string out)
       with exn ->
         Error (Printf.sprintf "json_parse_failed: %s" (Printexc.to_string exn)))
  | Unix.WEXITED n ->
      Error (Printf.sprintf "curl_exit_%d: %s" n (short_preview ~max_len:220 out))
  | Unix.WSIGNALED n ->
      Error (Printf.sprintf "curl_signaled_%d" n)
  | Unix.WSTOPPED n ->
      Error (Printf.sprintf "curl_stopped_%d" n)

let slack_ok_or_error (json : Yojson.Safe.t) : (unit, string) result =
  let ok = Safe_ops.json_bool ~default:false "ok" json in
  if ok then Ok ()
  else
    let err =
      match Safe_ops.json_string_opt "error" json with
      | Some e when String.trim e <> "" -> e
      | _ -> "slack_api_error"
    in
    Error err

let post_keeper_alert_slack_dm
    ~(alert_text : string)
    ~(user_id : string) : bool * string option =
  let target = String.trim user_id in
  if target = "" then
    (false, Some "missing_dm_user_id")
  else
    match slack_alert_token () with
    | None -> (false, Some "missing_slack_token")
    | Some token ->
        let open_payload = `Assoc [ ("users", `String target) ] in
        match slack_api_post_json ~token ~endpoint:"conversations.open" ~payload:open_payload with
        | Error e -> (false, Some ("dm_open_failed: " ^ e))
        | Ok open_json ->
            (match slack_ok_or_error open_json with
             | Error e -> (false, Some ("dm_open_failed: " ^ e))
             | Ok () ->
                 let channel_id =
                   let open Yojson.Safe.Util in
                   match open_json |> member "channel" |> member "id" with
                   | `String s when String.trim s <> "" -> Some s
                   | _ -> None
                 in
                 (match channel_id with
                  | None -> (false, Some "dm_open_failed: missing_channel_id")
                  | Some cid ->
                      let post_payload = `Assoc [
                        ("channel", `String cid);
                        ("text", `String alert_text);
                      ] in
                      (match slack_api_post_json ~token ~endpoint:"chat.postMessage" ~payload:post_payload with
                       | Error e -> (false, Some ("dm_post_failed: " ^ e))
                       | Ok post_json ->
                           (match slack_ok_or_error post_json with
                            | Ok () -> (true, Some ("dm_sent:" ^ cid))
                            | Error e -> (false, Some ("dm_post_failed: " ^ e))))))

let split_csv_nonempty (raw : string) : string list =
  raw
  |> String.split_on_char ','
  |> List.map String.trim
  |> List.filter (fun s -> s <> "")

let post_keeper_alert_github
    ~(title : string)
    ~(body : string) : bool * string option =
  let repo = String.trim Env_config.KeeperAlert.github_repo in
  if repo = "" then
    (false, Some "missing_repo")
  else
    let labels = split_csv_nonempty Env_config.KeeperAlert.github_label in
    let args = [
      "gh"; "issue"; "create";
      "--repo"; repo;
      "--title"; title;
      "--body"; body;
    ]
    @ List.concat_map (fun label -> [ "--label"; label ]) labels
    in
    let (status, out) = Process_eio.run_argv_with_status ~timeout_sec:20.0 args in
    match status with
    | Unix.WEXITED 0 -> (true, Some (short_preview ~max_len:200 out))
    | Unix.WEXITED n ->
        (false, Some (Printf.sprintf "gh_exit_%d: %s" n (short_preview ~max_len:200 out)))
    | Unix.WSIGNALED n ->
        (false, Some (Printf.sprintf "gh_signaled_%d" n))
    | Unix.WSTOPPED n ->
        (false, Some (Printf.sprintf "gh_stopped_%d" n))

let maybe_emit_interesting_alert
    (ctx : _ context)
    ~(meta : keeper_meta)
    ~(message : string)
    ~(reply : string)
    ~(work_kind : string)
    ~(tool_call_count : int)
    ~(context_ratio : float)
    ~(goal_alignment : float)
    ~(response_alignment : float)
    ~(auto_rules : keeper_auto_rule_eval) : interesting_alert_result =
  let enabled = Env_config.KeeperAlert.enabled in
  let threshold = max 0.0 (min 1.0 Env_config.KeeperAlert.min_score) in
  if not enabled then
    { empty_interesting_alert_result with enabled = false; threshold }
  else
    let (score, reasons, keywords) =
      keeper_alert_signal
        ~message
        ~reply
        ~context_ratio
        ~goal_alignment
        ~response_alignment
        ~tool_call_count
        ~auto_rules
    in
    if score < threshold then
      {
        empty_interesting_alert_result with
        enabled = true;
        threshold;
        score;
        reasons;
        keywords;
      }
    else
      let now_ts = Time_compat.now () in
      let alert_id = Printf.sprintf "%s-%d" meta.trace_id (int_of_float (now_ts *. 1000.0)) in
      let alert_text =
        keeper_alert_text
          ~meta
          ~score
          ~reasons
          ~keywords
          ~message
          ~reply
          ~work_kind
          ~context_ratio
          ~goal_alignment
          ~response_alignment
      in
      let alert_json =
        `Assoc [
          ("ts", `String (now_iso ()));
          ("ts_unix", `Float now_ts);
          ("alert_id", `String alert_id);
          ("name", `String meta.name);
          ("agent_name", `String meta.agent_name);
          ("trace_id", `String meta.trace_id);
          ("generation", `Int meta.generation);
          ("score", `Float score);
          ("threshold", `Float threshold);
          ("reasons", `List (List.map (fun s -> `String s) reasons));
          ("keywords", `List (List.map (fun s -> `String s) keywords));
          ("work_kind", `String work_kind);
          ("tool_call_count", `Int tool_call_count);
          ("context_ratio", `Float context_ratio);
          ("goal_alignment", `Float goal_alignment);
          ("response_alignment", `Float response_alignment);
          ("message_preview", `String (short_preview ~max_len:260 message));
          ("reply_preview", `String (short_preview ~max_len:360 reply));
        ]
      in
      (try append_jsonl_line (keeper_alerts_path ctx.config) alert_json with exn ->
      Printf.eprintf "[keeper] alert JSONL write failed: %s\n%!" (Printexc.to_string exn));
      let board_result =
        run_alert_channel_with_retry ctx
          ~channel:"board"
          ~enabled:Env_config.KeeperAlert.board_enabled
          ~send_once:(fun () -> post_keeper_alert_board ~alert_text)
      in
      let slack_enabled =
        Env_config.KeeperAlert.slack_enabled
        && String.trim Env_config.KeeperAlert.slack_webhook_url <> ""
      in
      let slack_result =
        run_alert_channel_with_retry ctx
          ~channel:"slack"
          ~enabled:slack_enabled
          ~send_once:(fun () -> post_keeper_alert_slack ~alert_text)
      in
      let slack_dm_target = String.trim Env_config.KeeperAlert.slack_dm_user_id in
      let slack_dm_enabled =
        Env_config.KeeperAlert.slack_dm_enabled
        && slack_dm_target <> ""
      in
      let slack_dm_result =
        run_alert_channel_with_retry ctx
          ~channel:"slack_dm"
          ~enabled:slack_dm_enabled
          ~send_once:(fun () -> post_keeper_alert_slack_dm ~alert_text ~user_id:slack_dm_target)
      in
      let github_enabled =
        Env_config.KeeperAlert.github_enabled
        && String.trim Env_config.KeeperAlert.github_repo <> ""
        && score >= Env_config.KeeperAlert.github_min_score
      in
      let gh_title =
        Printf.sprintf "[keeper-alert] %s score %.2f (%s)"
          meta.name score (String.concat "," (if reasons = [] then [ "signal" ] else reasons))
      in
      let gh_body =
        utf8_safe_prefix_bytes
          (alert_text ^ "\n\n---\n\nraw alert json:\n" ^ Yojson.Safe.pretty_to_string alert_json)
          ~max_bytes:(max 800 Env_config.KeeperAlert.max_body_chars)
      in
      let github_result =
        run_alert_channel_with_retry ctx
          ~channel:"github"
          ~enabled:github_enabled
          ~send_once:(fun () -> post_keeper_alert_github ~title:gh_title ~body:gh_body)
      in
      let channels = [ board_result; slack_result; slack_dm_result; github_result ] in
      let attempted_failures =
        channels
        |> List.filter (fun r -> r.attempted && not r.success)
      in
      let attempted_success =
        channels
        |> List.exists (fun r -> r.attempted && r.success)
      in
      let retry_queued = attempted_failures <> [] in
      let deadlettered = attempted_failures <> [] && not attempted_success in
      if retry_queued then
        (try
           append_jsonl_line
             (keeper_alert_retry_path ctx.config)
             (`Assoc [
                ("ts", `String (now_iso ()));
                ("ts_unix", `Float now_ts);
                ("alert_id", `String alert_id);
                ("alert", alert_json);
                ("failed_channels",
                  `List (List.map alert_channel_result_to_json attempted_failures));
              ])
         with exn ->
           Printf.eprintf "[keeper] failed-channels JSONL write failed: %s\n%!" (Printexc.to_string exn));
      if deadlettered then
        (try
           append_jsonl_line
             (keeper_alert_deadletter_path ctx.config)
             (`Assoc [
                ("ts", `String (now_iso ()));
                ("ts_unix", `Float now_ts);
                ("alert_id", `String alert_id);
                ("alert", alert_json);
                ("channels",
                  `List (List.map alert_channel_result_to_json channels));
              ])
         with exn ->
           Printf.eprintf "[keeper] deadletter JSONL write failed: %s\n%!" (Printexc.to_string exn));
      {
        enabled = true;
        triggered = true;
        score;
        threshold;
        reasons;
        keywords;
        alert_id = Some alert_id;
        channels;
        retry_queued;
        deadlettered;
      }

type keeper_skill_route = {
  primary_skill: string;
  secondary_skills: string list;
  reason: string;
}

type keeper_skill_selection_mode =
  | SkillSelectHeuristic
  | SkillSelectAgent

let keeper_skill_selection_mode () : keeper_skill_selection_mode =
  match Sys.getenv_opt "MASC_KEEPER_SKILL_SELECTION" with
  | None -> SkillSelectAgent
  | Some raw ->
      let v = String.lowercase_ascii (String.trim raw) in
      if v = "" || v = "agent" || v = "llm" || v = "auto"
      then SkillSelectAgent
      else SkillSelectHeuristic

let keeper_allowed_skills = [
  "masc-heartbeat";
  "lodge-social";
  "masc-keeper-autonomy";
  "trpg-roleplay";
]

let canonical_keeper_skill_token (raw : string) : string option =
  match String.lowercase_ascii (String.trim raw) with
  | "masc-heartbeat" | "masc_heartbeat" | "heartbeat" -> Some "masc-heartbeat"
  | "lodge-social" | "lodge_social" | "lodge" | "social" -> Some "lodge-social"
  | "masc-keeper-autonomy"
  | "masc_keeper_autonomy"
  | "keeper-autonomy"
  | "keeper"
  | "autonomy" ->
      Some "masc-keeper-autonomy"
  | "trpg-roleplay" | "trpg_roleplay" | "trpg" | "roleplay" | "rp" ->
      Some "trpg-roleplay"
  | _ -> None

let unique_skills_preserve_order (xs : string list) : string list =
  List.fold_left
    (fun acc x -> if List.mem x acc then acc else acc @ [x])
    []
    xs

let skill_match_count_ci ~(text : string) ~(keywords : string list) : int =
  List.fold_left
    (fun acc keyword -> if contains_ci text keyword then acc + 1 else acc)
    0 keywords

let keeper_skill_priority ~(soul_profile : string) (skill : string) : int =
  let profile =
    canonical_soul_profile soul_profile |> Option.value ~default:default_soul_profile
  in
  match profile, skill with
  | "safety", "masc-heartbeat" -> 0
  | "safety", "masc-keeper-autonomy" -> 1
  | "safety", "lodge-social" -> 2
  | "delivery", "masc-keeper-autonomy" -> 0
  | "delivery", "masc-heartbeat" -> 1
  | "delivery", "lodge-social" -> 2
  | "research", "lodge-social" -> 0
  | "research", "masc-keeper-autonomy" -> 1
  | "research", "masc-heartbeat" -> 2
  | _, "masc-keeper-autonomy" -> 0
  | _, "masc-heartbeat" -> 1
  | _, "lodge-social" -> 2
  | _ -> 9

let route_keeper_skill ~(soul_profile : string) ~(message : string) : keeper_skill_route =
  let heartbeat_keywords = [
    "heartbeat"; "alive"; "status"; "health"; "diagnose"; "liveness";
    "하트비트"; "살아"; "상태"; "진단"; "헬스";
  ] in
  let lodge_keywords = [
    "board"; "post"; "comment"; "feed"; "social"; "lodge"; "k2k";
    "보드"; "포스트"; "댓글"; "피드"; "활동"; "소셜";
  ] in
  let keeper_keywords = [
    "keeper"; "handoff"; "compaction"; "context"; "generation"; "trace"; "memory";
    "키퍼"; "승계"; "핸드오프"; "컴팩팅"; "컨텍스트"; "세대"; "메모리";
  ] in
  let profile =
    canonical_soul_profile soul_profile |> Option.value ~default:default_soul_profile
  in
  let heartbeat_score = skill_match_count_ci ~text:message ~keywords:heartbeat_keywords in
  let lodge_score = skill_match_count_ci ~text:message ~keywords:lodge_keywords in
  let keeper_score = skill_match_count_ci ~text:message ~keywords:keeper_keywords in
  let heartbeat_bonus, lodge_bonus, keeper_bonus =
    match profile with
    | "safety" -> (1, 0, 1)
    | "delivery" -> (0, 0, 1)
    | "research" -> (0, 1, 1)
    | "relationship" -> (0, 1, 1)
    | _ -> (0, 0, 1)
  in
  let scored = [
    ("masc-heartbeat", heartbeat_score + heartbeat_bonus);
    ("lodge-social", lodge_score + lodge_bonus);
    ("masc-keeper-autonomy", keeper_score + keeper_bonus);
  ] in
  let sorted =
    List.sort
      (fun (sa, score_a) (sb, score_b) ->
         let c = compare score_b score_a in
         if c <> 0 then c
         else
           compare
             (keeper_skill_priority ~soul_profile:profile sa)
             (keeper_skill_priority ~soul_profile:profile sb))
      scored
  in
  let primary_skill =
    match sorted with
    | (name, _) :: _ -> name
    | [] -> "masc-keeper-autonomy"
  in
  let secondary_skills =
    sorted
    |> List.filter_map (fun (name, score) ->
           if name = primary_skill || score <= 0 then None else Some name)
    |> take 1
  in
  let reason =
    Printf.sprintf
      "profile=%s; scores{heartbeat=%d,lodge=%d,keeper=%d}"
      profile
      (heartbeat_score + heartbeat_bonus)
      (lodge_score + lodge_bonus)
      (keeper_score + keeper_bonus)
  in
  { primary_skill; secondary_skills; reason }

let skill_route_header (route : keeper_skill_route) : string =
  match route.secondary_skills with
  | [] -> Printf.sprintf "SKILL: %s" route.primary_skill
  | secs ->
      Printf.sprintf
        "SKILL: %s (+%s)"
        route.primary_skill
        (String.concat ", " secs)

let ensure_skill_route_header ~(route : keeper_skill_route) (raw : string) : string =
  let trimmed = String.trim raw in
  if trimmed = "" then
    skill_route_header route
  else
    let first_line =
      match String.split_on_char '\n' trimmed with
      | head :: _ -> String.trim head
      | [] -> ""
    in
    let already_tagged =
      match strip_prefix_ci ~prefix:"SKILL:" first_line with
      | Some _ -> true
      | None -> false
    in
    if already_tagged then raw
    else Printf.sprintf "%s\n%s" (skill_route_header route) raw

let strip_skill_route_lines (raw : string) : string =
  let lines = String.split_on_char '\n' raw in
  let keep line =
    let trimmed = String.trim line in
    if trimmed = "" then true
    else
      match strip_prefix_ci ~prefix:"SKILL:" trimmed with
      | Some _ -> false
      | None -> (
          match strip_prefix_ci ~prefix:"SKILL_REASON:" trimmed with
          | Some _ -> false
          | None -> true)
  in
  lines |> List.filter keep |> String.concat "\n"

let parse_skill_line (line : string) : (string * string list) option =
  match strip_prefix_ci ~prefix:"SKILL:" line with
  | None -> None
  | Some payload ->
      let payload = String.trim payload in
      if payload = "" then None
      else
        let payload_len = String.length payload in
        let rec first_sep i =
          if i >= payload_len then payload_len
          else
            match payload.[i] with
            | ' ' | '\t' | '(' -> i
            | _ -> first_sep (i + 1)
        in
        let primary_end = first_sep 0 in
        let primary_raw = String.sub payload 0 primary_end |> String.trim in
        let rest =
          if primary_end >= payload_len then ""
          else String.sub payload primary_end (payload_len - primary_end) |> String.trim
        in
        let secondary_raw_opt =
          if String.length rest >= 2 && String.sub rest 0 2 = "(+" then
            try
              let close_idx = Str.search_forward (Str.regexp_string ")") rest 2 in
              let inside = String.sub rest 2 (close_idx - 2) |> String.trim in
              if inside = "" then None else Some inside
            with Not_found ->
              None
          else
            None
        in
        match canonical_keeper_skill_token primary_raw with
        | None -> None
        | Some primary ->
            let secondary =
              match secondary_raw_opt with
              | None -> []
              | Some raw ->
                  raw
                  |> String.split_on_char ','
                  |> List.filter_map canonical_keeper_skill_token
                  |> unique_skills_preserve_order
                  |> List.filter (fun s -> s <> primary)
                  |> take 1
            in
            Some (primary, secondary)

let parse_skill_reason_line (line : string) : string option =
  match strip_prefix_ci ~prefix:"SKILL_REASON:" line with
  | Some v -> trim_nonempty v
  | None -> None

let agent_selected_skill_route_from_reply (raw : string) : keeper_skill_route option =
  let lines =
    raw
    |> String.split_on_char '\n'
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")
  in
  match lines with
  | [] -> None
  | first :: tail ->
      (match parse_skill_line first with
       | None -> None
       | Some (primary, secondary) ->
           let reason =
             tail
             |> take 3
             |> List.find_map parse_skill_reason_line
             |> Option.value ~default:"agent-selected"
           in
           Some { primary_skill = primary; secondary_skills = secondary; reason })

let skill_route_system_prompt_heuristic
    ~(base_system_prompt : string)
    ~(route : keeper_skill_route) : string =
  Printf.sprintf
    "%s\n\n\
     Skill routing policy (strict):\n\
     - Selected primary skill: %s\n\
     - Secondary skill(s): %s\n\
     - Selection reason: %s\n\
     - First line of assistant output MUST be exactly `%s`.\n\
     - After the first line, answer normally and concretely.\n\
     - Do not fabricate capabilities beyond the selected skills."
    base_system_prompt
    route.primary_skill
    (if route.secondary_skills = [] then "none" else String.concat ", " route.secondary_skills)
    route.reason
    (skill_route_header route)

let skill_route_system_prompt_agent
    ~(base_system_prompt : string)
    ~(fallback_route : keeper_skill_route)
    ~(soul_profile : string) : string =
  Printf.sprintf
    "%s\n\n\
     Skill routing policy (agent-selected):\n\
     - Available skills: %s\n\
     - SOUL profile: %s\n\
     - You MUST choose exactly one primary skill from the list above.\n\
     - You MAY add at most one secondary skill.\n\
     - First line MUST be: SKILL: <primary> (+<secondary>)\n\
     - Second line SHOULD be: SKILL_REASON: <short reason>\n\
     - If uncertain, default to `%s`.\n\
     - After those lines, answer normally and concretely.\n\
     - Do not fabricate capabilities beyond chosen skills."
    base_system_prompt
    (String.concat ", " keeper_allowed_skills)
    soul_profile
    fallback_route.primary_skill

let is_weather_text (s : string) : bool =
  contains_ci s "weather"
  || (try let _ = Str.search_forward (Str.regexp_string "날씨") s 0 in true with Not_found -> false)

let extract_user_messages (ctx_work : Context_manager.working_context) : string list =
  ctx_work.messages
  |> List.filter_map (fun (m : Llm_client.message) ->
       if m.role = Llm_client.User then
         let c = String.trim m.content in
         if c = "" then None else Some c
       else
         None)

let project_root_of_config (config : Room.config) : string =
  let base = config.base_path in
  if Filename.basename base = ".masc" then Filename.dirname base else base

let starts_with ~(prefix : string) (s : string) : bool =
  let lp = String.length prefix in
  String.length s >= lp && String.sub s 0 lp = prefix

let normalize_path_for_check (path : string) : string =
  try Unix.realpath path
  with Unix.Unix_error _ ->
    let parent = Filename.dirname path in
    let parent_norm =
      try Unix.realpath parent
      with Unix.Unix_error _ -> parent
    in
    Filename.concat parent_norm (Filename.basename path)

let resolve_keeper_target_path ~(config : Room.config) ~(raw_path : string)
    : (string, string) result =
  let raw = String.trim raw_path in
  if raw = "" then Error "path_required"
  else
    let root = project_root_of_config config in
    let candidate =
      if Filename.is_relative raw then Filename.concat root raw else raw
    in
    let root_norm = normalize_path_for_check root in
    let target_norm = normalize_path_for_check candidate in
    let allowed =
      target_norm = root_norm
      || starts_with ~prefix:(root_norm ^ "/") target_norm
    in
    if allowed then Ok candidate
    else
      Error
        (Printf.sprintf
           "path_outside_project_root: %s (root=%s)"
           target_norm
           root_norm)

let truncate_tool_output ?(max_len = 12000) (s : string) : string =
  if String.length s <= max_len then s
  else String.sub s 0 max_len ^ "\n...[truncated]"

let process_status_to_json (st : Unix.process_status) : Yojson.Safe.t =
  match st with
  | Unix.WEXITED code ->
      `Assoc [("kind", `String "exit"); ("code", `Int code)]
  | Unix.WSIGNALED sig_num ->
      `Assoc [("kind", `String "signaled"); ("signal", `Int sig_num)]
  | Unix.WSTOPPED sig_num ->
      `Assoc [("kind", `String "stopped"); ("signal", `Int sig_num)]

let execute_keeper_tool_call
    ~(config : Room.config)
    ~(meta : keeper_meta)
    ~(ctx_work : Context_manager.working_context)
    (tc : Llm_client.tool_call) : string =
  let args =
    try Yojson.Safe.from_string tc.call_arguments
    with Yojson.Json_error _ -> `Assoc []
  in
  let now_ts = Time_compat.now () in
  match tc.call_name with
  | "keeper_time_now" ->
      Yojson.Safe.to_string (`Assoc [
        ("now_iso", `String (now_iso ()));
        ("now_unix", `Float now_ts);
      ])
  | "keeper_context_status" ->
      let continuity = latest_state_snapshot_from_messages ctx_work.messages in
      let continuity_summary =
        match continuity with
        | None ->
            let trimmed = String.trim meta.continuity_summary in
            if trimmed = "" then "No continuity snapshot available." else trimmed
        | Some snapshot -> keeper_state_snapshot_to_summary_text snapshot
      in
      Yojson.Safe.to_string (`Assoc [
        ("name", `String meta.name);
        ("trace_id", `String meta.trace_id);
        ("generation", `Int meta.generation);
        ("context_ratio", `Float (Context_manager.context_ratio ctx_work));
        ("context_tokens", `Int ctx_work.token_count);
        ("context_max", `Int ctx_work.max_tokens);
        ("message_count", `Int (List.length ctx_work.messages));
        ("last_model_used", `String meta.last_model_used);
        ("continuity_state",
          match continuity with
          | None -> `Null
          | Some snapshot -> keeper_state_snapshot_to_json snapshot);
        ("continuity_summary",
          `String
            continuity_summary)
      ])
  | "keeper_memory_search" ->
      let query = Safe_ops.json_string ~default:"" "query" args |> String.trim in
      let limit = max 1 (min 8 (Safe_ops.json_int ~default:5 "limit" args)) in
      let user_msgs = extract_user_messages ctx_work in
      let matches =
        user_msgs
        |> List.filter (fun msg -> query <> "" && contains_ci msg query)
        |> List.rev
        |> take limit
        |> List.map (fun msg -> `String msg)
      in
      Yojson.Safe.to_string (`Assoc [
        ("query", `String query);
        ("match_count", `Int (List.length matches));
        ("matches", `List matches);
      ])
  | "keeper_weather_note" ->
      let location = Safe_ops.json_string ~default:"current location" "location" args in
      let recent_weather_questions =
        extract_user_messages ctx_work
        |> List.filter is_weather_text
        |> List.rev
        |> take 5
        |> List.map (fun q -> `String q)
      in
      Yojson.Safe.to_string (`Assoc [
        ("location", `String location);
        ("capability", `String "no_realtime_weather_feed");
        ("note", `String "This keeper cannot fetch live weather by itself.");
        ("recent_weather_questions", `List recent_weather_questions);
      ])
  (* Board tools — delegate to Tool_board with keeper name as author *)
  | "keeper_board_post" ->
      let author = meta.name in
      Printf.eprintf "[TRPG-TRACE] keeper_board_post called by %s, raw args: %s\n%!"
        author (Yojson.Safe.to_string args);
      let board_args = match args with
        | `Assoc fields ->
            (* Inject author from keeper meta, override if LLM set it *)
            let fields' = List.filter (fun (k, _) -> k <> "author") fields in
            `Assoc (("author", `String author) :: fields')
        | other -> other
      in
      Printf.eprintf "[TRPG-TRACE] board_args: %s\n%!" (Yojson.Safe.to_string board_args);
      let (ok, msg) = Tool_board.handle_tool "masc_board_post" board_args in
      Printf.eprintf "[TRPG-TRACE] handle_tool result: ok=%b msg=%s\n%!" ok
        (if String.length msg > 200 then String.sub msg 0 200 ^ "..." else msg);
      if ok then msg else Yojson.Safe.to_string (`Assoc [("error", `String msg)])
  | "keeper_board_list" ->
      let (ok, msg) = Tool_board.handle_tool "masc_board_list" args in
      if ok then msg else Yojson.Safe.to_string (`Assoc [("error", `String msg)])
  | "keeper_board_comment" ->
      let author = meta.name in
      let board_args = match args with
        | `Assoc fields ->
            let fields' = List.filter (fun (k, _) -> k <> "author") fields in
            `Assoc (("author", `String author) :: fields')
        | other -> other
      in
      let (ok, msg) = Tool_board.handle_tool "masc_board_comment" board_args in
      if ok then msg else Yojson.Safe.to_string (`Assoc [("error", `String msg)])
  | "keeper_fs_read" | "keeper_read" ->
      let path = Safe_ops.json_string ~default:"" "path" args in
      let max_bytes =
        Safe_ops.json_int ~default:20000 "max_bytes" args
        |> fun n -> max 512 (min 200000 n)
      in
      (match resolve_keeper_target_path ~config ~raw_path:path with
       | Error e ->
           Yojson.Safe.to_string (`Assoc [("error", `String e)])
       | Ok target ->
           (match Safe_ops.read_file_safe target with
            | Error e ->
                Yojson.Safe.to_string (`Assoc [("error", `String e); ("path", `String target)])
            | Ok content ->
                let total = String.length content in
                let truncated = total > max_bytes in
                let body =
                  if truncated then String.sub content 0 max_bytes else content
                in
                Yojson.Safe.to_string
                  (`Assoc [
                    ("ok", `Bool true);
                    ("path", `String target);
                    ("bytes", `Int total);
                    ("truncated", `Bool truncated);
                    ("content", `String body);
                  ])))
  | "keeper_fs_edit" | "keeper_edit" ->
      let path = Safe_ops.json_string ~default:"" "path" args in
      let content = Safe_ops.json_string ~default:"" "content" args in
      let mode =
        Safe_ops.json_string ~default:"overwrite" "mode" args
        |> String.lowercase_ascii
      in
      (match resolve_keeper_target_path ~config ~raw_path:path with
       | Error e ->
           Yojson.Safe.to_string (`Assoc [("error", `String e)])
       | Ok target ->
           (try
              let parent = Filename.dirname target in
              if not (Sys.file_exists parent) then Unix.mkdir parent 0o755;
              (match mode with
               | "append" ->
                   let oc =
                     open_out_gen [Open_wronly; Open_creat; Open_append] 0o644 target
                   in
                   Common.protect
                     ~module_name:"tool_keeper"
                     ~finally_label:"keeper_fs_edit_append_close"
                     ~finally:(fun () -> close_out_noerr oc)
                     (fun () -> output_string oc content)
               | "overwrite" | "" ->
                   let oc = open_out target in
                   Common.protect
                     ~module_name:"tool_keeper"
                     ~finally_label:"keeper_fs_edit_overwrite_close"
                     ~finally:(fun () -> close_out_noerr oc)
                     (fun () -> output_string oc content)
               | other ->
                   raise (Invalid_argument ("unsupported_mode:" ^ other)));
              Yojson.Safe.to_string
                (`Assoc [
                  ("ok", `Bool true);
                  ("path", `String target);
                  ("mode", `String (if mode = "" then "overwrite" else mode));
                  ("bytes_written", `Int (String.length content));
                ])
            with
            | Invalid_argument e ->
                Yojson.Safe.to_string (`Assoc [("error", `String e); ("path", `String target)])
            | Sys_error e ->
                Yojson.Safe.to_string (`Assoc [("error", `String e); ("path", `String target)])
            | Unix.Unix_error (err, _, _) ->
                Yojson.Safe.to_string
                  (`Assoc [
                    ("error", `String (Unix.error_message err));
                    ("path", `String target);
                  ])))
  | "keeper_bash" ->
      let cmd = Safe_ops.json_string ~default:"" "cmd" args |> String.trim in
      let timeout_sec =
        Safe_ops.json_float ~default:30.0 "timeout_sec" args
        |> fun n -> max 1.0 (min 180.0 n)
      in
      if cmd = "" then Yojson.Safe.to_string (`Assoc [("error", `String "cmd_required")])
      else
        let root = project_root_of_config config in
        let shell_cmd =
          Printf.sprintf "cd %s && %s 2>&1" (Filename.quote root) cmd
        in
        let (st, out) =
          Process_eio.run_argv_with_status
            ~timeout_sec
            ["/bin/zsh"; "-lc"; shell_cmd]
        in
        Yojson.Safe.to_string
          (`Assoc [
            ("ok", `Bool (st = Unix.WEXITED 0));
            ("status", process_status_to_json st);
            ("output", `String (truncate_tool_output out));
          ])
  | "keeper_github" ->
      let cmd = Safe_ops.json_string ~default:"" "cmd" args |> String.trim in
      let gh_args = Safe_ops.json_string_list "args" args in
      let timeout_sec =
        Safe_ops.json_float ~default:30.0 "timeout_sec" args
        |> fun n -> max 1.0 (min 180.0 n)
      in
      let gh_cmd =
        if cmd <> "" then "gh " ^ cmd
        else if gh_args <> [] then
          "gh " ^ String.concat " " (List.map Filename.quote gh_args)
        else
          ""
      in
      if gh_cmd = "" then Yojson.Safe.to_string (`Assoc [("error", `String "cmd_or_args_required")])
      else
        let root = project_root_of_config config in
        let shell_cmd =
          Printf.sprintf "cd %s && %s 2>&1" (Filename.quote root) gh_cmd
        in
        let (st, out) =
          Process_eio.run_argv_with_status
            ~timeout_sec
            ["/bin/zsh"; "-lc"; shell_cmd]
        in
        Yojson.Safe.to_string
          (`Assoc [
            ("ok", `Bool (st = Unix.WEXITED 0));
            ("status", process_status_to_json st);
            ("output", `String (truncate_tool_output out));
          ])
  (* Taskboard tools — Board Gardener operations *)
  | "keeper_tasks_list" ->
      let status_filter = Safe_ops.json_string_opt "status" args in
      let include_done = Safe_ops.json_bool ~default:false "include_done" args in
      Room.list_tasks ?status:status_filter ~include_done config
  | "keeper_tasks_audit" ->
      let orphans = Room.audit_orphan_tasks config in
      let items = List.map (fun ((task : Types.task), assignee) ->
        `Assoc [
          ("task_id", `String task.id);
          ("title", `String task.title);
          ("assignee", `String assignee);
          ("status", `String (Types.string_of_task_status task.task_status));
        ]
      ) orphans in
      Yojson.Safe.to_string (`Assoc [
        ("orphan_count", `Int (List.length orphans));
        ("orphans", `List items);
      ])
  | "keeper_task_force_release" ->
      let task_id = Safe_ops.json_string ~default:"" "task_id" args |> String.trim in
      let reason = Safe_ops.json_string ~default:"" "reason" args in
      if task_id = "" then
        Yojson.Safe.to_string (`Assoc [("error", `String "task_id required")])
      else begin
        let agent = Printf.sprintf "gardener:%s" meta.name in
        let _ = Room.broadcast config ~from_agent:agent
            ~content:(Printf.sprintf "Force-releasing task %s (reason: %s)" task_id
              (if reason = "" then "no reason given" else reason)) in
        match Room.force_release_task_r config ~agent_name:agent ~task_id () with
        | Ok msg ->
            Yojson.Safe.to_string (`Assoc [("ok", `Bool true); ("result", `String msg)])
        | Error e ->
            Yojson.Safe.to_string (`Assoc [("ok", `Bool false); ("error", `String (Types.masc_error_to_string e))])
      end
  | "keeper_task_force_done" ->
      let task_id = Safe_ops.json_string ~default:"" "task_id" args |> String.trim in
      let notes = Safe_ops.json_string ~default:"" "notes" args in
      if task_id = "" then
        Yojson.Safe.to_string (`Assoc [("error", `String "task_id required")])
      else begin
        let agent = Printf.sprintf "gardener:%s" meta.name in
        match Room.force_done_task_r config ~agent_name:agent ~task_id ~notes () with
        | Ok msg ->
            Yojson.Safe.to_string (`Assoc [("ok", `Bool true); ("result", `String msg)])
        | Error e ->
            Yojson.Safe.to_string (`Assoc [("ok", `Bool false); ("error", `String (Types.masc_error_to_string e))])
      end
  | "keeper_broadcast" ->
      let message = Safe_ops.json_string ~default:"" "message" args |> String.trim in
      if message = "" then
        Yojson.Safe.to_string (`Assoc [("error", `String "message required")])
      else begin
        let agent = Printf.sprintf "gardener:%s" meta.name in
        let _ = Room.broadcast config ~from_agent:agent ~content:message in
        Yojson.Safe.to_string (`Assoc [("ok", `Bool true); ("broadcast", `String message)])
      end
  | other ->
      Yojson.Safe.to_string (`Assoc [
        ("error", `String "unknown_tool");
        ("tool", `String other);
      ])

(** Build system prompt for tool-loop follow-up calls.
    Includes the agent's identity/character context but strips skill-routing
    instructions that confuse the model into outputting SKILL: prefixes. *)
let keeper_tool_loop_system_prompt ~(character_context : string) : string =
  Printf.sprintf
    "%s\n\n\
     TOOL-LOOP INSTRUCTIONS:\n\
     When you have all the information needed, produce a final text answer.\n\
     When you still need more data or actions, call the appropriate tool.\n\
     Never output SKILL: prefixes. Use function calling only.\n\
     Stay in character when writing content."
    character_context

let keeper_tool_followup_prompt
    ~(user_message : string)
    ~(draft_reply : string)
    ~(tool_outputs : (Llm_client.tool_call * string) list)
    ~(already_executed : string list) : string =
  let rendered =
    tool_outputs
    |> List.map (fun ((tc : Llm_client.tool_call), output) ->
         Printf.sprintf
           "- %s(%s)\n  => %s"
           tc.call_name
           tc.call_arguments
           output)
    |> String.concat "\n"
  in
  let is_write_tool (name : string) : bool =
    List.mem
      name
      [ "keeper_board_post"; "keeper_board_comment"; "keeper_fs_edit"; "keeper_edit";
        "keeper_task_force_release"; "keeper_task_force_done"; "keeper_broadcast" ]
  in
  let has_write =
    List.exists is_write_tool already_executed
  in
  let rules =
    if has_write then
      "RULES (follow strictly):\n\
       You have already posted to the board. ALL required actions are DONE.\n\
       Produce a brief final text answer confirming what you did. Do NOT call any more tools."
    else
      "RULES (follow strictly):\n\
       1. If the user asked you to POST, WRITE, or UPDATE something, you MUST call \
          the appropriate tool (e.g. keeper_board_post). Do NOT return the content as text.\n\
       2. If you still need information, call the appropriate read/list tool.\n\
       3. Only produce a final text answer when ALL required actions (reads AND writes) are done.\n\
       4. Use tool outputs as source of truth.\n\
       5. Reply in user's language and stay concise."
  in
  Printf.sprintf
    "You called tools. Here are the results.\n\n\
     User message: %s\n\
     Draft reply: %s\n\
     Tool results:\n%s\n\
     Previously executed: [%s]\n\n\
     %s\n"
    user_message draft_reply rendered
    (String.concat ", " already_executed)
    rules

let memory_correction_prompt
    ~(user_message : string)
    ~(first_reply : string)
    ~(candidate_user_msgs : string list)
    ~(expected_topic : string option) : string =
  let evidence =
    candidate_user_msgs
    |> List.mapi (fun i msg -> Printf.sprintf "%d) %s" (i + 1) msg)
    |> String.concat "\n"
  in
  let topic_instruction =
    match expected_topic with
    | Some "first_question" ->
        (match List.rev candidate_user_msgs with
         | earliest :: _ ->
             Printf.sprintf
               "- You MUST return the earliest question in the list exactly or near-verbatim: %s\n"
               earliest
         | [] ->
             "- User asked for the first question. Pick the earliest evidence if available.\n")
    | Some "weather" ->
        "- User asked about weather recall. Choose the weather-related question from evidence.\n"
    | _ ->
        "- Choose the single most relevant previous user question from evidence.\n"
  in
  Printf.sprintf
    "Memory correction required.\n\
     User asked: %s\n\
     Your previous answer: %s\n\
     Ground truth previous user questions:\n%s\n\n\
     Rewrite your answer using ONLY this evidence.\n\
     - If uncertain, explicitly say uncertain.\n\
     - Do not invent questions.\n\
     %s\
     - Keep concise.\n"
    user_message first_reply evidence topic_instruction

let memory_forced_grounding_prompt
    ~(user_message : string)
    ~(first_reply : string)
    ~(candidate_user_msgs : string list)
    ~(expected_topic : string option) : string =
  let evidence =
    candidate_user_msgs
    |> List.mapi (fun i msg -> Printf.sprintf "%d) %s" (i + 1) msg)
    |> String.concat "\n"
  in
  let topic_instruction =
    match expected_topic with
    | Some "first_question" ->
        "- Intent: user asked for the first question. Evidence list order is newest->oldest, so choose the LAST evidence line.\n"
    | Some "weather" ->
        "- Intent: user asked about weather. Choose the weather-related evidence line.\n"
    | _ ->
        "- Intent: user asked about previous question. Prefer the most recent evidence unless user asked otherwise.\n"
  in
  Printf.sprintf
    "Strict memory grounding retry.\n\
     User asked: %s\n\
     Your previous answer failed grounding validation: %s\n\
     Evidence (ordered newest to oldest):\n%s\n\n\
     You MUST answer using exactly one evidence line.\n\
     - The first line MUST be the chosen evidence question copied verbatim and wrapped in double quotes.\n\
     - Then add one concise sentence in the user's language.\n\
     - Do not invent or paraphrase the chosen question.\n\
     - Keep [STATE] continuity block at the end.\n\
     %s"
    user_message first_reply evidence topic_instruction

let contains_korean_text (s : string) : bool =
  try
    let _ = Str.search_forward (Str.regexp "[가-힣]") s 0 in
    true
  with Not_found ->
    false

let is_recent_question_query (s : string) : bool =
  let q = String.lowercase_ascii s in
  let has_ko needle =
    try
      let _ = Str.search_forward (Str.regexp_string needle) s 0 in
      true
    with Not_found ->
      false
  in
  let has_en needle =
    try
      let _ = Str.search_forward (Str.regexp_string needle) q 0 in
      true
    with Not_found ->
      false
  in
  has_ko "방금"
  || has_ko "직전"
  || has_ko "바로 전"
  || has_ko "좀 전에"
  || has_ko "전 질문"
  || has_en "just asked"
  || has_en "last question"
  || has_en "previous question"
  || has_en "most recent question"

let has_weather_keyword (s : string) : bool =
  let q = String.lowercase_ascii s in
  (try
     let _ = Str.search_forward (Str.regexp_string "날씨") s 0 in
     true
   with Not_found ->
     false)
  ||
  (try
     let _ = Str.search_forward (Str.regexp_string "weather") q 0 in
     true
   with Not_found ->
     false)

let select_recall_candidate
    ~(user_message : string)
    ~(expected_topic : string option)
    ~(best_match : string option)
    (candidates : string list) : string option =
  let best_match =
    match best_match with
    | Some text ->
        let text = String.trim text in
        if text = "" then None else Some text
    | None -> None
  in
  let most_recent =
    match candidates with
    | c :: _ ->
        let c = String.trim c in
        if c = "" then None else Some c
    | [] -> None
  in
  let oldest =
    match List.rev candidates with
    | c :: _ ->
        let c = String.trim c in
        if c = "" then None else Some c
    | [] -> None
  in
  let weather_candidate =
    match List.find_opt has_weather_keyword candidates with
    | None -> None
    | Some c ->
        let c = String.trim c in
        if c = "" then None else Some c
  in
  match expected_topic with
  | Some "first_question" -> (match oldest with Some _ as x -> x | None -> best_match)
  | Some "weather" ->
      (match weather_candidate with
       | Some _ as x -> x
       | None -> (match best_match with Some _ as x -> x | None -> most_recent))
  | _ ->
      if is_recent_question_query user_message then
        (match most_recent with Some _ as x -> x | None -> best_match)
      else
        (match best_match with Some _ as x -> x | None -> most_recent)

let recall_fallback_reply
    ~(meta : keeper_meta)
    ~(user_message : string)
    ~(selected_question : string)
    ~(expected_topic : string option) : string =
  let ko =
    contains_korean_text user_message || contains_korean_text selected_question
  in
  if ko then
    let lead =
      match expected_topic with
      | Some "first_question" -> "내 기록상 가장 처음 물어본 건 이거야:"
      | Some "weather" -> "내 기록에 남아있는 날씨 관련 질문은 이거야:"
      | _ -> "내 기록 기준으로는, 직전에 이런 질문을 했어:"
    in
    Printf.sprintf
      "%s\n\"%s\"\n\n\
       [STATE]\n\
       Goal: %s\n\
       Progress: 회상 실패 시 저장된 질문 기록으로 자연스럽게 직접 응답\n\
       Next: 필요하면 첫 질문/직전 질문/주제별로 다시 좁혀서 조회\n\
       Decisions: 회상 질의는 추측보다 저장된 사용자 질문 기록 우선\n\
       OpenQuestions: 없음\n\
       Constraints: 저장된 대화 기록 범위 밖으로는 추측하지 않음\n\
       [/STATE]"
      lead selected_question meta.goal
  else
    let lead =
      match expected_topic with
      | Some "first_question" -> "From stored history, your earliest question was:"
      | Some "weather" -> "From stored history, your weather-related question was:"
      | _ -> "From stored history, your previous question was:"
    in
    Printf.sprintf
      "%s\n\"%s\"\n\n\
       [STATE]\n\
       Goal: %s\n\
       Progress: Returned a deterministic recall answer from stored user messages\n\
       Next: Narrow to earliest/most-recent/topic-specific question if needed\n\
       Decisions: For recall queries, prefer stored user-message evidence over generation\n\
       OpenQuestions: none\n\
       Constraints: Do not infer outside stored conversation history\n\
       [/STATE]"
      lead selected_question meta.goal

let deterministic_recall_fallback
    ~(meta : keeper_meta)
    ~(user_message : string)
    ~(eval : memory_recall_eval)
    ~(candidates : string list) : (string * memory_recall_eval) option =
  if (not eval.performed) || eval.passed || eval.candidate_count <= 0 then
    None
  else
    match
      select_recall_candidate
        ~user_message
        ~expected_topic:eval.expected_topic
        ~best_match:eval.best_match
        candidates
    with
    | None -> None
    | Some selected_question ->
        let forced_reply =
          recall_fallback_reply
            ~meta
            ~user_message
            ~selected_question
            ~expected_topic:eval.expected_topic
        in
        let eval2 =
          evaluate_memory_recall
            ~user_message
            ~assistant_reply:forced_reply
            ~candidates
        in
        Some (forced_reply, eval2)

type metrics_summary = {
  sample_points: int;
  turn_points: int;
  heartbeat_points: int;
  proactive_points: int;
  auto_reflect_count: int;
  auto_plan_count: int;
  auto_compact_count: int;
  auto_handoff_count: int;
  guardrail_stop_count: int;
  drift_applied_count: int;
  handoff_count: int;
  compaction_events: int;
  compaction_saved_tokens: int;
  memory_compaction_events: int;
  memory_compaction_before_notes: int;
  memory_compaction_dropped_notes: int;
  memory_compaction_invalid_dropped: int;
  memory_checks: int;
  memory_passed: int;
  memory_failed: int;
  memory_correction_applied: int;
  memory_correction_success: int;
  memory_score_sum: float;
  memory_weather_checks: int;
  memory_weather_passed: int;
  repetition_risk_sum: float;
  repetition_risk_points: int;
  goal_alignment_sum: float;
  goal_alignment_points: int;
  response_alignment_sum: float;
  response_alignment_points: int;
  goal_drift_sum: float;
  goal_drift_points: int;
  last_handoff: Yojson.Safe.t option;
  last_compaction: Yojson.Safe.t option;
}

let empty_metrics_summary = {
  sample_points = 0;
  turn_points = 0;
  heartbeat_points = 0;
  proactive_points = 0;
  auto_reflect_count = 0;
  auto_plan_count = 0;
  auto_compact_count = 0;
  auto_handoff_count = 0;
  guardrail_stop_count = 0;
  drift_applied_count = 0;
  handoff_count = 0;
  compaction_events = 0;
  compaction_saved_tokens = 0;
  memory_compaction_events = 0;
  memory_compaction_before_notes = 0;
  memory_compaction_dropped_notes = 0;
  memory_compaction_invalid_dropped = 0;
  memory_checks = 0;
  memory_passed = 0;
  memory_failed = 0;
  memory_correction_applied = 0;
  memory_correction_success = 0;
  memory_score_sum = 0.0;
  memory_weather_checks = 0;
  memory_weather_passed = 0;
  repetition_risk_sum = 0.0;
  repetition_risk_points = 0;
  goal_alignment_sum = 0.0;
  goal_alignment_points = 0;
  response_alignment_sum = 0.0;
  response_alignment_points = 0;
  goal_drift_sum = 0.0;
  goal_drift_points = 0;
  last_handoff = None;
  last_compaction = None;
}

let metrics_summary_to_json (s : metrics_summary) : Yojson.Safe.t =
  let interaction_points = s.turn_points + s.proactive_points in
  let intervention_share =
    if interaction_points = 0 then 0.0
    else float_of_int s.proactive_points /. float_of_int interaction_points
  in
  let intervention_per_turn =
    if s.turn_points = 0 then 0.0
    else float_of_int s.proactive_points /. float_of_int s.turn_points
  in
  let drift_applied_rate =
    if interaction_points = 0 then 0.0
    else float_of_int s.drift_applied_count /. float_of_int interaction_points
  in
  let auto_reflect_rate =
    if interaction_points = 0 then 0.0
    else float_of_int s.auto_reflect_count /. float_of_int interaction_points
  in
  let auto_plan_rate =
    if interaction_points = 0 then 0.0
    else float_of_int s.auto_plan_count /. float_of_int interaction_points
  in
  let auto_compact_rate =
    if interaction_points = 0 then 0.0
    else float_of_int s.auto_compact_count /. float_of_int interaction_points
  in
  let auto_handoff_rate =
    if interaction_points = 0 then 0.0
    else float_of_int s.auto_handoff_count /. float_of_int interaction_points
  in
  let guardrail_stop_rate =
    if interaction_points = 0 then 0.0
    else float_of_int s.guardrail_stop_count /. float_of_int interaction_points
  in
  let memory_pass_rate =
    if s.memory_checks = 0 then 0.0
    else float_of_int s.memory_passed /. float_of_int s.memory_checks
  in
  let memory_avg_score =
    if s.memory_checks = 0 then 0.0
    else s.memory_score_sum /. float_of_int s.memory_checks
  in
  let memory_weather_pass_rate =
    if s.memory_weather_checks = 0 then 0.0
    else float_of_int s.memory_weather_passed /. float_of_int s.memory_weather_checks
  in
  let memory_compaction_drop_ratio =
    if s.memory_compaction_before_notes = 0 then 0.0
    else
      float_of_int s.memory_compaction_dropped_notes
      /. float_of_int s.memory_compaction_before_notes
  in
  let memory_compaction_drop_avg =
    if s.memory_compaction_events = 0 then 0.0
    else
      float_of_int s.memory_compaction_dropped_notes
      /. float_of_int s.memory_compaction_events
  in
  let repetition_risk_avg =
    if s.repetition_risk_points = 0 then 0.0
    else s.repetition_risk_sum /. float_of_int s.repetition_risk_points
  in
  let goal_alignment_avg =
    if s.goal_alignment_points = 0 then 0.0
    else s.goal_alignment_sum /. float_of_int s.goal_alignment_points
  in
  let response_alignment_avg =
    if s.response_alignment_points = 0 then 0.0
    else s.response_alignment_sum /. float_of_int s.response_alignment_points
  in
  let goal_drift_avg =
    if s.goal_drift_points = 0 then 0.0
    else s.goal_drift_sum /. float_of_int s.goal_drift_points
  in
  `Assoc [
    ("sample_points", `Int s.sample_points);
    ("turn_points", `Int s.turn_points);
    ("heartbeat_points", `Int s.heartbeat_points);
    ("proactive_points", `Int s.proactive_points);
    ("window_interactions", `Int interaction_points);
    ("intervention_share", `Float intervention_share);
    ("intervention_per_turn", `Float intervention_per_turn);
    ("auto_reflect_count", `Int s.auto_reflect_count);
    ("auto_plan_count", `Int s.auto_plan_count);
    ("auto_compact_count", `Int s.auto_compact_count);
    ("auto_handoff_count", `Int s.auto_handoff_count);
    ("guardrail_stop_count", `Int s.guardrail_stop_count);
    ("auto_reflect_rate", `Float auto_reflect_rate);
    ("auto_plan_rate", `Float auto_plan_rate);
    ("auto_compact_rate", `Float auto_compact_rate);
    ("auto_handoff_rate", `Float auto_handoff_rate);
    ("guardrail_stop_rate", `Float guardrail_stop_rate);
    ("drift_applied_count", `Int s.drift_applied_count);
    ("drift_applied_rate", `Float drift_applied_rate);
    ("handoff_count", `Int s.handoff_count);
    ("compaction_events", `Int s.compaction_events);
    ("compaction_saved_tokens", `Int s.compaction_saved_tokens);
    ("memory_compaction_events", `Int s.memory_compaction_events);
    ("memory_compaction_before_notes", `Int s.memory_compaction_before_notes);
    ("memory_compaction_dropped_notes", `Int s.memory_compaction_dropped_notes);
    ("memory_compaction_invalid_dropped", `Int s.memory_compaction_invalid_dropped);
    ("memory_compaction_drop_ratio", `Float memory_compaction_drop_ratio);
    ("memory_compaction_drop_avg", `Float memory_compaction_drop_avg);
    ("memory_checks", `Int s.memory_checks);
    ("memory_passed", `Int s.memory_passed);
    ("memory_failed", `Int s.memory_failed);
    ("memory_pass_rate", `Float memory_pass_rate);
    ("memory_avg_score", `Float memory_avg_score);
    ("memory_correction_applied", `Int s.memory_correction_applied);
    ("memory_correction_success", `Int s.memory_correction_success);
    ("memory_weather_checks", `Int s.memory_weather_checks);
    ("memory_weather_passed", `Int s.memory_weather_passed);
    ("memory_weather_pass_rate", `Float memory_weather_pass_rate);
    ("repetition_risk_avg", `Float repetition_risk_avg);
    ("goal_alignment_avg", `Float goal_alignment_avg);
    ("response_alignment_avg", `Float response_alignment_avg);
    ("goal_drift_avg", `Float goal_drift_avg);
    ("last_handoff", match s.last_handoff with Some j -> j | None -> `Null);
    ("last_compaction", match s.last_compaction with Some j -> j | None -> `Null);
  ]

let summarize_metrics_lines (lines : string list) ~(default_generation : int) : metrics_summary =
  let open Yojson.Safe.Util in
  List.fold_left (fun acc line ->
    try
      let j = Yojson.Safe.from_string line in
      let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" j in
      let trace_id = Safe_ops.json_string ~default:"" "trace_id" j in
      let generation = Safe_ops.json_int ~default:default_generation "generation" j in
      let channel = Safe_ops.json_string ~default:"turn" "channel" j in
      let is_turn = channel = "turn" in
      let is_heartbeat = channel = "heartbeat" in
      let is_proactive = channel = "proactive" in
      let is_interaction = is_turn || is_proactive in
      let compacted = Safe_ops.json_bool ~default:false "compacted" j in
      let before_tokens = Safe_ops.json_int ~default:0 "compaction_before_tokens" j in
      let after_tokens = Safe_ops.json_int ~default:0 "compaction_after_tokens" j in
      let saved_tokens = max 0 (before_tokens - after_tokens) in
      let handoff = j |> member "handoff" in
      let handoff_performed = Safe_ops.json_bool ~default:false "performed" handoff in
      let to_model = Safe_ops.json_string_opt "to_model" handoff in
      let prev_trace_id = Safe_ops.json_string_opt "prev_trace_id" handoff in
      let new_trace_id = Safe_ops.json_string_opt "new_trace_id" handoff in
      let memory = j |> member "memory_check" in
      let memory_performed = Safe_ops.json_bool ~default:false "performed" memory in
      let memory_passed = Safe_ops.json_bool ~default:false "passed" memory in
      let memory_final_score = Safe_ops.json_float ~default:0.0 "final_score" memory in
      let memory_correction_applied =
        Safe_ops.json_bool ~default:false "correction_applied" memory
      in
      let memory_correction_success =
        Safe_ops.json_bool ~default:false "correction_success" memory
      in
      let memory_expected_topic = Safe_ops.json_string_opt "expected_topic" memory in
      let memory_compaction_performed =
        Safe_ops.json_bool ~default:false "memory_compaction_performed" j
      in
      let memory_compaction_before_now =
        Safe_ops.json_int ~default:0 "memory_compaction_before_notes" j
      in
      let memory_compaction_dropped_now =
        Safe_ops.json_int ~default:0 "memory_compaction_dropped_notes" j
      in
      let memory_compaction_invalid_now =
        Safe_ops.json_int ~default:0 "memory_compaction_invalid_dropped" j
      in
      let drift =
        j |> member "drift"
      in
      let drift_applied_now =
        Safe_ops.json_bool ~default:false "applied" drift
      in
      let memory_is_weather =
        match memory_expected_topic with Some "weather" -> true | _ -> false
      in
      let auto_rules = j |> member "auto_rules" in
      let auto_reflect_now =
        Safe_ops.json_bool
          ~default:(Safe_ops.json_bool ~default:false "reflect" auto_rules)
          "auto_reflect"
          j
      in
      let auto_plan_now =
        Safe_ops.json_bool
          ~default:(Safe_ops.json_bool ~default:false "plan" auto_rules)
          "auto_plan"
          j
      in
      let auto_compact_now =
        Safe_ops.json_bool
          ~default:(Safe_ops.json_bool ~default:false "compact" auto_rules)
          "auto_compact"
          j
      in
      let auto_handoff_now =
        Safe_ops.json_bool
          ~default:(Safe_ops.json_bool ~default:false "handoff" auto_rules)
          "auto_handoff"
          j
      in
      let guardrail_stop_now =
        Safe_ops.json_bool
          ~default:(Safe_ops.json_bool ~default:false "guardrail_stop" auto_rules)
          "guardrail_stop"
          j
      in
      let repetition_risk_opt = Safe_ops.json_float_opt "repetition_risk" j in
      let goal_alignment_opt = Safe_ops.json_float_opt "goal_alignment" j in
      let response_alignment_opt = Safe_ops.json_float_opt "response_alignment" j in
      let goal_drift_opt = Safe_ops.json_float_opt "goal_drift" j in
      let handoff_json =
        if handoff_performed then
          Some (`Assoc [
            ("ts_unix", `Float ts_unix);
            ("trace_id", `String trace_id);
            ("generation", `Int generation);
            ("to_model", match to_model with Some s when s <> "" -> `String s | _ -> `Null);
            ("prev_trace_id", match prev_trace_id with Some s when s <> "" -> `String s | _ -> `Null);
            ("new_trace_id", match new_trace_id with Some s when s <> "" -> `String s | _ -> `Null);
          ])
        else
          acc.last_handoff
      in
      let compaction_json =
        if compacted then
          let trigger =
            Safe_ops.json_string_opt "compaction_trigger" j
          in
          Some (`Assoc [
            ("ts_unix", `Float ts_unix);
            ("trace_id", `String trace_id);
            ("generation", `Int generation);
            ("before_tokens", `Int before_tokens);
            ("after_tokens", `Int after_tokens);
            ("saved_tokens", `Int saved_tokens);
            ( "trigger",
              match trigger with
              | Some reason when String.trim reason <> "" -> `String reason
              | _ -> `Null );
          ])
        else
          acc.last_compaction
      in
      {
        sample_points = acc.sample_points + 1;
        turn_points = acc.turn_points + (if is_turn then 1 else 0);
        heartbeat_points = acc.heartbeat_points + (if is_heartbeat then 1 else 0);
        proactive_points = acc.proactive_points + (if is_proactive then 1 else 0);
        auto_reflect_count =
          acc.auto_reflect_count + (if is_interaction && auto_reflect_now then 1 else 0);
        auto_plan_count =
          acc.auto_plan_count + (if is_interaction && auto_plan_now then 1 else 0);
        auto_compact_count =
          acc.auto_compact_count + (if is_interaction && auto_compact_now then 1 else 0);
        auto_handoff_count =
          acc.auto_handoff_count + (if is_interaction && auto_handoff_now then 1 else 0);
        guardrail_stop_count =
          acc.guardrail_stop_count + (if is_interaction && guardrail_stop_now then 1 else 0);
        drift_applied_count =
          acc.drift_applied_count + (if is_interaction && drift_applied_now then 1 else 0);
        handoff_count = acc.handoff_count + (if is_interaction && handoff_performed then 1 else 0);
        compaction_events = acc.compaction_events + (if is_interaction && compacted then 1 else 0);
        compaction_saved_tokens =
          acc.compaction_saved_tokens + (if is_interaction && compacted then saved_tokens else 0);
        memory_compaction_events =
          acc.memory_compaction_events
          + (if is_interaction && memory_compaction_performed then 1 else 0);
        memory_compaction_before_notes =
          acc.memory_compaction_before_notes
          + (if is_interaction && memory_compaction_performed then memory_compaction_before_now else 0);
        memory_compaction_dropped_notes =
          acc.memory_compaction_dropped_notes
          + (if is_interaction && memory_compaction_performed then memory_compaction_dropped_now else 0);
        memory_compaction_invalid_dropped =
          acc.memory_compaction_invalid_dropped
          + (if is_interaction && memory_compaction_performed then memory_compaction_invalid_now else 0);
        memory_checks = acc.memory_checks + (if is_interaction && memory_performed then 1 else 0);
        memory_passed =
          acc.memory_passed + (if is_interaction && memory_performed && memory_passed then 1 else 0);
        memory_failed =
          acc.memory_failed + (if is_interaction && memory_performed && not memory_passed then 1 else 0);
        memory_correction_applied =
          acc.memory_correction_applied
          + (if is_interaction && memory_performed && memory_correction_applied then 1 else 0);
        memory_correction_success =
          acc.memory_correction_success
          + (if is_interaction && memory_performed && memory_correction_success then 1 else 0);
        memory_score_sum =
          acc.memory_score_sum
          +. (if is_interaction && memory_performed then memory_final_score else 0.0);
        memory_weather_checks =
          acc.memory_weather_checks
          + (if is_interaction && memory_performed && memory_is_weather then 1 else 0);
        memory_weather_passed =
          acc.memory_weather_passed
          + (if is_interaction && memory_performed && memory_is_weather && memory_passed then 1 else 0);
        repetition_risk_sum =
          acc.repetition_risk_sum
          +. (match repetition_risk_opt with Some v -> v | None -> 0.0);
        repetition_risk_points =
          acc.repetition_risk_points
          + (if Option.is_some repetition_risk_opt then 1 else 0);
        goal_alignment_sum =
          acc.goal_alignment_sum
          +. (match goal_alignment_opt with Some v -> v | None -> 0.0);
        goal_alignment_points =
          acc.goal_alignment_points
          + (if Option.is_some goal_alignment_opt then 1 else 0);
        response_alignment_sum =
          acc.response_alignment_sum
          +. (if is_interaction then Option.value ~default:0.0 response_alignment_opt else 0.0);
        response_alignment_points =
          acc.response_alignment_points
          + (if is_interaction && Option.is_some response_alignment_opt then 1 else 0);
        goal_drift_sum =
          acc.goal_drift_sum
          +. (if is_interaction then Option.value ~default:0.0 goal_drift_opt else 0.0);
        goal_drift_points =
          acc.goal_drift_points
          + (if is_interaction && Option.is_some goal_drift_opt then 1 else 0);
        last_handoff = handoff_json;
        last_compaction = compaction_json;
      }
    with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ ->
      acc
  ) empty_metrics_summary lines

let active_model_of_meta (m : keeper_meta) : string =
  if m.last_model_used <> "" then m.last_model_used
  else
    match m.models with
    | model :: _ -> model
    | [] -> ""

let next_model_hint_of_meta (m : keeper_meta) : string option =
  match m.models with
  | _current :: next_model :: _ -> Some next_model
  | current :: [] -> Some current
  | [] -> None

let parse_agent_status (config : Room.config) ~(agent_name : string) : Yojson.Safe.t =
  let agent_file =
    Filename.concat (Room.agents_dir config) (Room.safe_filename agent_name ^ ".json")
  in
  if not (Sys.file_exists agent_file) then
    `Assoc [("exists", `Bool false)]
  else
    match Safe_ops.read_json_file_safe agent_file with
    | Error _ -> `Assoc [("exists", `Bool true); ("error", `String "failed_to_read")]
    | Ok json ->
      (match Types.agent_of_yojson json with
       | Error _ -> `Assoc [("exists", `Bool true); ("error", `String "failed_to_parse")]
       | Ok (agent : Types.agent) ->
         let now_ts = Time_compat.now () in
         let joined_ts = Resilience.Time.parse_iso8601_opt agent.joined_at |> Option.value ~default:0.0 in
         let last_seen_ts = Resilience.Time.parse_iso8601_opt agent.last_seen |> Option.value ~default:0.0 in
         let age_s = if joined_ts <= 0.0 then 0.0 else now_ts -. joined_ts in
         let last_seen_ago_s = if last_seen_ts <= 0.0 then 0.0 else now_ts -. last_seen_ts in
         `Assoc [
           ("exists", `Bool true);
           ("name", `String agent.name);
           ("agent_type", `String agent.agent_type);
           ("status", `String (Types.string_of_agent_status agent.status));
           ("capabilities", `List (List.map (fun s -> `String s) agent.capabilities));
           ("current_task", match agent.current_task with None -> `Null | Some t -> `String t);
           ("joined_at", `String agent.joined_at);
           ("last_seen", `String agent.last_seen);
           ("age_s", `Float age_s);
           ("last_seen_ago_s", `Float last_seen_ago_s);
           ("is_zombie", `Bool (Room.is_zombie_agent agent.last_seen));
         ])

let json_string_opt key json =
  match Yojson.Safe.Util.member key json with
  | `String s ->
      let trimmed = String.trim s in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let json_bool key json default =
  match Yojson.Safe.Util.member key json with
  | `Bool value -> value
  | _ -> default

let json_float_opt key json =
  match Yojson.Safe.Util.member key json with
  | `Float value -> Some value
  | `Int value -> Some (float_of_int value)
  | _ -> None

let string_contains_ci haystack needle =
  let haystack = String.lowercase_ascii haystack in
  let needle = String.lowercase_ascii needle in
  needle <> "" && contains_ci haystack needle

let quiet_hours_active () =
  let current_hour = Lodge_heartbeat.current_hour_kst () in
  let quiet_start = Env_config.LodgeV2.quiet_start in
  let quiet_end = Env_config.LodgeV2.quiet_end in
  quiet_start < quiet_end
  && current_hour >= quiet_start
  && current_hour < quiet_end

let keeper_reply_snapshot_of_history (history_items : Yojson.Safe.t list) =
  let open Yojson.Safe.Util in
  let normalize_content item =
    match json_string_opt "content" item with
    | Some value -> value
    | None -> Option.value ~default:"" (json_string_opt "preview" item)
  in
  let update_last role ts content ((last_user, last_assistant) as acc) =
    let role = String.lowercase_ascii role in
    if role = "user" then
      (Some (ts, content), last_assistant)
    else if role = "assistant" then
      (last_user, Some (ts, content))
    else
      acc
  in
  let (last_user, last_assistant) =
    List.fold_left
      (fun acc item ->
        match item with
        | `Assoc _ ->
            let role = item |> member "role" |> to_string_option in
            let ts_unix =
              match json_float_opt "ts_unix" item with
              | Some ts when ts > 0.0 -> Some ts
              | _ -> json_float_opt "timestamp" item
            in
            let content = normalize_content item in
            (match role, ts_unix with
             | Some role, Some ts -> update_last role ts content acc
             | _ -> acc)
        | _ -> acc)
      (None, None)
      history_items
  in
  match last_user, last_assistant with
  | None, None ->
      (`String "never", `Null, `Null)
  | Some (user_ts, _), Some (assistant_ts, preview) when assistant_ts >= user_ts ->
      (`String "delivered", `Float assistant_ts, `String preview)
  | Some _, Some (assistant_ts, preview) ->
      (`String "delivered", `Float assistant_ts, `String preview)
  | Some _, None ->
      (`String "awaiting_reply", `Null, `Null)
  | None, Some (assistant_ts, preview) ->
      (`String "delivered", `Float assistant_ts, `String preview)

let keeper_error_hint ~agent_status ~meta =
  let agent_error = json_string_opt "error" agent_status in
  let proactive_reason =
    let reason = String.trim meta.last_proactive_reason in
    if reason = "" then None else Some reason
  in
  let drift_reason =
    let reason = String.trim meta.last_drift_reason in
    if reason = "" then None else Some reason
  in
  let looks_error_like text =
    List.exists (string_contains_ci text)
      [ "error"; "failed"; "timeout"; "graphql"; "llm"; "model"; "ollama"; "gemini"; "openai" ]
  in
  match agent_error with
  | Some _ as error -> error
  | None ->
      (match proactive_reason with
       | Some reason when looks_error_like reason -> Some reason
       | _ ->
           match drift_reason with
           | Some reason when looks_error_like reason -> Some reason
           | _ -> None)

let classify_keeper_quiet_reason ~meta ~keepalive_running ~agent_status ~now_ts =
  let quiet_active = quiet_hours_active () in
  let agent_exists = json_bool "exists" agent_status false in
  let agent_status_text =
    json_string_opt "status" agent_status
    |> Option.value ~default:"unknown"
    |> String.lowercase_ascii
  in
  let error_hint = keeper_error_hint ~agent_status ~meta in
  if not keepalive_running || not agent_exists || agent_status_text = "offline" || agent_status_text = "inactive" then
    Some "disabled"
  else if meta.total_turns = 0 && meta.proactive_count_total = 0 then
    let keeper_age_s =
      match Resilience.Time.parse_iso8601_opt meta.created_at with
      | Some created_ts when created_ts > 0.0 -> max 0.0 (now_ts -. created_ts)
      | _ -> 0.0
    in
    if keeper_age_s <= 120.0 then Some "startup" else Some "never_started"
  else if quiet_active then
    Some "quiet_hours"
  else
    match error_hint with
    | Some reason when string_contains_ci reason "graphql" -> Some "graphql_error"
    | Some reason
      when List.exists (string_contains_ci reason)
             [ "llm"; "model"; "timeout"; "ollama"; "gemini"; "openai" ] ->
        Some "llm_error"
    | Some _ -> Some "unknown"
    | None ->
        let last_turn_ago_s =
          if meta.last_turn_ts <= 0.0 then None else Some (max 0.0 (now_ts -. meta.last_turn_ts))
        in
        let last_proactive_ago_s =
          if meta.last_proactive_ts <= 0.0 then None
          else Some (max 0.0 (now_ts -. meta.last_proactive_ts))
        in
        if meta.proactive_enabled then
          match last_proactive_ago_s with
          | Some age when age < float_of_int meta.proactive_cooldown_sec -> Some "min_gap"
          | _ ->
              (match last_turn_ago_s with
               | Some age when age < float_of_int meta.proactive_idle_sec -> Some "no_recent_activity"
               | _ -> None)
        else
          None

let keeper_health_state ~meta ~keepalive_running ~agent_status ~quiet_reason ~now_ts =
  let agent_exists = json_bool "exists" agent_status false in
  let agent_status_text =
    json_string_opt "status" agent_status
    |> Option.value ~default:"unknown"
    |> String.lowercase_ascii
  in
  let last_seen_ago_s = json_float_opt "last_seen_ago_s" agent_status |> Option.value ~default:max_float in
  let is_zombie = json_bool "is_zombie" agent_status false in
  let stale_threshold_s =
    float_of_int (max 120 (meta.presence_keepalive_sec * 4))
  in
  let last_turn_ago_s =
    if meta.last_turn_ts <= 0.0 then max_float else max 0.0 (now_ts -. meta.last_turn_ts)
  in
  if not keepalive_running || not agent_exists || agent_status_text = "offline" || agent_status_text = "inactive" then
    "offline"
  else if is_zombie || last_seen_ago_s > stale_threshold_s then
    "stale"
  else
    match quiet_reason with
    | Some "graphql_error" | Some "llm_error" -> "degraded"
    | _ ->
        if meta.total_turns = 0 && meta.proactive_count_total = 0 then
          "idle"
        else if last_turn_ago_s > float_of_int (max meta.proactive_idle_sec 900) then
          "idle"
        else
          "healthy"

let keeper_next_action_path ~health_state ~quiet_reason =
  match health_state with
  | "offline" | "stale" | "degraded" -> "recover"
  | _ ->
      (match quiet_reason with
       | Some "quiet_hours" -> "manual_lodge_poke"
       | Some "graphql_error" | Some "llm_error" | Some "startup" | Some "unknown" -> "probe"
       | Some "disabled" -> "recover"
       | _ -> "direct_message")

let keeper_next_eligible_at_s ~meta ~quiet_reason ~now_ts =
  match quiet_reason with
  | Some "min_gap" when meta.last_proactive_ts > 0.0 ->
      let remaining =
        float_of_int meta.proactive_cooldown_sec -. (now_ts -. meta.last_proactive_ts)
      in
      if remaining > 0.0 then `Float remaining else `Null
  | _ -> `Null

let keeper_diagnostic_summary ~health_state ~quiet_reason =
  match health_state with
  | "offline" | "stale" | "degraded" ->
      "Keeper is not in a healthy reply state. Probe or recover before relying on automation."
  | _ ->
      (match quiet_reason with
       | Some "quiet_hours" ->
           "Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep."
       | Some "min_gap" ->
           "Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait."
       | Some "never_started" ->
           "Keeper metadata exists but no reply turn has been recorded yet."
       | _ -> "Keeper is reachable. Send a direct message for an immediate response.")

let keeper_diagnostic_json
    ~(meta : keeper_meta)
    ~(agent_status : Yojson.Safe.t)
    ~(keepalive_running : bool)
    ~(history_items : Yojson.Safe.t list)
    ~(now_ts : float) : Yojson.Safe.t =
  let quiet_reason = classify_keeper_quiet_reason ~meta ~keepalive_running ~agent_status ~now_ts in
  let health_state =
    keeper_health_state ~meta ~keepalive_running ~agent_status ~quiet_reason ~now_ts
  in
  let next_action_path = keeper_next_action_path ~health_state ~quiet_reason in
  let (last_reply_status, last_reply_at, last_reply_preview) =
    keeper_reply_snapshot_of_history history_items
  in
  let last_error =
    match keeper_error_hint ~agent_status ~meta with
    | Some reason -> `String reason
    | None -> `Null
  in
  `Assoc
    [
      ("health_state", `String health_state);
      ( "quiet_reason",
        match quiet_reason with Some reason -> `String reason | None -> `Null );
      ("next_action_path", `String next_action_path);
      ("recoverable", `Bool (String.equal next_action_path "recover"));
      ("summary", `String (keeper_diagnostic_summary ~health_state ~quiet_reason));
      ("last_reply_status", last_reply_status);
      ("last_reply_at", last_reply_at);
      ("last_reply_preview", last_reply_preview);
      ("last_error", last_error);
      ("keepalive_running", `Bool keepalive_running);
      ("next_eligible_at_s", keeper_next_eligible_at_s ~meta ~quiet_reason ~now_ts);
    ]

let keeper_constitution =
  "Continuity rules:\n\
   - This conversation may be compacted/summarized and handed off to a successor.\n\
   - You MUST preserve continuity by emitting a stable state block at the end of each reply.\n\
   - The state block is used for compaction/handoff. Do not include secrets.\n\
   - Reply in the user's language. Keep the main reply concise.\n\
   - Do not output [GOAL_COMPLETE] unless explicitly requested.\n\
   \n\
   State block template (must use these exact markers):\n\
   [STATE]\n\
   Goal: <short>\n\
   Progress: <short>\n\
   Next: <0-3 items separated by ';'>\n\
   Decisions: <0-3 items separated by ';'>\n\
   OpenQuestions: <0-3 items separated by ';'>\n\
   Constraints: <0-3 items separated by ';'>\n\
   [/STATE]\n"

let build_keeper_system_prompt
    ~goal
    ~short_goal
    ~mid_goal
    ~long_goal
    ~soul_profile
    ~will
    ~needs
    ~desires
    ~instructions =
  let profile =
    canonical_soul_profile soul_profile |> Option.value ~default:default_soul_profile
  in
  let goal = normalize_goal_horizon_text goal in
  let (short_goal, mid_goal, long_goal) =
    resolve_goal_horizons
      ~goal
      ~short_goal_opt:(Some short_goal)
      ~mid_goal_opt:(Some mid_goal)
      ~long_goal_opt:(Some long_goal)
  in
  let profile_policy = soul_profile_policy profile in
  let will =
    let s = normalize_self_model_text will in
    if s = "" then "Maintain coherent identity and goal continuity." else s
  in
  let needs =
    let s = normalize_self_model_text needs in
    if s = "" then "Reliable context continuity, factual grounding, and explicit next steps." else s
  in
  let desires =
    let s = normalize_self_model_text desires in
    if s = "" then "Make progress that is observable and useful to the user." else s
  in
  let custom =
    let s = String.trim instructions in
    if s = "" then ""
    else Printf.sprintf "\nCustom instructions:\n%s\n" s
  in
  Printf.sprintf
    "You are a keeper agent with persistent memory.\n\
     Goal: %s\n\
     Goal horizons:\n\
     - Short: %s\n\
     - Mid: %s\n\
     - Long: %s\n\
     \n\
     Tool guidance:\n\
     - You can call tools for time/context/memory/weather checks.\n\
     - Prefer tools when user asks for factual current status or memory lookup evidence.\n\
     - After tool use, answer with concise, grounded statements.\n\
     \n\
     Self model:\n\
     - Will: %s\n\
     - Needs: %s\n\
     - Desires: %s\n\
     \n\
     %s\n\
     \n\
    %s\
    %s"
    goal short_goal mid_goal long_goal will needs desires profile_policy keeper_constitution custom

let append_trait_clause ~(base : string) ~(clause : string) : string =
  let b = String.trim base in
  let c = String.trim clause in
  if c = "" then b
  else if b = "" then c
  else if contains_ci b c then b
  else Printf.sprintf "%s; %s" b c

let apply_self_model_drift
    ~(meta : keeper_meta)
    ~(user_message : string)
    ~(work_kind : string) : keeper_meta * bool * string option =
  if not meta.drift_enabled then (meta, false, None)
  else if String.trim user_message = "" then (meta, false, None)
  else if work_kind <> "general_chat" && work_kind <> "memory_recall" then (meta, false, None)
  else
    let turn_gap = meta.total_turns - meta.last_drift_turn in
    if turn_gap < meta.drift_min_turn_gap then
      (meta, false, None)
    else
      let msg = String.lowercase_ascii user_message in
      let has_any keywords =
        List.exists (fun kw -> contains_ci msg kw) keywords
      in
      let relationship_flag =
        has_any
          [ "연애"; "관계"; "감정"; "사람"; "호감"; "불호"; "신뢰"; "친밀"; "친구";
            "relationship"; "emotion"; "trust"; "liking"; "dislike" ]
      in
      let safety_flag =
        has_any
          [ "위험"; "리스크"; "장애"; "실패"; "사고"; "롤백"; "incident"; "risk";
            "failure"; "rollback"; "outage" ]
      in
      let delivery_flag =
        has_any
          [ "실행"; "마감"; "배포"; "완료"; "일정"; "ship"; "deliver"; "deadline";
            "execute" ]
      in
      let memory_flag =
        has_any
          [ "기억"; "메모"; "승계"; "핸드오프"; "컴팩팅"; "memory"; "handoff";
            "compaction"; "context" ]
      in
      let conflict_flag =
        has_any
          [ "갈등"; "충돌"; "싸움"; "비난"; "불편"; "conflict"; "fight"; "blame" ]
      in
      if not (relationship_flag || safety_flag || delivery_flag || memory_flag || conflict_flag) then
        (meta, false, None)
      else
        let will' =
          meta.will
          |> (fun v ->
                if safety_flag
                then append_trait_clause ~base:v ~clause:"불확실성이 커지면 즉시 보수 모드로 전환한다."
                else v)
          |> (fun v ->
                if conflict_flag
                then append_trait_clause ~base:v ~clause:"갈등 상황에서는 해석보다 사실 확인과 경계선 선언을 먼저 수행한다."
                else v)
          |> compact_self_model_text
        in
        let needs' =
          meta.needs
          |> (fun v ->
                if relationship_flag
                then append_trait_clause ~base:v ~clause:"관계의 비대칭, 감정 신호, 실제 사실을 분리 기록한다."
                else v)
          |> (fun v ->
                if memory_flag
                then append_trait_clause ~base:v ~clause:"기억 항목은 사실/해석/결정을 분리해 보존한다."
                else v)
          |> compact_self_model_text
        in
        let desires' =
          meta.desires
          |> (fun v ->
                if delivery_flag
                then append_trait_clause ~base:v ~clause:"다음 행동을 책임/기한/검증 기준과 함께 즉시 고정한다."
                else v)
          |> (fun v ->
                if relationship_flag
                then append_trait_clause ~base:v ~clause:"관계를 해치지 않으면서도 핵심을 말하는 문장을 우선 선택한다."
                else v)
          |> compact_self_model_text
        in
        if will' = meta.will && needs' = meta.needs && desires' = meta.desires then
          (meta, false, None)
        else
          let tags =
            []
            |> (fun xs -> if relationship_flag then "relationship" :: xs else xs)
            |> (fun xs -> if safety_flag then "safety" :: xs else xs)
            |> (fun xs -> if delivery_flag then "delivery" :: xs else xs)
            |> (fun xs -> if memory_flag then "memory" :: xs else xs)
            |> (fun xs -> if conflict_flag then "conflict" :: xs else xs)
            |> List.rev
          in
          let reason =
            Printf.sprintf
              "auto-drift(turn=%d,gap=%d,tags=%s)"
              meta.total_turns
              turn_gap
              (String.concat "," tags)
          in
          ( { meta with
              will = will';
              needs = needs';
              desires = desires';
              drift_count_total = meta.drift_count_total + 1;
              last_drift_turn = meta.total_turns;
              last_drift_reason = reason;
              updated_at = now_iso ();
            },
            true,
            Some reason )

let load_context_from_checkpoint ~trace_id ~primary_model_max_tokens ~base_dir =
  let session = Context_manager.create_session ~session_id:trace_id ~base_dir in
  let latest_ckpt =
    try Context_manager.load_latest_checkpoint session
    with ex ->
      Printf.eprintf
        "[keeper:%s] checkpoint load failed: %s\n%!"
        trace_id
        (Printexc.to_string ex);
      None
  in
  match latest_ckpt with
  | None -> (session, None)
  | Some ckpt ->
    (try
       let ctx =
         Context_manager.restore_checkpoint
           ckpt
           ~max_tokens:primary_model_max_tokens
       in
       (session, Some ctx)
     with ex ->
       Printf.eprintf
         "[keeper:%s] checkpoint restore failed: %s\n%!"
         trace_id
         (Printexc.to_string ex);
       (session, None))

let save_checkpoint session (ctx : Context_manager.working_context) ~generation =
  let ckpt = Context_manager.create_checkpoint ctx ~generation in
  Context_manager.save_checkpoint session ckpt;
  ckpt

let compaction_policy_of_keeper (meta : keeper_meta) : float * int * int =
  ( meta.compaction_ratio_gate,
    meta.compaction_message_gate,
    meta.compaction_token_gate )

let compact_if_needed
    ~(meta : keeper_meta)
    ~(now_ts : float)
    (ctx : Context_manager.working_context) :
    Context_manager.working_context * string option * string =
  let ratio = Context_manager.context_ratio ctx in
  let message_count = List.length ctx.messages in
  let token_count = ctx.token_count in
  let (ratio_gate, message_gate, token_gate) = compaction_policy_of_keeper meta in
  let cooldown = Float.of_int meta.continuity_compaction_cooldown_sec in
  let last_reflection_ts = max meta.last_continuity_update_ts meta.last_proactive_ts in
  let reflection_ready =
    last_reflection_ts > 0.0 && now_ts -. last_reflection_ts >= cooldown
  in
  let hold_s =
    if cooldown <= 0.0 then
      0.0
    else if last_reflection_ts <= 0.0 then
      Float.of_int meta.continuity_compaction_cooldown_sec
    else
      max
        0.0
        (Float.of_int meta.continuity_compaction_cooldown_sec -. (now_ts -. last_reflection_ts))
  in
  let trigger_reason =
    if not reflection_ready then
      Some
        (Printf.sprintf
           "skipped:continuity_reflection(%0.0fs<%ds)"
           hold_s
           meta.continuity_compaction_cooldown_sec)
    else if ratio >= ratio_gate then
      Some
        (Printf.sprintf
           "ratio(%.4f>=%.4f)"
           ratio
           ratio_gate)
    else if message_gate > 0 && message_count >= message_gate then
      Some
        (Printf.sprintf
           "messages(%d>=%d)"
           message_count
           message_gate)
    else if token_gate > 0 && token_count >= token_gate then
      Some
        (Printf.sprintf
           "tokens(%d>=%d)"
           token_count
           token_gate)
    else
      None
  in
  match trigger_reason with
  | None -> (ctx, None, "blocked:below_thresholds")
  | Some reason ->
      if String.starts_with ~prefix:"skipped:" reason then
        (ctx, None, reason)
      else
      let compacted_ctx =
        Context_manager.compact
          ctx
          Context_manager.[PruneToolOutputs; MergeContiguous; DropLowImportance; SummarizeOld]
      in
      (compacted_ctx, Some reason, "applied:" ^ reason)

let generate_trace_id () =
  let ts = int_of_float (Time_compat.now () *. 1000.0) in
  let rnd = Random.int 99999 in
  Printf.sprintf "trace-%d-%05d" ts rnd

let proactive_prompt_for_keeper
    ~(meta : keeper_meta)
    ~(idle_seconds : int)
    (snapshot : keeper_state_snapshot option)
    (continuity_summary : string) : string =
  let seed = proactive_seed_for_soul_profile meta.soul_profile in
  let profile =
    canonical_soul_profile meta.soul_profile
    |> Option.value ~default:default_soul_profile
  in
  let last_preview =
    if String.trim meta.last_proactive_preview = "" then "none"
    else meta.last_proactive_preview
  in
  let continuity_snapshot =
    match snapshot with
    | None -> "No continuity snapshot available."
    | Some s -> keeper_state_snapshot_to_summary_text s
  in
  let continuity_snapshot =
    if continuity_snapshot = "No continuity snapshot available." then
      let fallback = String.trim continuity_summary in
      if fallback = "" then continuity_snapshot else fallback
    else continuity_snapshot
  in
  Printf.sprintf
    "Autonomous proactive turn (no new user message) after %d seconds idle.\n\
     Keeper SOUL profile: %s.\n\
     Goal: %s\n\
     Last proactive preview (avoid repeating): %s\n\
     Continuity snapshot:\n%s\n\
     SOUL perspective hint: %s\n\
     Guidance (strict):\n\
     - Prefer the same language as the recent conversation.\n\
     - Avoid repeating the previous proactive message verbatim.\n\
     - Keep it concise and useful for the current goal.\n\
     - If external checks or actions are needed, call tools before finalizing.\n\
     - When a required write action is identified, execute it via tools and then summarize.\n\
     - For this proactive turn only, do NOT output [STATE] blocks.\n\
     - Output exactly one line using this format:\n\
       CHECKIN: <single complete sentence ending with punctuation>"
    idle_seconds profile meta.goal last_preview continuity_snapshot seed

type proactive_generation_result = {
  reply: string;
  usage: Llm_client.token_usage;
  model_used: string;
  latency_ms: int;
  attempts: int;
  total_cost_usd: float;
  fallback_applied: bool;
  tools_used: string list;
}

let proactive_retry_instruction attempt ~(reason : string) =
  if attempt = 2 then
    Printf.sprintf
      "Retry policy: previous attempt failed (%s). You MUST output now with a clearly different angle."
      reason
  else
    Printf.sprintf
      "Retry policy: previous attempts failed (%s). You MUST output one decisive check-in now, materially different from the last preview."
      reason

let proactive_temperature attempt =
  if attempt <= 1 then 0.55
  else if attempt = 2 then 0.75
  else 0.9

let strip_state_blocks_text (s : string) : string =
  let start_marker = "[STATE]" in
  let end_marker = "[/STATE]" in
  let start_re = Str.regexp_string start_marker in
  let end_re = Str.regexp_string end_marker in
  let len = String.length s in
  let rec loop from (buf : Buffer.t) =
    if from >= len then ()
    else
      try
        let i = Str.search_forward start_re s from in
        if i > from then Buffer.add_substring buf s from (i - from);
        let block_start = i + String.length start_marker in
        let next_from =
          try
            let j = Str.search_forward end_re s block_start in
            j + String.length end_marker
          with Not_found ->
            len
        in
        loop next_from buf
      with Not_found ->
        Buffer.add_substring buf s from (len - from)
  in
  let buf = Buffer.create len in
  loop 0 buf;
  Buffer.contents buf

let normalize_proactive_text (raw : string) : string =
  raw
  |> strip_state_blocks_text
  |> Str.global_replace (Str.regexp "[ \t\r\n]+") " "
  |> String.trim

let extract_checkin_text (raw : string) : string option =
  let cleaned = normalize_proactive_text raw in
  if cleaned = "" then None
  else
    let lines =
      raw
      |> String.split_on_char '\n'
      |> List.map String.trim
      |> List.filter (fun line -> line <> "")
    in
    let checkin_line =
      List.find_map
        (fun line ->
          match strip_prefix_ci ~prefix:"CHECKIN:" line with
          | Some s ->
              let s = normalize_proactive_text s in
              if s = "" then None else Some s
          | None -> None)
        lines
    in
    match checkin_line with
    | Some s -> Some s
    | None -> Some cleaned

let proactive_has_terminal_punct (s : string) : bool =
  let t = String.trim s in
  t <> "" && Str.string_match (Str.regexp ".*[.!?。！？]$") t 0

let proactive_has_terminal_korean_ending (s : string) : bool =
  let t = String.trim s in
  t <> ""
  && Str.string_match
       (Str.regexp ".*\\(다\\|요\\|니다\\|습니다\\|중입니다\\|함\\)$")
       t 0

let proactive_has_terminal_ending (s : string) : bool =
  proactive_has_terminal_punct s || proactive_has_terminal_korean_ending s

let proactive_looks_fragmentary (s : string) : bool =
  let t = String.trim s in
  t = ""
  || Str.string_match (Str.regexp ".*[\"'([{]$") t 0
  || Str.string_match (Str.regexp ".*[:;,\\-]$") t 0

let proactive_fallback_reply ~(meta : keeper_meta) ~(idle_seconds : int) : string =
  let goal =
    let g = String.trim meta.goal in
    if g = "" then "현재 목표" else g
  in
  let goal_phrase =
    goal
    |> Str.global_replace (Str.regexp "[.!?。！？]+$") ""
    |> String.trim
    |> fun s -> if s = "" then goal else s
  in
  let soul_hint =
    match String.lowercase_ascii (String.trim meta.soul_profile) with
    | "safety" -> "리스크 우선 점검을 마쳤고"
    | "delivery" -> "실행 단위로 정리해 두었고"
    | "research" -> "가설 검증 포인트를 갱신했고"
    | _ -> "진행 상태를 점검했고"
  in
  let templates =
    [|
      Printf.sprintf
        "%s %s, 다음 지시를 받으면 즉시 진행하겠습니다."
        goal soul_hint;
      Printf.sprintf
        "현재는 %s에 맞춰 대기 중이며, 새 입력이 오면 바로 실행 단계로 전환하겠습니다."
        goal_phrase;
      Printf.sprintf
        "%s 기준으로 우선순위를 업데이트했습니다. 다음 턴에서 바로 이어가겠습니다."
        goal;
      Printf.sprintf
        "idle %ds 동안 %s 관련 체크를 유지했습니다. 후속 요청에 맞춰 계속 진행하겠습니다."
        idle_seconds goal_phrase;
    |]
  in
  let idx =
    abs (Hashtbl.hash (meta.name, meta.proactive_count_total, idle_seconds))
    mod Array.length templates
  in
  templates.(idx)

let proactive_quality_check (raw : string) : (string, string) result =
  match extract_checkin_text raw with
  | None -> Error "empty"
  | Some text ->
      if proactive_looks_fragmentary text then Error "fragmentary"
      else if not (proactive_has_terminal_ending text) then Error "missing_terminal_ending"
      else Ok text

let looks_fragmentary_history_text (raw : string) : bool =
  let t = normalize_proactive_text raw in
  if t = "" then true
  else
    let hard_fragment = proactive_looks_fragmentary t in
    let has_terminal = proactive_has_terminal_ending t in
    let ends_korean_sentence =
      Str.string_match
        (Str.regexp ".*\\(다\\|요\\|니다\\|습니다\\|중입니다\\|함\\)$")
        t 0
    in
    let short_unterminated =
      (not has_terminal) && (not ends_korean_sentence) && String.length t <= 24
    in
    let trailing_connector =
      (not has_terminal)
      && Str.string_match
           (Str.regexp
              ".*\\(and\\|or\\|with\\|to\\|for\\|그리고\\|또는\\|및\\)$")
           (String.lowercase_ascii t) 0
    in
    hard_fragment || short_unterminated || trailing_connector

let run_proactive_generation
    ~(specs : Llm_client.model_spec list)
    ~(primary : Llm_client.model_spec)
    ~(config : Room.config)
    ~(ctx_work : Context_manager.working_context)
    ~(meta : keeper_meta)
    ~(continuity_snapshot : keeper_state_snapshot option)
    ~(continuity_summary : string)
    ~(idle_seconds : int) : proactive_generation_result option =
  let base_prompt =
    proactive_prompt_for_keeper ~meta ~idle_seconds continuity_snapshot continuity_summary
  in
  let zero_usage : Llm_client.token_usage =
    { Llm_client.input_tokens = 0; output_tokens = 0; total_tokens = 0;
      cache_creation_input_tokens = 0; cache_read_input_tokens = 0; }
  in
  let max_attempts = 3 in
  let previous_preview = String.trim meta.last_proactive_preview in
  let similarity_threshold = 0.72 in
  let fallback_skill_route =
    route_keeper_skill ~soul_profile:meta.soul_profile ~message:"proactive idle automation checkin"
  in
  let skill_selection_mode = keeper_skill_selection_mode () in
  let base_turn_system_prompt =
    match skill_selection_mode with
    | SkillSelectHeuristic ->
        skill_route_system_prompt_heuristic
          ~base_system_prompt:ctx_work.system_prompt
          ~route:fallback_skill_route
    | SkillSelectAgent ->
        skill_route_system_prompt_agent
          ~base_system_prompt:ctx_work.system_prompt
          ~fallback_route:fallback_skill_route
          ~soul_profile:meta.soul_profile
  in
  let turn_system_prompt =
    append_continuity_context_prompt
      ~base_prompt:base_turn_system_prompt
      continuity_snapshot
      ~continuity_summary
  in
  let max_tool_rounds = 3 in
  let execute_tool_calls
      ~(ctx_work : Context_manager.working_context)
      (tcs : Llm_client.tool_call list) : (Llm_client.tool_call * string) list =
    List.map
      (fun (tc : Llm_client.tool_call) ->
         let output =
           try execute_keeper_tool_call ~config ~meta ~ctx_work tc
           with exn ->
             Yojson.Safe.to_string
               (`Assoc [
                 ("error", `String (Printexc.to_string exn));
                 ("tool", `String tc.call_name);
               ])
         in
         (tc, output))
      tcs
  in
  let run_cascade requests = Llm_client.cascade requests in
  let rec loop attempt usage_acc latency_acc cost_acc retry_hint =
    if attempt > max_attempts then
      Some {
        reply = proactive_fallback_reply ~meta ~idle_seconds;
        usage = usage_acc;
        model_used = primary.model_id;
        latency_ms = latency_acc;
        attempts = max_attempts;
        total_cost_usd = cost_acc;
        fallback_applied = true;
        tools_used = [];
      }
    else
      let prompt =
        if String.trim retry_hint = "" then base_prompt
        else Printf.sprintf "%s\n\n%s" base_prompt retry_hint
      in
      let requests =
        List.map
          (fun (model : Llm_client.model_spec) ->
            ({
               Llm_client.model;
               messages =
                 (Llm_client.system_msg turn_system_prompt)
                 :: (ctx_work.messages @ [ Llm_client.user_msg prompt ]);
               temperature = proactive_temperature attempt;
               max_tokens = 1024; (* increased from 220 to allow tool calls *)
               tools = keeper_llm_tools;
               response_format = `Text;
             }
              : Llm_client.completion_request))
          specs
      in
      match run_cascade requests with
      | Error _ -> None
      | Ok resp0 ->
          let used_model0 =
            model_spec_for_used specs resp0.model_used
            |> Option.value ~default:primary
          in
          let cost0 = cost_usd_of_usage resp0.usage used_model0 in
          let rec tool_loop ~round ~acc_usage ~acc_latency ~acc_cost
              ~acc_tools_used ~last_resp =
            if last_resp.Llm_client.tool_calls = [] || round > max_tool_rounds then
              let content =
                let c = String.trim last_resp.Llm_client.content in
                if c = "" && acc_tools_used <> [] then
                  Printf.sprintf "(tools executed: %s)"
                    (String.concat ", " acc_tools_used)
                else last_resp.Llm_client.content
              in
              ( content,
                acc_usage,
                last_resp.Llm_client.model_used,
                acc_latency,
                acc_cost,
                acc_tools_used )
            else
              let round_tools =
                List.map
                  (fun (tc : Llm_client.tool_call) -> tc.call_name)
                  last_resp.Llm_client.tool_calls
              in
              let all_tools_so_far = acc_tools_used @ round_tools in
              let tool_outputs =
                execute_tool_calls ~ctx_work last_resp.Llm_client.tool_calls
              in
              let followup_prompt =
                keeper_tool_followup_prompt
                  ~user_message:prompt
                  ~draft_reply:last_resp.Llm_client.content
                  ~tool_outputs
                  ~already_executed:all_tools_so_far
              in
              let write_done =
                List.exists
                  (fun n ->
                     List.mem n
                       [
                         "keeper_board_post";
                         "keeper_board_comment";
                         "keeper_fs_edit";
                         "keeper_edit";
                       ])
                  all_tools_so_far
              in
              let next_tools =
                if write_done then [] else keeper_llm_tools
              in
              let followup_requests =
                List.map
                  (fun (model : Llm_client.model_spec) ->
                     ({
                        Llm_client.model;
                        messages = [
                          Llm_client.system_msg
                            (keeper_tool_loop_system_prompt
                               ~character_context:turn_system_prompt);
                          Llm_client.user_msg followup_prompt;
                        ];
                        temperature = 0.3;
                        max_tokens = 1024; (* increased from 220 to allow tool calls *)
                        tools = next_tools;
                        response_format = `Text;
                      }
                       : Llm_client.completion_request))
                  specs
              in
              match run_cascade followup_requests with
              | Error _ ->
                  ( last_resp.Llm_client.content,
                    acc_usage,
                    last_resp.Llm_client.model_used,
                    acc_latency,
                    acc_cost,
                    acc_tools_used @ round_tools )
              | Ok resp_next ->
                  let used_model_next =
                    model_spec_for_used specs resp_next.model_used
                    |> Option.value ~default:primary
                  in
                  let cost_next = cost_usd_of_usage resp_next.usage used_model_next in
                  tool_loop
                    ~round:(round + 1)
                    ~acc_usage:(merge_usage acc_usage resp_next.usage)
                    ~acc_latency:(acc_latency + resp_next.latency_ms)
                    ~acc_cost:(acc_cost +. cost_next)
                    ~acc_tools_used:(acc_tools_used @ round_tools)
                    ~last_resp:resp_next
          in
          let (attempt_content, attempt_usage, attempt_model_used, attempt_latency_ms,
               attempt_cost_usd, attempt_tools_used) =
            tool_loop
              ~round:1
              ~acc_usage:resp0.usage
              ~acc_latency:resp0.latency_ms
              ~acc_cost:cost0
              ~acc_tools_used:[]
              ~last_resp:resp0
          in
          let usage_acc = merge_usage usage_acc attempt_usage in
          let latency_acc = latency_acc + attempt_latency_ms in
          let cost_acc = cost_acc +. attempt_cost_usd in
          let trimmed = String.trim attempt_content in
          if trimmed <> "" then
            (match proactive_quality_check trimmed with
             | Error reason when attempt < max_attempts ->
                 let hint =
                   proactive_retry_instruction (attempt + 1) ~reason
                 in
                 loop (attempt + 1) usage_acc latency_acc cost_acc hint
             | Error _ ->
                 Some {
                   reply = proactive_fallback_reply ~meta ~idle_seconds;
                   usage = usage_acc;
                   model_used = attempt_model_used;
                   latency_ms = latency_acc;
                   attempts = attempt;
                   total_cost_usd = cost_acc;
                   fallback_applied = true;
                   tools_used = attempt_tools_used;
                 }
             | Ok checked_reply ->
                 let too_similar =
                   if previous_preview = "" then false
                   else
                     proactive_similarity_score
                       ~candidate:checked_reply
                       ~previous:previous_preview
                     >= similarity_threshold
                 in
                 if too_similar && attempt < max_attempts then
                   let hint =
                     proactive_retry_instruction (attempt + 1) ~reason:"too_similar"
                   in
                   loop (attempt + 1) usage_acc latency_acc cost_acc hint
                 else
                   Some {
                     reply = checked_reply;
                     usage = usage_acc;
                     model_used = attempt_model_used;
                     latency_ms = latency_acc;
                     attempts = attempt;
                     total_cost_usd = cost_acc;
                     fallback_applied = false;
                     tools_used = attempt_tools_used;
                   })
          else
            let hint =
              proactive_retry_instruction (attempt + 1) ~reason:"empty"
            in
            loop (attempt + 1) usage_acc latency_acc cost_acc hint
  in
  loop 1 zero_usage 0 0.0 ""

let memory_check_default_json () : Yojson.Safe.t =
  `Assoc [
    ("performed", `Bool false);
    ("query_kind", `String "none");
    ("expected_topic", `Null);
    ("candidate_count", `Int 0);
    ("initial_score", `Float 0.0);
    ("final_score", `Float 0.0);
    ("threshold", `Float 0.18);
    ("passed", `Bool true);
    ("best_match", `Null);
    ("correction_applied", `Bool false);
    ("correction_success", `Bool false);
    ("prompt_fallback_applied", `Bool false);
    ("prompt_fallback_success", `Bool false);
    ("deterministic_fallback_applied", `Bool false);
    ("recall_fallback_applied", `Bool false);
  ]

(** Check if keeper autonomy engine is enabled via environment variable. *)
let keeper_autonomy_enabled () =
  match Sys.getenv_opt "MASC_KEEPER_AUTONOMY_ENABLED" with
  | Some s -> String.lowercase_ascii (String.trim s) = "true"
  | None -> false

(* ================================================================ *)
(* Autonomous Execution Engine (Phase 5)                            *)
(* ================================================================ *)

(** Gate config for autonomous keeper execution.
    Restricts allowed tools to safe, read-only + board operations.
    @since 2.74.0 *)
let autonomous_gate_config
    ~(autonomy_level : Keeper_autonomy.autonomy_level) : Eval_gate.gate_config =
  let base_allowed = [
    "keeper_board_post"; "keeper_board_comment"; "keeper_board_list";
    "keeper_read"; "keeper_fs_read";
    "keeper_memory_search";
    "keeper_time_now"; "keeper_context_status";
  ] in
  let base_denied = [
    "keeper_bash"; "keeper_edit"; "keeper_fs_edit"; "keeper_github";
  ] in
  match autonomy_level with
  | L4_Autonomous ->
      (* L4: allow bash for safe commands *)
      {
        max_cost_usd = 0.10;
        max_tool_calls_per_turn = 5;
        entropy_threshold = 2;
        destructive_check_enabled = true;
        allowlist_enabled = true;
        allowed_tools = "keeper_bash" :: base_allowed;
        denied_tools = List.filter (fun t -> t <> "keeper_bash") base_denied;
      }
  | L5_Independent ->
      (* L5: all tools allowed, higher budget *)
      {
        max_cost_usd = 0.50;
        max_tool_calls_per_turn = 10;
        entropy_threshold = 3;
        destructive_check_enabled = true;
        allowlist_enabled = false;
        allowed_tools = [];
        denied_tools = [];
      }
  | _ ->
      (* L3 and below: strict safe-only *)
      {
        max_cost_usd = 0.10;
        max_tool_calls_per_turn = 5;
        entropy_threshold = 2;
        destructive_check_enabled = true;
        allowlist_enabled = true;
        allowed_tools = base_allowed;
        denied_tools = base_denied;
      }

(** Execute an approved/cautioned action plan via LLM + tool loop with gate sandboxing.

    1. Inject plan text into LLM system prompt
    2. LLM generates tool_calls based on plan
    3. Each tool_call goes through Eval_gate.guarded_execute
    4. Recursive tool_loop (max 3 rounds)
    5. Returns execution summary

    @since 2.74.0 *)
let execute_approved_plan
    ~(config : Room.config)
    ~(meta : keeper_meta)
    ~(specs : Llm_client.model_spec list)
    ~(plan : string)
    ~(pa : Keeper_autonomy.proposed_action)
    ~(autonomy_level : Keeper_autonomy.autonomy_level)
    ~(trajectory_acc : Trajectory.accumulator option)
    : string * float * string list =
  let gate_config = autonomous_gate_config ~autonomy_level in
  let primary = match specs with p :: _ -> p | [] -> Llm_client.default_local_model_spec () in
  let system_prompt = Printf.sprintf
{|You are a keeper agent executing an approved action plan.
Your name: %s
Goal: %s (id=%s)

Approved Plan:
%s

Execute step 1 of this plan using the available tools.
Be concise. Only use tools that directly advance the plan.
Do NOT use destructive tools (bash rm, edit, delete).|}
    meta.name pa.goal_title pa.goal_id plan
  in
  let ctx_work = Context_manager.create
    ~system_prompt:(Printf.sprintf "Keeper %s autonomous execution" meta.name)
    ~max_tokens:4000 in
  let execute_tool_calls
      (tcs : Llm_client.tool_call list) : (Llm_client.tool_call * string) list =
    List.map
      (fun (tc : Llm_client.tool_call) ->
         let execute () =
           execute_keeper_tool_call ~config ~meta ~ctx_work tc
         in
         let (decision, result_opt, _post_eval, duration_ms) =
           Eval_gate.guarded_execute
             ~config:gate_config
             ~accumulated_cost:0.0
             ~trajectory_acc
             ~tool_name:tc.call_name
             ~args_json:tc.call_arguments
             ~execute
         in
         let result = match decision, result_opt with
           | Trajectory.Reject reason, _ ->
               Printf.eprintf "[keeper-autonomy] GATE BLOCKED %s: %s\n%!"
                 tc.call_name reason;
               Yojson.Safe.to_string (`Assoc [("gate_blocked", `String tc.call_name); ("reason", `String reason)])
           | _, Some r -> r
           | _, None -> "{\"error\":\"no result\"}"
         in
         (* Record to trajectory *)
         (match trajectory_acc with
          | Some acc ->
              Trajectory.record_entry acc {
                ts = Time_compat.now ();
                ts_iso = Types.now_iso ();
                turn = acc.Trajectory.turn;
                round = 0;
                tool_name = tc.call_name;
                args_json = tc.call_arguments;
                gate_decision = decision;
                result = Some (if String.length result > 500
                          then String.sub result 0 500 ^ "..."
                          else result);
                duration_ms;
                error = None;
                cost_usd = 0.0;
              }
          | None -> ());
         (tc, result))
      tcs
  in
  let run_cascade requests = Llm_client.cascade requests in
  let max_rounds = 3 in
  let initial_request =
    { Llm_client.model = primary;
      messages = [
        Llm_client.system_msg system_prompt;
        Llm_client.user_msg "Execute the first step of the plan now.";
      ];
      temperature = 0.3;
      max_tokens = 1024;
      tools = keeper_llm_tools;
      response_format = `Text;
    }
  in
  let requests = List.map (fun (spec : Llm_client.model_spec) ->
    { initial_request with Llm_client.model = spec }
  ) specs in
  match run_cascade requests with
  | Error e ->
      (Printf.sprintf "LLM cascade failed: %s" e, 0.0, [])
  | Ok resp0 ->
      let rec exec_loop ~round ~acc_cost ~acc_tools ~last_resp =
        if last_resp.Llm_client.tool_calls = [] || round > max_rounds then
          let content =
            let c = String.trim last_resp.Llm_client.content in
            if c = "" && acc_tools <> [] then
              Printf.sprintf "(autonomous execution: %s)"
                (String.concat ", " acc_tools)
            else c
          in
          (content, acc_cost, acc_tools)
        else
          let round_tools =
            List.map (fun (tc : Llm_client.tool_call) -> tc.call_name)
              last_resp.Llm_client.tool_calls
          in
          let all_tools = acc_tools @ round_tools in
          let tool_outputs = execute_tool_calls last_resp.Llm_client.tool_calls in
          let followup_prompt =
            keeper_tool_followup_prompt
              ~user_message:"Execute the next step of the plan."
              ~draft_reply:last_resp.Llm_client.content
              ~tool_outputs
              ~already_executed:all_tools
          in
          (* Stop providing tools after write operations *)
          let write_done =
            List.exists (fun n ->
              List.mem n ["keeper_board_post"; "keeper_board_comment"])
              all_tools
          in
          let next_tools = if write_done then [] else keeper_llm_tools in
          let followup_requests = List.map (fun (spec : Llm_client.model_spec) ->
            { Llm_client.model = spec;
              messages = [
                Llm_client.system_msg system_prompt;
                Llm_client.user_msg followup_prompt;
              ];
              temperature = 0.3;
              max_tokens = 1024;
              tools = next_tools;
              response_format = `Text;
            }
          ) specs in
          match run_cascade followup_requests with
          | Error _ ->
              (last_resp.Llm_client.content, acc_cost, all_tools)
          | Ok next_resp ->
              let used_spec =
                model_spec_for_used specs next_resp.model_used
                |> Option.value ~default:primary
              in
              let round_cost = cost_usd_of_usage next_resp.usage used_spec in
              exec_loop ~round:(round + 1)
                ~acc_cost:(acc_cost +. round_cost)
                ~acc_tools:all_tools
                ~last_resp:next_resp
      in
      let used_spec0 =
        model_spec_for_used specs resp0.model_used
        |> Option.value ~default:primary
      in
      let cost0 = cost_usd_of_usage resp0.usage used_spec0 in
      exec_loop ~round:1 ~acc_cost:cost0 ~acc_tools:[] ~last_resp:resp0

(** Autonomous goal turn: evaluate goals and optionally generate/verify action plan.
    Returns Some updated_meta when an autonomous action decision was made,
    None to fall through to regular proactive generation.
    @since 2.74.0 *)
let run_autonomous_goal_turn ~(config : Room.config) ~(meta : keeper_meta)
    ~(specs : Llm_client.model_spec list) : keeper_meta option =
  if not (keeper_autonomy_enabled ()) then None
  else if meta.active_goal_ids = [] then None
  else
    match Keeper_autonomy.autonomy_level_of_string meta.autonomy_level with
    | None -> None
    | Some L1_Reactive -> None
    | Some level ->
        let primary = match specs with p :: _ -> p | [] -> Llm_client.default_local_model_spec () in
        let verify_model =
          match Llm_client.default_verifier_model_spec () with
          | Ok model -> model
          | Error _ -> primary
        in
        let keeper_context =
          Printf.sprintf "keeper=%s autonomy=%s turns=%d cost=$%.4f"
            meta.name (Keeper_autonomy.autonomy_level_to_string level)
            meta.total_turns meta.total_cost_usd
        in
        match level with
        | L1_Reactive -> None
        | L2_Suggestive ->
            (* L2: evaluate and post suggestion to Board *)
            let next = Keeper_autonomy.evaluate_next_action
              ~config ~goal_ids:meta.active_goal_ids ~keeper_name:meta.name in
            (match next with
             | Propose pa ->
                 Printf.eprintf "[keeper-autonomy] %s L2 suggest: %s (risk=%s, cost=$%.2f)\n%!"
                   meta.name pa.action_description
                   (Keeper_autonomy.risk_level_to_string pa.risk_level)
                   pa.estimated_cost_usd;
                 let board_args = `Assoc [
                   ("author", `String meta.name);
                   ("title", `String (Printf.sprintf "[L2 제안] %s" pa.goal_title));
                   ("content", `String (Printf.sprintf
                     "**제안 액션**: %s\n\n- Risk: %s\n- Estimated cost: $%.2f\n- Goal: %s (id=%s)"
                     pa.action_description
                     (Keeper_autonomy.risk_level_to_string pa.risk_level)
                     pa.estimated_cost_usd
                     pa.goal_title pa.goal_id));
                   ("tags", `List [
                     `String "keeper-autonomy";
                     `String "L2-suggestion";
                     `String meta.name;
                   ]);
                 ] in
                 let (ok, _msg) = Tool_board.handle_tool "masc_board_post" board_args in
                 if not ok then
                   Printf.eprintf "[keeper-autonomy] %s L2 board post failed\n%!" meta.name;
                 Some { meta with
                   last_autonomous_action_at = now_iso ();
                   autonomous_action_count = meta.autonomous_action_count + 1;
                   updated_at = now_iso ();
                 }
             | StartPerpetualAgent req ->
                 Printf.eprintf "[keeper-autonomy] %s L2 perpetual suggest: %s\n%!"
                   meta.name req.goal_title;
                 let board_args = `Assoc [
                   ("author", `String meta.name);
                   ("title", `String (Printf.sprintf "[L2 제안] Perpetual Agent: %s" req.goal_title));
                   ("content", `String (Printf.sprintf
                     "**장기 목표 감지**: %s\n\n이 목표는 Perpetual Agent가 적합합니다.\n- Models: %s\n- Coding mode: %b\n- Agent: %s\n\nL3+ 자율성에서 자동 시작됩니다."
                     req.goal_title
                     (String.concat ", " req.models)
                     req.coding_mode
                     req.coding_agent));
                   ("tags", `List [
                     `String "keeper-autonomy";
                     `String "perpetual-suggestion";
                     `String meta.name;
                   ]);
                 ] in
                 (match Tool_board.handle_tool "masc_board_post" board_args with
                  | (true, _) -> ()
                  | (false, err) ->
                      Printf.eprintf "[keeper-autonomy] %s L2 perpetual board post failed: %s\n%!" meta.name err
                  | exception exn ->
                      Printf.eprintf "[keeper-autonomy] %s L2 board post error: %s\n%!" meta.name (Printexc.to_string exn));
                 Some { meta with
                   last_autonomous_action_at = now_iso ();
                   autonomous_action_count = meta.autonomous_action_count + 1;
                   updated_at = now_iso ();
                 }
             | _ -> None)
        | _ ->
            (* L3+: full pipeline — evaluate, plan, verify, decide *)
            let result = Keeper_verifier.run_pipeline
              ~config
              ~goal_ids:meta.active_goal_ids
              ~keeper_name:meta.name
              ~keeper_context
              ~plan_model:primary
              ~verify_model
              ~autonomy_level:level
            in
            (match result with
             | NothingToDo reason ->
                 Printf.eprintf "[keeper-autonomy] %s: nothing to do (%s)\n%!" meta.name reason;
                 None
             | PerpetualRequested req ->
                 Printf.eprintf "[keeper-autonomy] %s PERPETUAL: starting for %s\n%!"
                   meta.name req.goal_title;
                 (* Keeper runs in heartbeat timer context without Eio.Switch.t,
                    so coding_mode (= Claude Code spawn) is structurally unavailable.
                    Force LLM-only mode to prevent guaranteed failure. *)
                 let effective_coding_mode = false in
                 (if req.coding_mode then
                    Printf.eprintf "[keeper-autonomy] %s: coding_mode requested but unavailable (no Eio.Switch in heartbeat context), falling back to LLM-only\n%!" meta.name);
                 let perp_args = `Assoc [
                   ("goal", `String req.goal_title);
                   ("models", `List (List.map (fun m -> `String m) req.models));
                   ("coding_mode", `Bool effective_coding_mode);
                   ("coding_agent", `String req.coding_agent);
                 ] in
                 let perp_ctx = {
                   Tool_perpetual.agent_name = meta.name;
                   start_loop = None;
                   sw = None;
                   proc_mgr = None;
                 } in
                 (match Tool_perpetual.dispatch perp_ctx ~name:"masc_perpetual_start" ~args:perp_args with
                  | Some (true, result_json) ->
                      Printf.eprintf "[keeper-autonomy] %s perpetual started: %s\n%!"
                        meta.name result_json;
                      (* Update goal with perpetual agent info *)
                      (try ignore (Goal_store.review_goal config
                        ~goal_id:req.goal_id ~outcome:"progress"
                        ~note:(Printf.sprintf "Perpetual agent started (models: %s)"
                          (String.concat ", " req.models)) ()) with exn ->
                        Printf.eprintf "[keeper] goal review failed: %s\n%!" (Printexc.to_string exn));
                      (* Post to Board *)
                      let board_args = `Assoc [
                        ("author", `String meta.name);
                        ("title", `String (Printf.sprintf "[L%d Perpetual] %s"
                          (Keeper_autonomy.autonomy_level_to_int level) req.goal_title));
                        ("content", `String (Printf.sprintf
                          "Perpetual Agent started for long-horizon goal.\n\n- Goal: %s (id=%s)\n- Models: %s\n- Coding mode: %b"
                          req.goal_title req.goal_id
                          (String.concat ", " req.models) req.coding_mode));
                        ("tags", `List [
                          `String "keeper-autonomy";
                          `String "perpetual-start";
                          `String meta.name;
                        ]);
                      ] in
                      (match Tool_board.handle_tool "masc_board_post" board_args with
                       | (true, _) -> ()
                       | (false, err) ->
                           Printf.eprintf "[keeper-autonomy] %s: board post failed: %s\n%!" meta.name err
                       | exception exn ->
                           Printf.eprintf "[keeper-autonomy] %s: board post error: %s\n%!" meta.name (Printexc.to_string exn));
                      Some { meta with
                        last_autonomous_action_at = now_iso ();
                        autonomous_action_count = meta.autonomous_action_count + 1;
                        updated_at = now_iso ();
                      }
                  | Some (false, err) ->
                      Printf.eprintf "[keeper-autonomy] %s perpetual start failed: %s\n%!"
                        meta.name err;
                      None
                  | None ->
                      Printf.eprintf "[keeper-autonomy] %s perpetual dispatch returned None\n%!" meta.name;
                      None)
             | Approved (pa, plan) ->
                 Printf.eprintf "[keeper-autonomy] %s APPROVED: %s\n%!"
                   meta.name pa.action_description;
                 (* 5-3: Create trajectory accumulator for this autonomous turn *)
                 let masc_root = Filename.concat config.base_path ".masc" in
                 let traj_acc = Trajectory.create_accumulator
                   ~masc_root
                   ~keeper_name:meta.name
                   ~trace_id:(Printf.sprintf "keeper-auto-%s-%d"
                     meta.name meta.autonomous_action_count)
                   ~generation:meta.generation in
                 (* 5-4: SSE — keeper_autonomy_start *)
                 (try Sse.broadcast (`Assoc [
                   ("type", `String "keeper_autonomy_start");
                   ("name", `String meta.name);
                   ("goal_id", `String pa.goal_id);
                   ("action", `String pa.action_description);
                   ("autonomy_level", `String (Keeper_autonomy.autonomy_level_to_string level));
                 ]) with exn ->
                   Printf.eprintf "[keeper] SSE keeper_autonomy_start broadcast failed: %s\n%!" (Printexc.to_string exn));
                 (* 5-2: Execute the approved plan *)
                 let (summary, exec_cost, tools_used) =
                   execute_approved_plan ~config ~meta ~specs ~plan ~pa
                     ~autonomy_level:level ~trajectory_acc:(Some traj_acc) in
                 (* 5-3: Finalize trajectory *)
                 (try ignore (Trajectory.finalize traj_acc Trajectory.Completed)
                  with exn -> Printf.eprintf "[keeper] trajectory finalize failed: %s\n%!" (Printexc.to_string exn));
                 (* 5-3: Update goal progress *)
                 let outcome = if tools_used <> [] then "progress" else "blocked" in
                 let review_note = Printf.sprintf
                   "Autonomous execution (L%d): %s | tools: [%s] | cost: $%.4f"
                   (Keeper_autonomy.autonomy_level_to_int level)
                   (if String.length summary > 200 then String.sub summary 0 200 ^ "..." else summary)
                   (String.concat ", " tools_used)
                   exec_cost in
                 (try ignore (Goal_store.review_goal config
                   ~goal_id:pa.goal_id ~outcome ~note:review_note ()) with exn ->
                   Printf.eprintf "[keeper] goal review failed: %s\n%!" (Printexc.to_string exn));
                 (* 5-4: Post execution report to Board *)
                 let report_args = `Assoc [
                   ("author", `String meta.name);
                   ("title", `String (Printf.sprintf "[L%d 실행] %s"
                     (Keeper_autonomy.autonomy_level_to_int level) pa.goal_title));
                   ("content", `String (Printf.sprintf
                     "**실행 결과**: %s\n\n- Tools used: [%s]\n- Cost: $%.4f\n- Goal: %s (id=%s)\n- Outcome: %s"
                     (if String.length summary > 500 then String.sub summary 0 500 ^ "..." else summary)
                     (String.concat ", " tools_used) exec_cost
                     pa.goal_title pa.goal_id outcome));
                   ("tags", `List [
                     `String "keeper-autonomy";
                     `String "execution-report";
                     `String meta.name;
                   ]);
                 ] in
                 let (_ok, _msg) = Tool_board.handle_tool "masc_board_post" report_args in
                 (* 5-4: SSE — keeper_autonomy_complete *)
                 (try Sse.broadcast (`Assoc [
                   ("type", `String "keeper_autonomy_complete");
                   ("name", `String meta.name);
                   ("goal_id", `String pa.goal_id);
                   ("result", `String outcome);
                   ("tools_used", `List (List.map (fun t -> `String t) tools_used));
                   ("cost_usd", `Float exec_cost);
                 ]) with exn ->
                   Printf.eprintf "[keeper] SSE keeper_autonomy_complete broadcast failed: %s\n%!" (Printexc.to_string exn));
                 Some { meta with
                   last_autonomous_action_at = now_iso ();
                   autonomous_action_count = meta.autonomous_action_count + 1;
                   total_cost_usd = meta.total_cost_usd +. exec_cost;
                   updated_at = now_iso ();
                 }
             | Cautioned (pa, plan, warning) ->
                 Printf.eprintf "[keeper-autonomy] %s CAUTIONED: %s (warning: %s)\n%!"
                   meta.name pa.action_description warning;
                 (* 5-3: Trajectory with warning recorded *)
                 let masc_root = Filename.concat config.base_path ".masc" in
                 let traj_acc = Trajectory.create_accumulator
                   ~masc_root
                   ~keeper_name:meta.name
                   ~trace_id:(Printf.sprintf "keeper-auto-%s-%d-cautioned"
                     meta.name meta.autonomous_action_count)
                   ~generation:meta.generation in
                 (* Record caution warning to trajectory *)
                 Trajectory.record_entry traj_acc {
                   ts = Time_compat.now ();
                   ts_iso = Types.now_iso ();
                   turn = traj_acc.Trajectory.turn;
                   round = 0;
                   tool_name = "_caution_warning";
                   args_json = Yojson.Safe.to_string (`Assoc [("warning", `String warning)]);
                   gate_decision = Trajectory.Pass;
                   result = Some warning;
                   duration_ms = 0;
                   error = None;
                   cost_usd = 0.0;
                 };
                 (* 5-4: SSE — keeper_autonomy_start (cautioned) *)
                 (try Sse.broadcast (`Assoc [
                   ("type", `String "keeper_autonomy_start");
                   ("name", `String meta.name);
                   ("goal_id", `String pa.goal_id);
                   ("action", `String pa.action_description);
                   ("autonomy_level", `String (Keeper_autonomy.autonomy_level_to_string level));
                   ("caution", `String warning);
                 ]) with exn ->
                   Printf.eprintf "[keeper] SSE keeper_autonomy_start (cautioned) broadcast failed: %s\n%!" (Printexc.to_string exn));
                 (* 5-2: Execute despite caution *)
                 let (summary, exec_cost, tools_used) =
                   execute_approved_plan ~config ~meta ~specs ~plan ~pa
                     ~autonomy_level:level ~trajectory_acc:(Some traj_acc) in
                 (try ignore (Trajectory.finalize traj_acc Trajectory.Completed)
                  with exn -> Printf.eprintf "[keeper] trajectory finalize (cautioned) failed: %s\n%!" (Printexc.to_string exn));
                 (* 5-3: Update goal progress *)
                 let outcome = if tools_used <> [] then "progress" else "blocked" in
                 let review_note = Printf.sprintf
                   "Cautioned execution (L%d, warning: %s): %s | tools: [%s] | cost: $%.4f"
                   (Keeper_autonomy.autonomy_level_to_int level) warning
                   (if String.length summary > 150 then String.sub summary 0 150 ^ "..." else summary)
                   (String.concat ", " tools_used)
                   exec_cost in
                 (try ignore (Goal_store.review_goal config
                   ~goal_id:pa.goal_id ~outcome ~note:review_note ()) with exn ->
                   Printf.eprintf "[keeper] goal review (cautioned) failed: %s\n%!" (Printexc.to_string exn));
                 (* 5-4: Board report + SSE complete *)
                 let report_args = `Assoc [
                   ("author", `String meta.name);
                   ("title", `String (Printf.sprintf "[L%d 실행⚠] %s"
                     (Keeper_autonomy.autonomy_level_to_int level) pa.goal_title));
                   ("content", `String (Printf.sprintf
                     "**경고**: %s\n\n**실행 결과**: %s\n\n- Tools: [%s]\n- Cost: $%.4f\n- Goal: %s (id=%s)"
                     warning
                     (if String.length summary > 400 then String.sub summary 0 400 ^ "..." else summary)
                     (String.concat ", " tools_used) exec_cost
                     pa.goal_title pa.goal_id));
                   ("tags", `List [
                     `String "keeper-autonomy";
                     `String "execution-report";
                     `String "cautioned";
                     `String meta.name;
                   ]);
                 ] in
                 let (_ok, _msg) = Tool_board.handle_tool "masc_board_post" report_args in
                 (try Sse.broadcast (`Assoc [
                   ("type", `String "keeper_autonomy_complete");
                   ("name", `String meta.name);
                   ("goal_id", `String pa.goal_id);
                   ("result", `String outcome);
                   ("tools_used", `List (List.map (fun t -> `String t) tools_used));
                   ("cost_usd", `Float exec_cost);
                   ("warning", `String warning);
                 ]) with exn ->
                   Printf.eprintf "[keeper] SSE keeper_autonomy_complete (cautioned) broadcast failed: %s\n%!" (Printexc.to_string exn));
                 Some { meta with
                   last_autonomous_action_at = now_iso ();
                   autonomous_action_count = meta.autonomous_action_count + 1;
                   total_cost_usd = meta.total_cost_usd +. exec_cost;
                   updated_at = now_iso ();
                 }
             | Rejected (pa, reason) ->
                 Printf.eprintf "[keeper-autonomy] %s REJECTED: %s (%s)\n%!"
                   meta.name pa.action_description reason;
                 None)

let maybe_emit_proactive (ctx : _ context) (meta : keeper_meta) : keeper_meta =
  if not meta.proactive_enabled then meta
  else
    let now_ts = Time_compat.now () in
    let created_ts =
      Resilience.Time.parse_iso8601_opt meta.created_at |> Option.value ~default:0.0
    in
    let activity_ts =
      let base = max meta.last_turn_ts meta.last_proactive_ts in
      if base > 0.0 then base else created_ts
    in
    let idle_seconds =
      if activity_ts <= 0.0 then 0 else int_of_float (max 0.0 (now_ts -. activity_ts))
    in
    let idle_gate = normalize_proactive_idle_sec meta.proactive_idle_sec in
    let cooldown_gate = normalize_proactive_cooldown_sec meta.proactive_cooldown_sec in
    let cooldown_elapsed =
      if meta.last_proactive_ts <= 0.0 then max_int
      else int_of_float (max 0.0 (now_ts -. meta.last_proactive_ts))
    in
    if idle_seconds < idle_gate || cooldown_elapsed < cooldown_gate then meta
    else
      match model_specs_of_strings meta.models with
      | Error _ -> meta
      | Ok specs ->
          (match ensure_api_keys specs with
           | Error _ -> meta
           | Ok () ->
               (* Phase 2: Autonomous goal turn (L2+ with active goals) *)
               (match run_autonomous_goal_turn ~config:ctx.config ~meta ~specs with
                | Some updated_meta ->
                    (match write_meta ctx.config updated_meta with
                     | Ok () -> ()
                     | Error msg ->
                         Printf.eprintf "[keeper] write_meta failed after goal turn: %s\n%!" msg);
                    updated_meta
                | None ->
               let primary =
                 match specs with
                 | p :: _ -> p
                 | [] -> Llm_client.default_local_model_spec ()
               in
               let base_dir = session_base_dir ctx.config in
               let (session, ctx_opt) =
                 load_context_from_checkpoint
                   ~trace_id:meta.trace_id
                   ~primary_model_max_tokens:primary.max_context
                   ~base_dir
               in
               match ctx_opt with
               | None -> meta
               | Some ctx_work ->
                   let continuity_snapshot = latest_state_snapshot_from_messages ctx_work.messages in
                   let continuity_summary =
                     match continuity_snapshot with
                     | Some s -> keeper_state_snapshot_to_summary_text s
                     | None -> (
                         let trimmed = String.trim meta.continuity_summary in
                         if trimmed = "" then "No continuity snapshot available." else trimmed)
                   in
                   let continuity_summary = String.trim continuity_summary in
                   let last_continuity_update_ts =
                     if
                       continuity_summary <> ""
                       && String.trim meta.continuity_summary <> continuity_summary
                     then
                       now_ts
                     else
                       meta.last_continuity_update_ts
                   in
                   let meta_for_compaction =
                     { meta with
                       continuity_summary;
                       last_continuity_update_ts
                     }
                   in
                   match
                     run_proactive_generation
                       ~specs
                       ~primary
                       ~config:ctx.config
                       ~ctx_work
                       ~meta
                       ~continuity_snapshot
                       ~continuity_summary
                       ~idle_seconds
                   with
                       | None -> meta
	                   | Some generated ->
	                       let model_used =
	                         let m = String.trim generated.model_used in
	                         if m <> "" then m else primary.model_id
	                       in
	                       let proactive_skill_route =
	                         route_keeper_skill
	                           ~soul_profile:meta.soul_profile
	                           ~message:"proactive idle checkin"
	                       in
	                       let safe_reply = generated.reply in
	                       let assistant_msg = Llm_client.assistant_msg safe_reply in
	                       let ctx_work = Context_manager.append ctx_work assistant_msg in
                       Context_manager.persist_message session assistant_msg;
                       let before_compact_tokens = ctx_work.token_count in
                       let (ctx_work, compaction_trigger, compaction_decision) =
                        compact_if_needed ~meta:meta_for_compaction ~now_ts ctx_work
                       in
                       let after_compact_tokens = ctx_work.token_count in
                       let compacted = after_compact_tokens < before_compact_tokens in
                       (try ignore (save_checkpoint session ctx_work ~generation:meta.generation)
                        with exn -> Printf.eprintf "[keeper] save_checkpoint (tool_loop) failed: %s\n%!" (Printexc.to_string exn));
                       let turn_cost = generated.total_cost_usd in
                       let proactive_reason =
                         Printf.sprintf
                           "idle=%ds>=gate=%ds; cooldown_elapsed=%ds>=gate=%ds; soul=%s; skill=%s; attempts=%d; mode=tool_loop; tool_calls=%d; fallback=%d"
                           idle_seconds idle_gate cooldown_elapsed cooldown_gate meta.soul_profile
                           proactive_skill_route.primary_skill
                           generated.attempts
                           (List.length generated.tools_used)
                           (if generated.fallback_applied then 1 else 0)
                       in
                           let updated =
                             {
                               meta with
                           updated_at = now_iso ();
                           total_turns = meta.total_turns + 1;
                           total_input_tokens =
                             meta.total_input_tokens + generated.usage.input_tokens;
                           total_output_tokens =
                             meta.total_output_tokens + generated.usage.output_tokens;
                           total_tokens = meta.total_tokens + generated.usage.total_tokens;
                           total_cost_usd = meta.total_cost_usd +. turn_cost;
                           last_turn_ts = now_ts;
                           last_model_used = model_used;
                           last_input_tokens = generated.usage.input_tokens;
                           last_output_tokens = generated.usage.output_tokens;
                           last_total_tokens = generated.usage.total_tokens;
                           last_latency_ms = generated.latency_ms;
                           compaction_count =
                             meta.compaction_count + if compacted then 1 else 0;
                           last_compaction_check_ts = now_ts;
                           last_compaction_decision = compaction_decision;
                           last_compaction_ts =
                             if compacted then now_ts else meta.last_compaction_ts;
                           last_compaction_before_tokens =
                             if compacted
                             then before_compact_tokens
                             else meta.last_compaction_before_tokens;
                           last_compaction_after_tokens =
                             if compacted
                             then after_compact_tokens
                             else meta.last_compaction_after_tokens;
                           proactive_count_total = meta.proactive_count_total + 1;
                           last_proactive_ts = now_ts;
                           last_proactive_reason = proactive_reason;
                               last_proactive_preview = short_preview safe_reply;
                               continuity_summary;
                               last_continuity_update_ts;
                             }
                       in
                       (match write_meta ctx.config updated with
                        | Ok () -> ()
                        | Error msg ->
                            Printf.eprintf "[keeper] write_meta failed after proactive turn: %s\n%!" msg);
                       (try
                          let metrics_path = keeper_metrics_path ctx.config updated.name in
                          let metrics_json =
                            `Assoc
                              [
                                ("ts", `String (now_iso ()));
                                ("ts_unix", `Float now_ts);
                                ("channel", `String "proactive");
                                ("name", `String updated.name);
                                ("agent_name", `String updated.agent_name);
                                ("trace_id", `String updated.trace_id);
                                ("generation", `Int updated.generation);
                                ("model_used", `String model_used);
                                ( "usage",
                                  `Assoc
                                    [
                                      ("input_tokens", `Int generated.usage.input_tokens);
                                      ("output_tokens", `Int generated.usage.output_tokens);
                                      ("total_tokens", `Int generated.usage.total_tokens);
                                    ] );
                                ("latency_ms", `Int generated.latency_ms);
                                ("cost_usd", `Float turn_cost);
                                ("context_ratio", `Float (Context_manager.context_ratio ctx_work));
                                ("context_tokens", `Int ctx_work.token_count);
                                ("context_max", `Int ctx_work.max_tokens);
                                ("message_count", `Int (List.length ctx_work.messages));
                                ("compacted", `Bool compacted);
                                ("compaction_before_tokens", `Int before_compact_tokens);
                                ("compaction_after_tokens", `Int after_compact_tokens);
                                  ( "compaction_trigger",
                                    match compaction_trigger with
                                    | Some reason -> `String reason
                                    | None -> `Null );
                                ("compaction_decision", `String compaction_decision);
                                ("work_kind", `String "proactive_checkin");
	                                ("tool_call_count", `Int (List.length generated.tools_used));
	                                ("tools_used", `List (List.map (fun s -> `String s) generated.tools_used));
	                                ("skill_primary", `String proactive_skill_route.primary_skill);
	                                ("skill_secondary",
	                                  `List
	                                    (List.map
	                                       (fun s -> `String s)
	                                       proactive_skill_route.secondary_skills));
	                                ("skill_reason", `String proactive_skill_route.reason);
	                                ("memory_check", memory_check_default_json ());
	                                ("proactive", `Assoc [
                                  ("performed", `Bool true);
                                  ("attempts", `Int generated.attempts);
                                  ("fallback_applied", `Bool generated.fallback_applied);
                                  ("idle_seconds", `Int idle_seconds);
                                  ("idle_gate_seconds", `Int idle_gate);
                                  ("cooldown_elapsed_seconds", `Int cooldown_elapsed);
                                  ("cooldown_gate_seconds", `Int cooldown_gate);
                                  ("reason", `String proactive_reason);
                                  ("preview", `String (short_preview safe_reply));
                                ]);
                                ("handoff", `Assoc [ ("performed", `Bool false) ]);
                              ]
                          in
                          append_jsonl_line metrics_path metrics_json
                        with exn ->
                          Printf.eprintf "[keeper] metrics JSONL write failed: %s\n%!" (Printexc.to_string exn));
                       updated))

(* Presence keepalive fibers keyed by keeper name. *)
let keepalives : (string, bool ref) Hashtbl.t = Hashtbl.create 8
let running_keepers () = Hashtbl.length keepalives
let keeper_keepalive_running name = Hashtbl.mem keepalives name
let keeper_spawn_slots_available () =
  let max_keepers = Env_config.KeeperBootstrap.max_active_keepers in
  max_keepers <= 0 || running_keepers () < max_keepers

let start_keepalive ?(proactive_warmup_sec = 0) (ctx : _ context) (m : keeper_meta) : unit =
  if not m.presence_keepalive then ()
  else if Hashtbl.mem keepalives m.name then ()
  else if not (keeper_spawn_slots_available ()) then ()
  else begin
    let stop = ref false in
    Hashtbl.replace keepalives m.name stop;
    (* Keepers should be usable even if the user hasn't called masc_init yet. *)
    (try
       if not (Room_utils.is_initialized ctx.config) then
         ignore (Room.init ctx.config ~agent_name:None)
     with exn ->
       Printf.eprintf "[keeper] room init failed: %s\n%!" (Printexc.to_string exn));
    (* Ensure the keeper agent exists in room (skip join if already present). *)
    (try
       if not (Room.is_agent_joined ctx.config ~agent_name:m.agent_name) then
         ignore (Room.join ctx.config ~agent_name:m.agent_name ~capabilities:["keeper"] ())
     with exn ->
       Printf.eprintf "[keeper] room join failed: %s\n%!" (Printexc.to_string exn));
    Eio.Fiber.fork ~sw:ctx.sw (fun () ->
      let keepalive_started_ts = Time_compat.now () in
      let snapshot_interval_sec =
        match Sys.getenv_opt "MASC_KEEPER_SNAPSHOT_SEC" with
        | Some s ->
            (try max 15 (min 3600 (int_of_string (String.trim s))) with Failure _ -> 60)
        | None -> 60
      in
      let last_snapshot_ts = ref 0.0 in
      let rec loop () =
        if !stop then ()
        else begin
          let meta_current =
            match read_meta ctx.config m.name with
            | Ok (Some latest) -> latest
            | _ -> m
          in
          (try
             ignore (Room.heartbeat ctx.config ~agent_name:meta_current.agent_name)
           with exn ->
             Printf.eprintf "[keeper] room heartbeat failed: %s\n%!" (Printexc.to_string exn));
          let now_ts = Time_compat.now () in
          if now_ts -. !last_snapshot_ts >= float_of_int snapshot_interval_sec then begin
            (try
               let metrics_path = keeper_metrics_path ctx.config meta_current.name in
               let primary_model =
                 match model_specs_of_strings meta_current.models with
                 | Ok (primary :: _) -> primary
                 | _ -> Llm_client.default_local_model_spec ()
               in
               let base_dir = session_base_dir ctx.config in
               let (_session, ctx_opt) =
                 load_context_from_checkpoint
                   ~trace_id:meta_current.trace_id
                   ~primary_model_max_tokens:primary_model.max_context
                   ~base_dir
               in
	               (match ctx_opt with
	                | None -> ()
	                | Some c ->
                    let latest_user_message =
                      latest_message_content_by_role
                        ~role:Llm_client.User
                        c.messages
                    in
                    let latest_assistant_message =
                      latest_message_content_by_role
                        ~role:Llm_client.Assistant
                        c.messages
                    in
	                    let continuity_snapshot = latest_state_snapshot_from_messages c.messages in
	                    let continuity_summary =
	                      match continuity_snapshot with
	                      | Some s -> keeper_state_snapshot_to_summary_text s
	                      | None ->
	                          let trimmed = String.trim meta_current.continuity_summary in
	                          if trimmed = "" then "No continuity snapshot available." else trimmed
	                    in
	                    let repetition_risk =
	                      repetition_risk_score ~messages:c.messages ~candidate_reply:None
	                    in
	                    let goal_alignment =
	                      goal_alignment_score
	                        ~meta:meta_current
	                        ~user_message:latest_user_message
	                        ~assistant_reply:latest_assistant_message
	                    in
                    let response_alignment =
                      match latest_user_message, latest_assistant_message with
                      | Some user_message, Some assistant_message ->
                        jaccard_similarity user_message assistant_message
                      | _ -> 0.0
                    in
                    let auto_rules =
                      evaluate_keeper_auto_rules
                        ~meta:meta_current
                        ~context_ratio:(Context_manager.context_ratio c)
                        ~message_count:(List.length c.messages)
                        ~token_count:c.token_count
                        ~repetition_risk
                        ~goal_alignment
                        ~response_alignment
                    in
	                    let snapshot = `Assoc [
                      ("ts", `String (now_iso ()));
                      ("ts_unix", `Float now_ts);
                      ("channel", `String "heartbeat");
                      ("name", `String meta_current.name);
                      ("agent_name", `String meta_current.agent_name);
                      ("trace_id", `String meta_current.trace_id);
                      ("generation", `Int meta_current.generation);
                      ("model_used", `String meta_current.last_model_used);
                      ("usage", `Assoc [
                        ("input_tokens", `Int 0);
                        ("output_tokens", `Int 0);
                        ("total_tokens", `Int 0);
                      ]);
                      ("latency_ms", `Int 0);
                      ("cost_usd", `Float 0.0);
                      ("context_ratio", `Float (Context_manager.context_ratio c));
                      ("context_tokens", `Int c.token_count);
                      ("context_max", `Int c.max_tokens);
                      ("message_count", `Int (List.length c.messages));
                      ("continuity_state",
                        match continuity_snapshot with
                        | None -> `Null
                        | Some s -> keeper_state_snapshot_to_json s);
                      ("continuity_summary",
                        `String continuity_summary);
                      ("compacted", `Bool false);
                      ("compaction_before_tokens", `Int c.token_count);
                      ("compaction_after_tokens", `Int c.token_count);
                      ("work_kind", `String "status_tick");
                      ("tool_call_count", `Int 0);
                      ("tools_used", `List []);
                      ("snapshot_source", `String "keeper_context_status");
                      ("memory_check", memory_check_default_json ());
                      ("auto_rules", keeper_auto_rule_eval_to_json auto_rules);
                      ("reflection", keeper_reflection_payload_of_auto_rules auto_rules);
                      ("auto_reflect", `Bool auto_rules.reflect);
                      ("auto_plan", `Bool auto_rules.plan);
                      ("auto_compact", `Bool auto_rules.compact);
                      ("auto_handoff", `Bool auto_rules.handoff);
	                      ("repetition_risk", `Float repetition_risk);
	                      ("goal_alignment", `Float goal_alignment);
                      ("response_alignment", `Float response_alignment);
                      ("goal_drift", `Float auto_rules.goal_drift);
                      ("guardrail_stop", `Bool auto_rules.guardrail_stop);
                      ("guardrail_stop_reason",
                        match auto_rules.guardrail_reason with
                        | Some reason -> `String reason
                        | None -> `Null);
	                      ("handoff", `Assoc [("performed", `Bool false)]);
	                    ] in
                    append_jsonl_line metrics_path snapshot;
                    (* SSE: keeper_heartbeat — dashboard real-time monitoring *)
                    (try Sse.broadcast (`Assoc [
                      ("type", `String "keeper_heartbeat");
                      ("name", `String meta_current.name);
                      ("generation", `Int meta_current.generation);
                      ("context_ratio", `Float (Context_manager.context_ratio c));
                      ("ts_unix", `Float now_ts);
                    ]) with exn ->
                      Printf.eprintf "[keeper] heartbeat SSE broadcast failed: %s\n%!" (Printexc.to_string exn)))
             with exn ->
               Printf.eprintf "[keeper] heartbeat snapshot write failed: %s\n%!" (Printexc.to_string exn));
            last_snapshot_ts := now_ts
          end;
          let proactive_warmup_elapsed =
            proactive_warmup_sec <= 0
            || now_ts -. keepalive_started_ts >= float_of_int proactive_warmup_sec
          in
          let meta_after_proactive =
            if proactive_warmup_elapsed
            then (try maybe_emit_proactive ctx meta_current with exn -> Printf.eprintf "[keeper] proactive emission failed: %s\n%!" (Printexc.to_string exn); meta_current)
            else meta_current
          in
          let base = float_of_int (max 30 (min 300 meta_after_proactive.presence_keepalive_sec)) in
          let jitter = base *. 0.2 *. Random.float 1.0 in
          Eio.Time.sleep ctx.clock (base +. jitter);
          loop ()
        end
      in
      loop ())
  end

let stop_keepalive name =
  match Hashtbl.find_opt keepalives name with
  | None -> ()
  | Some stop ->
    stop := true;
    Hashtbl.remove keepalives name

(* --------------------------------------------------------------- *)
(* Handlers                                                         *)
(* --------------------------------------------------------------- *)

let handle_keeper_up ctx args : tool_result =
  let name = get_string args "name" "" in
  if not (validate_name name) then
    (false, "❌ invalid keeper name (allowed: [A-Za-z0-9._-])")
  else
    let soul_profile_opt_res = parse_soul_profile_opt args "soul_profile" in
    let compaction_profile_opt_res =
      parse_compaction_profile_opt args "compaction_profile"
    in
    match soul_profile_opt_res, compaction_profile_opt_res with
    | Error e, _ | _, Error e -> (false, "❌ " ^ e)
    | Ok soul_profile_opt, Ok compaction_profile_opt ->
    let goal_opt = get_string_opt args "goal" in
    let short_goal_opt = parse_goal_horizon_opt args "short_goal" in
    let mid_goal_opt = parse_goal_horizon_opt args "mid_goal" in
    let long_goal_opt = parse_goal_horizon_opt args "long_goal" in
    let models_in = get_string_list args "models" in
    let verify_opt = get_bool_opt args "verify" in
    let presence_keepalive_opt = get_bool_opt args "presence_keepalive" in
    let presence_keepalive_sec_opt = Safe_ops.json_int_opt "presence_keepalive_sec" args in
    let proactive_enabled_opt = get_bool_opt args "proactive_enabled" in
    let proactive_idle_sec_opt = Safe_ops.json_int_opt "proactive_idle_sec" args in
    let proactive_cooldown_sec_opt = Safe_ops.json_int_opt "proactive_cooldown_sec" args in
    let drift_enabled_opt = get_bool_opt args "drift_enabled" in
    let drift_min_turn_gap_opt = Safe_ops.json_int_opt "drift_min_turn_gap" args in
    let compaction_ratio_gate_opt = Safe_ops.json_float_opt "compaction_ratio_gate" args in
    let compaction_message_gate_opt = Safe_ops.json_int_opt "compaction_message_gate" args in
    let compaction_token_gate_opt = Safe_ops.json_int_opt "compaction_token_gate" args in
    let continuity_compaction_cooldown_sec_opt =
      Safe_ops.json_int_opt "continuity_compaction_cooldown_sec" args
    in
    let auto_handoff_opt = get_bool_opt args "auto_handoff" in
    let handoff_threshold_opt = Safe_ops.json_float_opt "handoff_threshold" args in
    let handoff_cooldown_sec_opt = Safe_ops.json_int_opt "handoff_cooldown_sec" args in
    let context_budget_opt = Safe_ops.json_float_opt "context_budget" args in
    let instructions_arg = get_string_opt args "instructions" in
    let soul_path = Filename.concat (Filename.concat (Filename.concat (Filename.concat ctx.config.base_path "memory") "souls") name) "SOUL.md" in
    let soul_content = match Safe_ops.read_file_safe soul_path with Ok c -> c | Error _ -> "" in
    let instructions_opt = if soul_content <> "" then let base = Option.value ~default:"" instructions_arg in Some (base ^ "\n\n[SYSTEM: SOUL INFUSION]\n" ^ soul_content) else instructions_arg in
    let will_opt = parse_self_model_opt args "will" in
    let needs_opt = parse_self_model_opt args "needs" in
    let desires_opt = parse_self_model_opt args "desires" in
    match read_meta ctx.config name with
    | Error e -> (false, Printf.sprintf "❌ %s" e)
  | Ok None ->
      (* Create new keeper *)
      let now_ts = Time_compat.now () in
      let goal = Option.value ~default:"" goal_opt |> normalize_goal_horizon_text in
      if goal = "" then
        (false, "❌ goal is required when creating a keeper")
      else if models_in = [] then
        (false, "❌ models is required when creating a keeper")
      else
        let verify = Option.value ~default:false verify_opt in
        let presence_keepalive = Option.value ~default:true presence_keepalive_opt in
        let presence_keepalive_sec = Option.value ~default:30 presence_keepalive_sec_opt in
        let max_active_keepers = Env_config.KeeperBootstrap.max_active_keepers in
        let active_keepers = running_keepers () in
        if presence_keepalive && max_active_keepers > 0 && active_keepers >= max_active_keepers then
          (false,
            Printf.sprintf
              "❌ keeper keepalive max active reached (%d/%d). Stop/remove a keeper or set MASC_KEEPER_MAX_ACTIVE_KEEPERS."
              active_keepers max_active_keepers)
        else
        let proactive_enabled =
          Option.value ~default:default_proactive_enabled proactive_enabled_opt
        in
        let proactive_idle_sec =
          Option.value ~default:default_proactive_idle_sec proactive_idle_sec_opt
          |> normalize_proactive_idle_sec
        in
        let proactive_cooldown_sec =
          Option.value ~default:default_proactive_cooldown_sec proactive_cooldown_sec_opt
          |> normalize_proactive_cooldown_sec
        in
        let drift_enabled =
          Option.value ~default:default_drift_enabled drift_enabled_opt
        in
        let drift_min_turn_gap =
          Option.value ~default:default_drift_min_turn_gap drift_min_turn_gap_opt
          |> normalize_drift_min_turn_gap
        in
        let auto_handoff = Option.value ~default:true auto_handoff_opt in
        let handoff_threshold = Option.value ~default:0.85 handoff_threshold_opt in
        let handoff_cooldown_sec = Option.value ~default:300 handoff_cooldown_sec_opt in
        let context_budget = Option.value ~default:0.6 context_budget_opt in
        let soul_profile = Option.value ~default:default_soul_profile soul_profile_opt in
        let will = Option.value ~default:default_keeper_will will_opt in
        let needs = Option.value ~default:default_keeper_needs needs_opt in
        let desires = Option.value ~default:default_keeper_desires desires_opt in
        let (short_goal, mid_goal, long_goal) =
          resolve_goal_horizons
            ~goal
            ~short_goal_opt
            ~mid_goal_opt
            ~long_goal_opt
        in
        let instructions = Option.value ~default:"" instructions_opt in
        let (env_ratio_gate, env_message_gate, env_token_gate) =
          keeper_compaction_policy_from_env ()
        in
        let continuity_compaction_cooldown_sec =
          Option.value
            ~default:(keeper_continuity_compaction_cooldown_sec ())
            continuity_compaction_cooldown_sec_opt
          |> normalize_continuity_compaction_cooldown_sec
        in
        let (compaction_profile, compaction_ratio_gate, compaction_message_gate, compaction_token_gate) =
          resolve_compaction_policy
            ~profile_opt:compaction_profile_opt
            ~ratio_opt:compaction_ratio_gate_opt
            ~message_opt:compaction_message_gate_opt
            ~token_opt:compaction_token_gate_opt
            ~fallback_profile:default_compaction_profile
            ~fallback_ratio:env_ratio_gate
            ~fallback_message:env_message_gate
            ~fallback_token:env_token_gate
        in
        (match model_specs_of_strings models_in with
         | Error e -> (false, "❌ " ^ e)
         | Ok specs ->
           (match ensure_api_keys specs with
           | Error e -> (false, "❌ " ^ e)
           | Ok () ->
             let trace_id = generate_trace_id () in
             let primary = match specs with
               | m :: _ -> m
               | [] -> Llm_client.default_local_model_spec ()
             in
             let base_dir = session_base_dir ctx.config in
             mkdir_p base_dir;
             let session = Context_manager.create_session ~session_id:trace_id ~base_dir in
               let system_prompt =
                 build_keeper_system_prompt
                   ~goal
                   ~short_goal
                   ~mid_goal
                   ~long_goal
                   ~soul_profile
                   ~will
                   ~needs
                   ~desires
                   ~instructions
             in
             let ctx0 = Context_manager.create ~system_prompt ~max_tokens:primary.max_context in
             (try ignore (save_checkpoint session ctx0 ~generation:0)
              with exn -> Printf.eprintf "[keeper] save_checkpoint (init) failed: %s\n%!" (Printexc.to_string exn));
             let meta = {
               name;
               agent_name = keeper_agent_name name;
               trace_id;
               trace_history = [];
               goal;
               short_goal;
               mid_goal;
               long_goal;
               soul_profile;
               will;
               needs;
               desires;
               instructions;
               models = models_in;
               generation = 0;
               verify;
               presence_keepalive;
               presence_keepalive_sec;
               proactive_enabled;
               proactive_idle_sec;
               proactive_cooldown_sec;
               drift_enabled;
               drift_min_turn_gap;
               drift_count_total = 0;
               last_drift_turn = 0;
               last_drift_reason = "";
               compaction_profile;
               compaction_ratio_gate;
               compaction_message_gate;
               compaction_token_gate;
               continuity_compaction_cooldown_sec;
               auto_handoff;
               handoff_threshold;
               handoff_cooldown_sec;
               context_budget;
               last_handoff_ts = 0.0;
               created_at = now_iso ();
               updated_at = now_iso ();
               total_turns = 0;
               total_input_tokens = 0;
               total_output_tokens = 0;
               total_tokens = 0;
               total_cost_usd = 0.0;
               last_turn_ts = 0.0;
               last_model_used = "";
               last_input_tokens = 0;
               last_output_tokens = 0;
               last_total_tokens = 0;
               last_latency_ms = 0;
               compaction_count = 0;
               last_compaction_ts = 0.0;
               last_compaction_before_tokens = 0;
               last_compaction_after_tokens = 0;
               last_compaction_check_ts = now_ts;
               last_compaction_decision = "initialized";
               proactive_count_total = 0;
               last_proactive_ts = 0.0;
                last_proactive_reason = "";
                last_proactive_preview = "";
                last_continuity_update_ts = now_ts;
                continuity_summary = "";
                autonomy_level = "l1_reactive";
                active_goal_ids = [];
                last_autonomous_action_at = "";
                autonomous_action_count = 0;
             } in
             match write_meta ctx.config meta with
             | Error e -> (false, "❌ " ^ e)
             | Ok () ->
               start_keepalive ctx meta;
               let json = `Assoc [
                 ("name", `String meta.name);
                 ("agent_name", `String meta.agent_name);
                 ("trace_id", `String meta.trace_id);
                 ("generation", `Int meta.generation);
                 ("goal", `String meta.goal);
                 ("short_goal", `String meta.short_goal);
                 ("mid_goal", `String meta.mid_goal);
                 ("long_goal", `String meta.long_goal);
                 ("soul_profile", `String meta.soul_profile);
                 ("will", `String meta.will);
                 ("needs", `String meta.needs);
                 ("desires", `String meta.desires);
                 ("instructions", `String meta.instructions);
                 ("models", `List (List.map (fun s -> `String s) meta.models));
                 ("presence_keepalive", `Bool meta.presence_keepalive);
                 ("presence_keepalive_sec", `Int meta.presence_keepalive_sec);
                 ("proactive_enabled", `Bool meta.proactive_enabled);
                 ("proactive_idle_sec", `Int meta.proactive_idle_sec);
                 ("proactive_cooldown_sec", `Int meta.proactive_cooldown_sec);
                 ("drift_enabled", `Bool meta.drift_enabled);
                 ("drift_min_turn_gap", `Int meta.drift_min_turn_gap);
                 ("compaction_profile", `String meta.compaction_profile);
                 ("compaction_ratio_gate", `Float meta.compaction_ratio_gate);
                 ("compaction_message_gate", `Int meta.compaction_message_gate);
                 ("compaction_token_gate", `Int meta.compaction_token_gate);
                 ("auto_handoff", `Bool meta.auto_handoff);
                 ("handoff_threshold", `Float meta.handoff_threshold);
               ] in
               (true, Yojson.Safe.pretty_to_string json)))
    | Ok (Some old) ->
      (* Update existing keeper meta (goal/models optional) *)
      let goal_provided = Option.is_some goal_opt in
      let goal =
        match goal_opt with
        | Some g -> normalize_goal_horizon_text g
        | None -> old.goal
      in
      let short_goal_default = if goal_provided then goal else old.short_goal in
      let mid_goal_default = if goal_provided then goal else old.mid_goal in
      let long_goal_default = if goal_provided then goal else old.long_goal in
      let short_goal =
        Option.value ~default:short_goal_default short_goal_opt
        |> normalize_goal_horizon_text
      in
      let mid_goal =
        Option.value ~default:mid_goal_default mid_goal_opt
        |> normalize_goal_horizon_text
      in
      let long_goal =
        Option.value ~default:long_goal_default long_goal_opt
        |> normalize_goal_horizon_text
      in
      let models = if models_in <> [] then models_in else old.models in
      let (compaction_profile, compaction_ratio_gate, compaction_message_gate, compaction_token_gate) =
        resolve_compaction_policy
          ~profile_opt:compaction_profile_opt
          ~ratio_opt:compaction_ratio_gate_opt
          ~message_opt:compaction_message_gate_opt
          ~token_opt:compaction_token_gate_opt
          ~fallback_profile:old.compaction_profile
          ~fallback_ratio:old.compaction_ratio_gate
          ~fallback_message:old.compaction_message_gate
          ~fallback_token:old.compaction_token_gate
      in
      let updated = { old with
        goal;
        short_goal;
        mid_goal;
        long_goal;
        soul_profile = Option.value ~default:old.soul_profile soul_profile_opt;
        will = Option.value ~default:old.will will_opt;
        needs = Option.value ~default:old.needs needs_opt;
        desires = Option.value ~default:old.desires desires_opt;
        instructions = Option.value ~default:old.instructions instructions_opt;
        models;
        verify = Option.value ~default:old.verify verify_opt;
        presence_keepalive = Option.value ~default:old.presence_keepalive presence_keepalive_opt;
        presence_keepalive_sec = Option.value ~default:old.presence_keepalive_sec presence_keepalive_sec_opt;
        proactive_enabled = Option.value ~default:old.proactive_enabled proactive_enabled_opt;
        proactive_idle_sec =
          Option.value ~default:old.proactive_idle_sec proactive_idle_sec_opt
          |> normalize_proactive_idle_sec;
        proactive_cooldown_sec =
          Option.value ~default:old.proactive_cooldown_sec proactive_cooldown_sec_opt
          |> normalize_proactive_cooldown_sec;
        drift_enabled = Option.value ~default:old.drift_enabled drift_enabled_opt;
        drift_min_turn_gap =
          Option.value ~default:old.drift_min_turn_gap drift_min_turn_gap_opt
          |> normalize_drift_min_turn_gap;
        compaction_profile;
        compaction_ratio_gate;
        compaction_message_gate;
        compaction_token_gate;
        continuity_compaction_cooldown_sec =
          Option.value
            ~default:old.continuity_compaction_cooldown_sec
            continuity_compaction_cooldown_sec_opt
          |> normalize_continuity_compaction_cooldown_sec;
        auto_handoff = Option.value ~default:old.auto_handoff auto_handoff_opt;
        handoff_threshold = Option.value ~default:old.handoff_threshold handoff_threshold_opt;
        handoff_cooldown_sec = Option.value ~default:old.handoff_cooldown_sec handoff_cooldown_sec_opt;
        context_budget = Option.value ~default:old.context_budget context_budget_opt;
        updated_at = now_iso ();
      } in
      (match write_meta ctx.config updated with
       | Error e -> (false, "❌ " ^ e)
       | Ok () ->
         stop_keepalive updated.name;
         start_keepalive ctx updated;
         (true, Yojson.Safe.pretty_to_string (meta_to_json updated)))

let handle_keeper_status ctx args : tool_result =
  let name = get_string args "name" "" in
  if not (validate_name name) then
    (false, "❌ invalid keeper name")
  else
    match read_meta ctx.config name with
    | Error e -> (false, "❌ " ^ e)
    | Ok None -> (false, Printf.sprintf "❌ keeper not found: %s" name)
    | Ok (Some m) ->
      let tail_turns = max 0 (get_int args "tail_turns" 3) in
      let tail_messages = max 0 (get_int args "tail_messages" 5) in
      let tail_compactions = max 0 (get_int args "tail_compactions" 10) in
      let tail_bytes = max 1_000 (get_int args "tail_bytes" 60_000) in
      let fast = get_bool args "fast" (keeper_status_fast_default ()) in
      let include_context = get_bool args "include_context" (not fast) in
      let include_metrics_overview =
        get_bool args "include_metrics_overview" (not fast)
      in
      let include_memory_bank = get_bool args "include_memory_bank" (not fast) in
      let include_history_tail = get_bool args "include_history_tail" (not fast) in
      let include_compaction_history =
        get_bool args "include_compaction_history" (not fast)
      in
      let models = m.models in
      (match model_specs_of_strings models with
       | Error e -> (false, "❌ " ^ e)
       | Ok specs ->
         let primary = match specs with m0 :: _ -> m0 | [] -> Llm_client.default_local_model_spec () in
         let base_dir = session_base_dir ctx.config in
         let ctx_opt =
           if include_context then
             let (_session, ctx_opt) =
               load_context_from_checkpoint
                 ~trace_id:m.trace_id
                 ~primary_model_max_tokens:primary.max_context
                 ~base_dir
             in
             ctx_opt
           else
             None
         in
         let ctx_stats =
           if not include_context then
             `Assoc [
               ("skipped", `Bool true);
               ("reason", `String "fast_or_disabled");
               ("has_checkpoint", `Null);
             ]
           else
             match ctx_opt with
             | None -> `Assoc [("has_checkpoint", `Bool false)]
             | Some c ->
               `Assoc [
                 ("has_checkpoint", `Bool true);
                 ("context_ratio", `Float (Context_manager.context_ratio c));
                 ("context_tokens", `Int c.token_count);
                 ("context_max", `Int c.max_tokens);
                 ("message_count", `Int (List.length c.messages));
               ]
         in
         let keepalive_running = keeper_keepalive_running m.name in
         let agent_status = parse_agent_status ctx.config ~agent_name:m.agent_name in
         let now_ts = Time_compat.now () in
         let created_ts =
           Resilience.Time.parse_iso8601_opt m.created_at |> Option.value ~default:0.0
         in
         let keeper_age_s = if created_ts <= 0.0 then 0.0 else now_ts -. created_ts in
         let last_turn_ago_s = if m.last_turn_ts <= 0.0 then 0.0 else now_ts -. m.last_turn_ts in
         let last_handoff_ago_s = if m.last_handoff_ts <= 0.0 then 0.0 else now_ts -. m.last_handoff_ts in
         let last_compaction_ago_s = if m.last_compaction_ts <= 0.0 then 0.0 else now_ts -. m.last_compaction_ts in
         let last_proactive_ago_s =
           if m.last_proactive_ts <= 0.0 then 0.0 else now_ts -. m.last_proactive_ts
         in
         let trace_history_count = List.length m.trace_history in
         let active_model = active_model_of_meta m in
         let next_model_hint = next_model_hint_of_meta m in
         let last_compaction_saved_tokens =
           max 0 (m.last_compaction_before_tokens - m.last_compaction_after_tokens)
         in
         let (compact_ratio_gate, compact_message_gate, compact_token_gate) =
           compaction_policy_of_keeper m
         in

         let models_resolved = `List (List.map (fun (s : Llm_client.model_spec) ->
           `Assoc [
             ("provider", `String (Llm_client.string_of_provider s.provider));
             ("model_id", `String s.model_id);
             ("max_context", `Int s.max_context);
             ("api_key_env", match s.api_key_env with None -> `Null | Some k -> `String k);
           ]
         ) specs) in

         let metrics_path = keeper_metrics_path ctx.config m.name in
         let memory_bank_path = keeper_memory_bank_path ctx.config m.name in
         let session_dir = keeper_session_dir ctx.config m.trace_id in
         let history_path = keeper_history_path ctx.config m.trace_id in

         let metrics_tail =
           let lines =
             read_file_tail_lines metrics_path
               ~max_bytes:tail_bytes
               ~max_lines:tail_turns
           in
           `List
             (List.filter_map
                (fun line ->
                  try Some (Yojson.Safe.from_string line) with Yojson.Json_error _ -> None)
                lines)
         in
         let metrics_window_lines =
           if include_metrics_overview then
             read_file_tail_lines metrics_path
               ~max_bytes:tail_bytes
               ~max_lines:(max tail_turns 200)
           else
             []
         in
         let metrics_overview =
           if include_metrics_overview then
             summarize_metrics_lines
               metrics_window_lines
               ~default_generation:m.generation
           else
             empty_metrics_summary
         in
         let last_skill_route =
           if not include_metrics_overview then
             None
           else
             let open Yojson.Safe.Util in
             let rec find_latest = function
               | [] -> None
               | line :: tl ->
                 (try
                    let j = Yojson.Safe.from_string line in
                    match Safe_ops.json_string_opt "skill_primary" j with
                    | Some primary when String.trim primary <> "" ->
                      let secondary =
                        match j |> member "skill_secondary" with
                        | `List xs ->
                          xs
                          |> List.filter_map (fun v ->
                               match v with
                               | `String s when String.trim s <> "" -> Some s
                               | _ -> None)
                        | _ -> []
                      in
                      let reason = Safe_ops.json_string_opt "skill_reason" j in
                      Some
                        (`Assoc
                           [
                             ("primary", `String primary);
                             ( "secondary",
                               `List (List.map (fun s -> `String s) secondary) );
                             ( "reason",
                               match reason with
                               | Some s -> `String s
                               | None -> `Null );
                           ])
                    | _ -> find_latest tl
                  with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> find_latest tl)
             in
             find_latest (List.rev metrics_window_lines)
         in
         let memory_bank_summary =
           if include_memory_bank then
             read_keeper_memory_summary
               ctx.config
               ~name:m.name
               ~max_bytes:tail_bytes
               ~max_lines:(max (tail_turns * 10) 400)
               ~recent_limit:8
           else
             {
               total_notes = 0;
               last_ts_unix = 0.0;
               top_kind = None;
               kind_counts = [];
               recent_notes = [];
             }
         in

         let history_filter_fragments =
           bool_default_true_of_env "MASC_KEEPER_HISTORY_FRAGMENT_FILTER"
         in
         let (history_tail, history_raw_count, history_fragment_count, history_fragment_filtered_count) =
           if not include_history_tail then
             (`List [], 0, 0, 0)
           else
             let lines =
               read_file_tail_lines history_path
                 ~max_bytes:tail_bytes
                 ~max_lines:tail_messages
             in
             let open Yojson.Safe.Util in
             let (items_rev, raw_count, fragment_count, filtered_count) =
               List.fold_left
                 (fun (acc, raw_count, fragment_count, filtered_count) line ->
                   try
                     let j = Yojson.Safe.from_string line in
                     let role =
                       j |> member "role" |> to_string_option
                       |> Option.value ~default:"unknown"
                     in
                     let content =
                       j |> member "content" |> to_string_option
                       |> Option.value ~default:""
                     in
                     let ts_unix =
                       let ts0 = Safe_ops.json_float ~default:0.0 "ts_unix" j in
                       if ts0 > 0.0 then ts0
                       else Safe_ops.json_float ~default:0.0 "timestamp" j
                     in
                     let age_s =
                       if ts_unix > 0.0 then Some (max 0.0 (now_ts -. ts_unix))
                       else None
                     in
                     let role_lc = String.lowercase_ascii role in
                     let entry_kind =
                       match role_lc with
                       | "assistant" -> "self_talk"
                       | "user" -> "input"
                       | "tool" -> "tool_result"
                       | "system" -> "system"
                       | _ -> "other"
                     in
                     let is_fragment =
                       role_lc = "assistant"
                       && looks_fragmentary_history_text content
                     in
                     let should_filter = history_filter_fragments && is_fragment in
                     let preview =
                       if String.length content > 200 then
                         utf8_safe_prefix_bytes content ~max_bytes:200 ^ "..."
                       else content
                     in
                     let item =
                       `Assoc [
                         ("role", `String role);
                         ("kind", `String entry_kind);
                         ("is_fragment", `Bool is_fragment);
                         ("ts_unix", `Float ts_unix);
                         ("age_s", match age_s with Some v -> `Float v | None -> `Null);
                         ("content", `String preview);
                       ]
                     in
                     let acc = if should_filter then acc else item :: acc in
                     let filtered_count =
                       filtered_count + if should_filter then 1 else 0
                     in
                     ( acc,
                       raw_count + 1,
                       fragment_count + (if is_fragment then 1 else 0),
                       filtered_count )
                   with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> (acc, raw_count, fragment_count, filtered_count))
                 ([], 0, 0, 0) lines
             in
             (`List (List.rev items_rev), raw_count, fragment_count, filtered_count)
         in
         let history_items =
           match history_tail with
           | `List xs -> xs
           | _ -> []
         in
         let diagnostic =
           keeper_diagnostic_json
             ~meta:m
             ~agent_status
             ~keepalive_running
             ~history_items
             ~now_ts
         in

         let compaction_history_tail =
           if not include_compaction_history then
             (`List [], 0)
           else
             let lines =
               read_file_tail_lines metrics_path
                 ~max_bytes:tail_bytes
                 ~max_lines:(max 200 (tail_compactions * 20))
             in
             let events_rev =
               List.fold_left
                 (fun acc line ->
                   try
                     let j = Yojson.Safe.from_string line in
                     let compacted = Safe_ops.json_bool ~default:false "compacted" j in
                     let memory_compaction_performed =
                       Safe_ops.json_bool ~default:false "memory_compaction_performed" j
                     in
                     if (not compacted) && (not memory_compaction_performed) then acc
                     else
                       let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" j in
                       let age_s =
                         if ts_unix > 0.0 then Some (max 0.0 (now_ts -. ts_unix)) else None
                       in
                       let before_tokens = Safe_ops.json_int ~default:0 "compaction_before_tokens" j in
                       let after_tokens = Safe_ops.json_int ~default:0 "compaction_after_tokens" j in
                       let saved_tokens = max 0 (before_tokens - after_tokens) in
                       let memory_before_notes =
                         Safe_ops.json_int ~default:0 "memory_compaction_before_notes" j
                       in
                       let memory_after_notes =
                         Safe_ops.json_int ~default:0 "memory_compaction_after_notes" j
                       in
                       let memory_dropped_notes =
                         Safe_ops.json_int ~default:0 "memory_compaction_dropped_notes" j
                       in
                       let memory_invalid_dropped =
                         Safe_ops.json_int ~default:0 "memory_compaction_invalid_dropped" j
                       in
                       let event_kind =
                         if compacted && memory_compaction_performed then "context+memory"
                         else if compacted then "context"
                         else "memory"
                       in
                       let item =
                         `Assoc [
                           ("kind", `String event_kind);
                           ("channel", `String (Safe_ops.json_string ~default:"turn" "channel" j));
                           ("ts_unix", `Float ts_unix);
                           ("age_s", match age_s with Some v -> `Float v | None -> `Null);
                           ("trace_id", `String (Safe_ops.json_string ~default:"" "trace_id" j));
                           ("generation", `Int (Safe_ops.json_int ~default:m.generation "generation" j));
                           ("context_ratio", `Float (Safe_ops.json_float ~default:0.0 "context_ratio" j));
                           ("context_before_tokens", `Int before_tokens);
                           ("context_after_tokens", `Int after_tokens);
                           ("context_saved_tokens", `Int saved_tokens);
                           ( "context_trigger",
                             match Safe_ops.json_string_opt "compaction_trigger" j with
                             | Some reason when String.trim reason <> "" -> `String reason
                             | _ -> `Null );
                           ("memory_compaction_performed", `Bool memory_compaction_performed);
                           ("memory_before_notes", `Int memory_before_notes);
                           ("memory_after_notes", `Int memory_after_notes);
                           ("memory_dropped_notes", `Int memory_dropped_notes);
                           ("memory_invalid_dropped", `Int memory_invalid_dropped);
                           ( "memory_reason",
                             match Safe_ops.json_string_opt "memory_compaction_reason" j with
                             | Some reason when String.trim reason <> "" -> `String reason
                             | _ -> `Null );
                         ]
                       in
                       item :: acc
                   with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> acc)
                 [] lines
             in
             let events = List.rev events_rev in
             let total = List.length events in
             let start = max 0 (total - tail_compactions) in
             let tail = List.filteri (fun i _ -> i >= start) events in
             (`List tail, total)
         in

         let json = `Assoc [
           ("meta", meta_to_json m);
           ("goal", `String m.goal);
           ("short_goal", `String m.short_goal);
           ("mid_goal", `String m.mid_goal);
           ("long_goal", `String m.long_goal);
           ("goal_horizons", `Assoc [
             ("short", `String m.short_goal);
             ("mid", `String m.mid_goal);
             ("long", `String m.long_goal);
           ]);
           ("soul_profile", `String m.soul_profile);
           ("will", if String.trim m.will = "" then `Null else `String m.will);
           ("needs", if String.trim m.needs = "" then `Null else `String m.needs);
           ("desires", if String.trim m.desires = "" then `Null else `String m.desires);
           ("self_model", `Assoc [
             ("will", if String.trim m.will = "" then `Null else `String m.will);
             ("needs", if String.trim m.needs = "" then `Null else `String m.needs);
             ("desires", if String.trim m.desires = "" then `Null else `String m.desires);
           ]);
           ("keepalive_running", `Bool keepalive_running);
           ("agent", agent_status);
           ("diagnostic", diagnostic);
           ("keeper_age_s", `Float keeper_age_s);
           ("last_turn_ago_s", `Float last_turn_ago_s);
           ("last_handoff_ago_s", `Float last_handoff_ago_s);
           ("last_compaction_ago_s", `Float last_compaction_ago_s);
           ("last_proactive_ago_s", `Float last_proactive_ago_s);
           ("active_model", `String active_model);
           ("next_model_hint", match next_model_hint with Some s -> `String s | None -> `Null);
           ("trace_history_count", `Int trace_history_count);
           ("handoff_count_total", `Int trace_history_count);
           ("last_compaction_saved_tokens", `Int last_compaction_saved_tokens);
           ("lifecycle", `Assoc [
             ("created_at", `String m.created_at);
             ("updated_at", `String m.updated_at);
             ("uptime_hours", `Float (keeper_age_s /. 3600.0));
           ]);
           ("proactive", `Assoc [
             ("enabled", `Bool m.proactive_enabled);
             ("idle_sec", `Int m.proactive_idle_sec);
             ("cooldown_sec", `Int m.proactive_cooldown_sec);
             ("count_total", `Int m.proactive_count_total);
             ("last_ts", `Float m.last_proactive_ts);
             ("last_ago_s", `Float last_proactive_ago_s);
             ("last_reason",
               if String.trim m.last_proactive_reason = ""
               then `Null
               else `String m.last_proactive_reason);
             ("last_preview",
               if String.trim m.last_proactive_preview = ""
               then `Null
               else `String m.last_proactive_preview);
           ]);
           ("drift", `Assoc [
             ("enabled", `Bool m.drift_enabled);
             ("min_turn_gap", `Int m.drift_min_turn_gap);
             ("count_total", `Int m.drift_count_total);
             ("last_turn", `Int m.last_drift_turn);
             ("last_reason",
               if String.trim m.last_drift_reason = ""
               then `Null
               else `String m.last_drift_reason);
           ]);
           ("compaction_policy", `Assoc [
             ("profile", `String m.compaction_profile);
             ("ratio_gate", `Float compact_ratio_gate);
             ("message_gate", `Int compact_message_gate);
             ("token_gate", `Int compact_token_gate);
             ("token_gate_enabled", `Bool (compact_token_gate > 0));
           ]);
           ("status_options", `Assoc [
             ("fast", `Bool fast);
             ("include_context", `Bool include_context);
             ("include_metrics_overview", `Bool include_metrics_overview);
             ("include_memory_bank", `Bool include_memory_bank);
             ("include_history_tail", `Bool include_history_tail);
             ("include_compaction_history", `Bool include_compaction_history);
           ]);
	           ("models_resolved", models_resolved);
	           ("context", ctx_stats);
	           ("skill_route", match last_skill_route with Some v -> v | None -> `Null);
	           ("metrics_overview", metrics_summary_to_json metrics_overview);
	           ("memory_bank", memory_summary_to_json memory_bank_summary);
           ("metrics_tail", metrics_tail);
           ("history_tail", history_tail);
           ("history_tail_count",
             match history_tail with
             | `List xs -> `Int (List.length xs)
             | _ -> `Int 0);
           ("history_raw_count", `Int history_raw_count);
           ("history_fragment_count", `Int history_fragment_count);
           ("history_fragment_filtered_count", `Int history_fragment_filtered_count);
           ("history_fragment_filter_enabled", `Bool history_filter_fragments);
           ("compaction_history_tail", fst compaction_history_tail);
           ("compaction_history_count", `Int (snd compaction_history_tail));
           ("storage_paths", `Assoc [
             ("meta", `String (keeper_meta_path ctx.config m.name));
             ("metrics", `String metrics_path);
             ("memory_bank", `String memory_bank_path);
             ("session_dir", `String session_dir);
             ("history", `String history_path);
           ]);
         ] in
         (true, Yojson.Safe.pretty_to_string json))

let handle_keeper_msg ctx args : tool_result =
  let name = get_string args "name" "" in
  let message = get_string args "message" "" in
  if not (validate_name name) then
    (false, "❌ invalid keeper name")
  else if message = "" then
    (false, "❌ message is required")
  else
    let inline_goal = get_string_opt args "goal" in
    let inline_short_goal = parse_goal_horizon_opt args "short_goal" in
    let inline_mid_goal = parse_goal_horizon_opt args "mid_goal" in
    let inline_long_goal = parse_goal_horizon_opt args "long_goal" in
    let inline_instructions = get_string_opt args "instructions" in
    let turn_instructions = get_string_opt args "turn_instructions" in
    let no_skill_route = get_bool args "no_skill_route" false in
    let no_state_block = get_bool args "no_state_block" false in
    let inline_will = parse_self_model_opt args "will" in
    let inline_needs = parse_self_model_opt args "needs" in
    let inline_desires = parse_self_model_opt args "desires" in
    let inline_drift_enabled_opt = get_bool_opt args "drift_enabled" in
    let inline_drift_min_turn_gap_opt = Safe_ops.json_int_opt "drift_min_turn_gap" args in
    let inline_soul_profile_res = parse_soul_profile_opt args "soul_profile" in
    let new_soul_profile_res = parse_soul_profile_opt args "new_soul_profile" in
    let new_short_goal = parse_goal_horizon_opt args "new_short_goal" in
    let new_mid_goal = parse_goal_horizon_opt args "new_mid_goal" in
    let new_long_goal = parse_goal_horizon_opt args "new_long_goal" in
    let new_will = parse_self_model_opt args "new_will" in
    let new_needs = parse_self_model_opt args "new_needs" in
    let new_desires = parse_self_model_opt args "new_desires" in
    let new_drift_enabled_opt = get_bool_opt args "new_drift_enabled" in
    let new_drift_min_turn_gap_opt = Safe_ops.json_int_opt "new_drift_min_turn_gap" args in
    let inline_models = get_string_list args "models" in
    let require_existing = get_bool args "require_existing" false in
    let timeout_sec_opt =
      Safe_ops.json_float_opt "timeout_sec" args
      |> Option.map (fun v ->
             let sec = int_of_float (Float.ceil v) in
             max 5 (min 300 sec))
    in
    let ollama_timeout_sec_opt =
      Safe_ops.json_float_opt "ollama_timeout_sec" args
      |> Option.map (fun v ->
             let sec = int_of_float (Float.ceil v) in
             max 10 (min 300 sec))
    in
    match inline_soul_profile_res, new_soul_profile_res with
    | Error e, _ | _, Error e -> (false, "❌ " ^ e)
    | Ok inline_soul_profile, Ok new_soul_profile ->
    (* Ensure keeper exists (create inline if missing) *)
    let ensure_keeper () : (keeper_meta, string) result =
      match read_meta ctx.config name with
      | Error e -> Error e
      | Ok (Some m) -> Ok m
      | Ok None ->
          if require_existing then
            Error (Printf.sprintf "keeper not found: %s" name)
          else
          let goal = Option.value ~default:"" inline_goal |> normalize_goal_horizon_text in
          if goal = "" then Error "keeper not found and goal not provided"
          else if inline_models = [] then Error "keeper not found and models not provided"
          else
          let now_ts = Time_compat.now () in
          let trace_id = generate_trace_id () in
          let soul_profile =
            Option.value ~default:default_soul_profile inline_soul_profile
          in
          let will = Option.value ~default:default_keeper_will inline_will in
          let needs = Option.value ~default:default_keeper_needs inline_needs in
          let desires = Option.value ~default:default_keeper_desires inline_desires in
          let drift_enabled =
            Option.value ~default:default_drift_enabled inline_drift_enabled_opt
          in
          let drift_min_turn_gap =
            Option.value ~default:default_drift_min_turn_gap inline_drift_min_turn_gap_opt
            |> normalize_drift_min_turn_gap
          in
          let (env_ratio_gate, env_message_gate, env_token_gate) =
            keeper_compaction_policy_from_env ()
          in
          let continuity_compaction_cooldown_sec =
            keeper_continuity_compaction_cooldown_sec ()
            |> normalize_continuity_compaction_cooldown_sec
          in
          let (short_goal, mid_goal, long_goal) =
            resolve_goal_horizons
              ~goal
              ~short_goal_opt:inline_short_goal
              ~mid_goal_opt:inline_mid_goal
              ~long_goal_opt:inline_long_goal
          in
          let instructions = Option.value ~default:"" inline_instructions in
          let meta = {
            name;
            agent_name = keeper_agent_name name;
            trace_id;
            trace_history = [];
            goal;
            short_goal;
            mid_goal;
            long_goal;
            soul_profile;
            will;
            needs;
            desires;
            instructions;
            models = inline_models;
            generation = 0;
            verify = false;
            presence_keepalive = true;
            presence_keepalive_sec = 30;
            proactive_enabled = default_proactive_enabled;
            proactive_idle_sec = default_proactive_idle_sec;
            proactive_cooldown_sec = default_proactive_cooldown_sec;
            drift_enabled;
            drift_min_turn_gap;
            drift_count_total = 0;
            last_drift_turn = 0;
            last_drift_reason = "";
            compaction_profile = default_compaction_profile;
            compaction_ratio_gate = env_ratio_gate;
            compaction_message_gate = env_message_gate;
            compaction_token_gate = env_token_gate;
            continuity_compaction_cooldown_sec;
            auto_handoff = true;
            handoff_threshold = 0.85;
            handoff_cooldown_sec = 300;
            context_budget = 0.6;
            last_handoff_ts = 0.0;
            created_at = now_iso ();
            updated_at = now_iso ();
            total_turns = 0;
            total_input_tokens = 0;
            total_output_tokens = 0;
            total_tokens = 0;
            total_cost_usd = 0.0;
            last_turn_ts = 0.0;
            last_model_used = "";
            last_input_tokens = 0;
            last_output_tokens = 0;
            last_total_tokens = 0;
            last_latency_ms = 0;
            compaction_count = 0;
            last_compaction_ts = 0.0;
            last_compaction_before_tokens = 0;
            last_compaction_after_tokens = 0;
            last_compaction_check_ts = now_ts;
            last_compaction_decision = "initialized";
            proactive_count_total = 0;
            last_proactive_ts = 0.0;
            last_proactive_reason = "";
            last_proactive_preview = "";
            last_continuity_update_ts = now_ts;
            continuity_summary = "";
            autonomy_level = "l1_reactive";
            active_goal_ids = [];
            last_autonomous_action_at = "";
            autonomous_action_count = 0;
          } in
          let base_dir = session_base_dir ctx.config in
          mkdir_p base_dir;
          (match model_specs_of_strings meta.models with
           | Error e -> Error e
           | Ok specs ->
             (match ensure_api_keys specs with
              | Error e -> Error e
              | Ok () ->
                let primary = match specs with m0 :: _ -> m0 | [] -> Llm_client.default_local_model_spec () in
                let session = Context_manager.create_session ~session_id:trace_id ~base_dir in
                let system_prompt =
                  build_keeper_system_prompt
                    ~goal
                    ~short_goal
                    ~mid_goal
                    ~long_goal
                    ~soul_profile
                    ~will
                    ~needs
                    ~desires
                    ~instructions
                in
                let ctx0 = Context_manager.create ~system_prompt ~max_tokens:primary.max_context in
                (try ignore (save_checkpoint session ctx0 ~generation:0)
                 with exn -> Printf.eprintf "[keeper] save_checkpoint (ensure) failed: %s\n%!" (Printexc.to_string exn));
                match write_meta ctx.config meta with
                | Error e -> Error e
                | Ok () -> Ok meta))
    in
    match ensure_keeper () with
    | Error e -> (false, "❌ " ^ e)
    | Ok meta0 ->
      (* Update keeper settings inline if requested. *)
      let meta =
        let new_goal_opt = normalize_goal_horizon_opt (get_string_opt args "new_goal") in
        let goal =
          match new_goal_opt with
          | None -> meta0.goal
          | Some ng -> ng
        in
        let goal_provided = Option.is_some new_goal_opt in
        let short_goal_default = if goal_provided then goal else meta0.short_goal in
        let mid_goal_default = if goal_provided then goal else meta0.mid_goal in
        let long_goal_default = if goal_provided then goal else meta0.long_goal in
        let short_goal =
          Option.value ~default:short_goal_default new_short_goal
          |> normalize_goal_horizon_text
        in
        let mid_goal =
          Option.value ~default:mid_goal_default new_mid_goal
          |> normalize_goal_horizon_text
        in
        let long_goal =
          Option.value ~default:long_goal_default new_long_goal
          |> normalize_goal_horizon_text
        in
        let soul_profile =
          match new_soul_profile with
          | None -> meta0.soul_profile
          | Some sp -> sp
        in
        let instructions =
          match get_string_opt args "new_instructions" with
          | None -> meta0.instructions
          | Some ni -> ni
        in
        let will =
          match new_will with
          | None -> meta0.will
          | Some w -> w
        in
        let needs =
          match new_needs with
          | None -> meta0.needs
          | Some n -> n
        in
        let desires =
          match new_desires with
          | None -> meta0.desires
          | Some d -> d
        in
        let drift_enabled =
          match new_drift_enabled_opt with
          | None -> meta0.drift_enabled
          | Some v -> v
        in
        let drift_min_turn_gap =
          match new_drift_min_turn_gap_opt with
          | None -> meta0.drift_min_turn_gap
          | Some v -> normalize_drift_min_turn_gap v
        in
        if goal = meta0.goal
           && short_goal = meta0.short_goal
           && mid_goal = meta0.mid_goal
           && long_goal = meta0.long_goal
           && soul_profile = meta0.soul_profile
           && will = meta0.will
           && needs = meta0.needs
           && desires = meta0.desires
           && instructions = meta0.instructions
           && drift_enabled = meta0.drift_enabled
           && drift_min_turn_gap = meta0.drift_min_turn_gap
        then
          meta0
        else
          let updated = {
            meta0 with
            goal;
            short_goal;
            mid_goal;
            long_goal;
            soul_profile;
            will;
            needs;
            desires;
            instructions;
            drift_enabled;
            drift_min_turn_gap;
            updated_at = now_iso ();
          } in
          (try ignore (write_meta ctx.config updated)
           with exn -> Printf.eprintf "[keeper] write_meta (settings) failed: %s\n%!" (Printexc.to_string exn));
          updated
      in
      start_keepalive ctx meta;
      (* === Harness: trajectory accumulator + eval gate config === *)
      let masc_root = Filename.concat ctx.config.base_path ".masc" in
      let trajectory_acc =
        Trajectory.create_accumulator
          ~masc_root
          ~keeper_name:meta.name
          ~trace_id:meta.trace_id
          ~generation:meta.generation
      in
      let gate_config = Eval_gate.default_config in
      let effective_models =
        if inline_models <> [] then inline_models else meta.models
      in
      let effective_models =
        maybe_append_keeper_fallback_models effective_models
      in
      (match model_specs_of_strings effective_models with
       | Error e -> (false, "❌ " ^ e)
       | Ok specs ->
         (match ensure_api_keys specs with
          | Error e -> (false, "❌ " ^ e)
          | Ok () ->
            let primary = match specs with m0 :: _ -> m0 | [] -> Llm_client.default_local_model_spec () in
            let base_dir = session_base_dir ctx.config in
            mkdir_p base_dir;
            let (session, ctx_opt) = load_context_from_checkpoint
              ~trace_id:meta.trace_id ~primary_model_max_tokens:primary.max_context ~base_dir in
            let base_ctx =
              match ctx_opt with
              | Some c -> c
              | None ->
                Context_manager.create
                  ~system_prompt:(
                    build_keeper_system_prompt
                      ~goal:meta.goal
                      ~short_goal:meta.short_goal
                      ~mid_goal:meta.mid_goal
                      ~long_goal:meta.long_goal
                      ~soul_profile:meta.soul_profile
                      ~will:meta.will
                      ~needs:meta.needs
                      ~desires:meta.desires
                      ~instructions:meta.instructions)
                  ~max_tokens:primary.max_context
            in
	            let ctx_work =
	              (* Always re-apply the current keeper prompt so goal/instructions updates
	                 actually take effect even when restoring an old checkpoint. *)
	              Context_manager.set_system_prompt base_ctx
                ~system_prompt:(
                  build_keeper_system_prompt
                    ~goal:meta.goal
                    ~short_goal:meta.short_goal
                    ~mid_goal:meta.mid_goal
                    ~long_goal:meta.long_goal
                    ~soul_profile:meta.soul_profile
                    ~will:meta.will
                    ~needs:meta.needs
	                    ~desires:meta.desires
	                    ~instructions:meta.instructions)
            in
            let fallback_skill_route =
              route_keeper_skill ~soul_profile:meta.soul_profile ~message
            in
            let skill_selection_mode = keeper_skill_selection_mode () in
            let continuity_snapshot = latest_state_snapshot_from_messages ctx_work.messages in
            let continuity_summary =
              match continuity_snapshot with
              | Some s -> keeper_state_snapshot_to_summary_text s
              | None -> (
                  let trimmed = String.trim meta.continuity_summary in
                  if trimmed = "" then "No continuity snapshot available." else trimmed)
            in
            let base_turn_system_prompt =
              if no_skill_route then
                ctx_work.system_prompt
              else
                match skill_selection_mode with
                | SkillSelectHeuristic ->
                    skill_route_system_prompt_heuristic
                      ~base_system_prompt:ctx_work.system_prompt
                      ~route:fallback_skill_route
                | SkillSelectAgent ->
                    skill_route_system_prompt_agent
                      ~base_system_prompt:ctx_work.system_prompt
                      ~fallback_route:fallback_skill_route
                      ~soul_profile:meta.soul_profile
            in
            let turn_system_prompt =
              append_continuity_context_prompt
                ~base_prompt:base_turn_system_prompt
                continuity_snapshot
                ~continuity_summary
            in
            let turn_system_prompt =
              let policy_guards = [
                (no_skill_route,
                 "Output guard: NEVER output lines starting with SKILL: or SKILL_REASON:.");
                (no_state_block,
                 "Output guard: NEVER output [STATE] or [/STATE] blocks in this turn.");
              ] in
              let policy_lines =
                List.filter_map
                  (fun (active, line) -> if active then Some line else None)
                  policy_guards
              in
              match policy_lines with
              | [] -> turn_system_prompt
              | _ ->
                  Printf.sprintf "%s\n\n%s"
                    turn_system_prompt
                    (String.concat "\n" policy_lines)
            in
            let turn_system_prompt =
              match turn_instructions with
              | None -> turn_system_prompt
              | Some ti ->
                  Printf.sprintf "%s\n\n--- Turn-specific instructions ---\n%s"
                    turn_system_prompt ti
            in
	            let user_msg = Llm_client.user_msg message in
	            let ctx_work = Context_manager.append ctx_work user_msg in
	            Context_manager.persist_message session user_msg;
            let turn_max_tokens = keeper_turn_max_tokens () in
            let followup_max_tokens = keeper_followup_max_tokens turn_max_tokens in
            let correction_max_tokens = keeper_correction_max_tokens turn_max_tokens in
            let postpass_budget_ms = keeper_msg_postpass_budget_ms () in
            let turn_started_ts = Time_compat.now () in
            let postpass_elapsed_ms () =
              int_of_float
                (max 0.0 ((Time_compat.now () -. turn_started_ts) *. 1000.0))
            in
            let postpass_remaining_ms () =
              if postpass_budget_ms <= 0 then max_int
              else max 0 (postpass_budget_ms - postpass_elapsed_ms ())
            in
            let has_postpass_budget () =
              postpass_budget_ms <= 0 || postpass_remaining_ms () > 0
            in

            (* Single-turn LLM call with cascade *)
            let requests =
	              List.map (fun (model : Llm_client.model_spec) ->
	                let msgs =
	                  (Llm_client.system_msg turn_system_prompt) :: ctx_work.messages
	                in
	                ({
                  Llm_client.model;
                  messages = msgs;
                  temperature = 0.7;
                  max_tokens = turn_max_tokens;
                  tools = keeper_llm_tools;
                  response_format = `Text;
                } : Llm_client.completion_request)
              ) specs
            in
            let run_cascade requests =
              match timeout_sec_opt, ollama_timeout_sec_opt with
              | Some timeout_sec, Some ollama_timeout_sec ->
                  Llm_client.cascade ~timeout_sec ~ollama_timeout_sec requests
              | Some timeout_sec, None ->
                  Llm_client.cascade ~timeout_sec requests
              | None, Some ollama_timeout_sec ->
                  Llm_client.cascade ~ollama_timeout_sec requests
              | None, None -> Llm_client.cascade requests
            in
            let recall_candidates = recent_user_messages base_ctx.messages ~max_n:32 in
            match run_cascade requests with
            | Error e ->
              (try ignore (Trajectory.finalize trajectory_acc (Trajectory.Failed e))
               with exn -> Printf.eprintf "[keeper] trajectory finalize (error path) failed: %s\n%!" (Printexc.to_string exn));
              (false, Printf.sprintf "❌ LLM failed: %s" e)
            | Ok resp0 ->
              let used_model0 =
                model_spec_for_used specs resp0.model_used
                |> Option.value ~default:primary
              in
              let cost0 = cost_usd_of_usage resp0.usage used_model0 in
              (* Multi-round tool calling loop: up to 3 rounds *)
              let max_tool_rounds = 3 in
              let _trunc s n = if String.length s > n then String.sub s 0 n ^ "..." else s in
              let execute_tool_calls tcs =
                List.map (fun (tc : Llm_client.tool_call) ->
                  Printf.eprintf "[TRPG-TRACE] Executing tool: %s args: %s\n%!"
                    tc.call_name (_trunc tc.call_arguments 200);
                  let (decision, result_opt, eval_opt, duration_ms) =
                    Eval_gate.guarded_execute
                      ~config:gate_config
                      ~accumulated_cost:trajectory_acc.Trajectory.total_cost
                      ~trajectory_acc:(Some trajectory_acc)
                      ~tool_name:tc.call_name
                      ~args_json:tc.call_arguments
                      ~execute:(fun () ->
                        execute_keeper_tool_call ~config:ctx.config ~meta ~ctx_work tc)
                  in
                  let output = match decision with
                    | Trajectory.Reject reason ->
                        Printf.eprintf "[HARNESS] Tool %s GATED: %s\n%!" tc.call_name reason;
                        Yojson.Safe.to_string (`Assoc [
                          ("error", `String (Printf.sprintf "gated: %s" reason));
                          ("tool", `String tc.call_name);
                        ])
                    | Trajectory.Pass ->
                        let r = Option.value ~default:"" result_opt in
                        Printf.eprintf "[TRPG-TRACE] Tool %s OK: %s\n%!" tc.call_name (_trunc r 200);
                        (* Log post-eval warnings *)
                        (match eval_opt with
                         | Some eval when eval.Eval_gate.should_warn ->
                             Printf.eprintf "[HARNESS] Warning for %s: %s\n%!" tc.call_name
                               (Option.value ~default:"" eval.Eval_gate.warning)
                         | _ -> ());
                        r
                  in
                  (* Record trajectory entry *)
                  let entry : Trajectory.tool_call_entry = {
                    ts = Time_compat.now ();
                    ts_iso = Types.now_iso ();
                    turn = trajectory_acc.Trajectory.turn;
                    round = 0;  (* updated by tool_loop caller *)
                    tool_name = tc.call_name;
                    args_json = tc.call_arguments;
                    gate_decision = decision;
                    result = (match decision with
                      | Trajectory.Pass -> result_opt
                      | Trajectory.Reject _ -> Some output);
                    duration_ms;
                    error = (match eval_opt with
                      | Some e -> e.Eval_gate.error_message
                      | None -> None);
                    cost_usd = (match eval_opt with
                      | Some e -> e.Eval_gate.cost_usd
                      | None -> 0.0);
                  } in
                  Trajectory.record_entry trajectory_acc entry;
                  (tc, output)
                ) tcs
              in
              let rec tool_loop ~round ~acc_usage ~acc_latency ~acc_cost
                  ~acc_tools_used ~last_resp =
                if last_resp.Llm_client.tool_calls = [] || round > max_tool_rounds then
                  (* Terminal: no more tool calls or hit round limit *)
                  let content =
                    let c = String.trim last_resp.Llm_client.content in
                    if c = "" && acc_tools_used <> [] then
                      Printf.sprintf "(tools executed: %s)"
                        (String.concat ", " acc_tools_used)
                    else last_resp.Llm_client.content
                  in
                  ( content, acc_usage, last_resp.Llm_client.model_used,
                    acc_latency, acc_cost, acc_tools_used )
                else begin
                  Printf.eprintf "[TRPG-TRACE] Tool round %d/%d: %d tool calls\n%!"
                    round max_tool_rounds
                    (List.length last_resp.Llm_client.tool_calls);
                  let round_tools =
                    List.map (fun (tc : Llm_client.tool_call) -> tc.call_name)
                      last_resp.Llm_client.tool_calls
                  in
                  let all_tools_so_far = acc_tools_used @ round_tools in
                  let tool_outputs = execute_tool_calls last_resp.Llm_client.tool_calls in
                  let followup_prompt =
                    keeper_tool_followup_prompt
                      ~user_message:message
                      ~draft_reply:last_resp.Llm_client.content
                      ~tool_outputs
                      ~already_executed:all_tools_so_far
                  in
                  (* Once a write tool has been executed, strip tools from the
                     next request to force the model to produce a text answer. *)
                  let write_done =
                    List.exists
                      (fun n ->
                         List.mem n
                           [
                             "keeper_board_post";
                             "keeper_board_comment";
                             "keeper_fs_edit";
                             "keeper_edit";
                           ])
                      all_tools_so_far
                  in
                  let next_tools =
                    if write_done then [] else keeper_llm_tools
                  in
                  let followup_requests =
                    List.map (fun (model : Llm_client.model_spec) ->
                      ({
                        Llm_client.model;
                        messages = [
                          Llm_client.system_msg (keeper_tool_loop_system_prompt
                            ~character_context:ctx_work.system_prompt);
                          Llm_client.user_msg followup_prompt;
                        ];
                        temperature = 0.3;
                        max_tokens = followup_max_tokens;
                        tools = next_tools;
                        response_format = `Text;
                      } : Llm_client.completion_request)
                    ) specs
                  in
                  match run_cascade followup_requests with
                  | Error _ ->
                    (* Cascade failed — return what we have *)
                    ( last_resp.Llm_client.content, acc_usage,
                      last_resp.Llm_client.model_used, acc_latency,
                      acc_cost, acc_tools_used @ round_tools )
                  | Ok resp_next ->
                    Printf.eprintf "[TRPG-TRACE] Follow-up round %d resp: tool_calls=%d content_len=%d model=%s\n%!"
                      round
                      (List.length resp_next.Llm_client.tool_calls)
                      (String.length resp_next.Llm_client.content)
                      resp_next.Llm_client.model_used;
                    let used_model_next =
                      model_spec_for_used specs resp_next.model_used
                      |> Option.value ~default:primary
                    in
                    let cost_next = cost_usd_of_usage resp_next.usage used_model_next in
                    tool_loop
                      ~round:(round + 1)
                      ~acc_usage:(merge_usage acc_usage resp_next.usage)
                      ~acc_latency:(acc_latency + resp_next.latency_ms)
                      ~acc_cost:(acc_cost +. cost_next)
                      ~acc_tools_used:(acc_tools_used @ round_tools)
                      ~last_resp:resp_next
                end
              in
              (* Harness: increment turn counter before tool execution *)
              Trajectory.increment_turn trajectory_acc;
              let (base_content, base_usage, base_model_used, base_latency_ms,
                   base_cost_usd, tools_used) =
                tool_loop ~round:1 ~acc_usage:resp0.usage
                  ~acc_latency:resp0.latency_ms ~acc_cost:cost0
                  ~acc_tools_used:[] ~last_resp:resp0
              in
              let eval0 =
                evaluate_memory_recall
                  ~user_message:message
                  ~assistant_reply:base_content
                  ~candidates:recall_candidates
              in
              let correction_needed =
                eval0.performed && not eval0.passed && eval0.candidate_count > 0
              in
              let (content_after_correction, usage_after_correction,
                   model_after_correction, latency_after_correction,
                   eval_after_correction, correction_applied_after_correction,
                   correction_success_after_correction,
                   correction_skipped_budget_after_correction,
                   cost_after_correction, tools_used) =
                if not correction_needed then
                  ( base_content, base_usage, base_model_used, base_latency_ms,
                    eval0, false, false, false, base_cost_usd, tools_used )
                else if not (has_postpass_budget ()) then
                  ( base_content, base_usage, base_model_used, base_latency_ms,
                    eval0, false, false, true, base_cost_usd, tools_used )
                else
                  let correction_prompt =
                    memory_correction_prompt
                      ~user_message:message
                      ~first_reply:base_content
                      ~candidate_user_msgs:recall_candidates
                      ~expected_topic:eval0.expected_topic
                  in
                  let correction_requests =
                    List.map (fun (model : Llm_client.model_spec) ->
	                      ({
	                        Llm_client.model;
	                        messages = [
	                          Llm_client.system_msg turn_system_prompt;
	                          Llm_client.user_msg correction_prompt;
	                        ];
                        temperature = 0.2;
                        max_tokens = correction_max_tokens;
                        tools = [];
                        response_format = `Text;
                      } : Llm_client.completion_request)
                    ) specs
                  in
                  match run_cascade correction_requests with
                  | Error _ ->
                    ( base_content, base_usage, base_model_used, base_latency_ms,
                      eval0, true, false, false, base_cost_usd, tools_used )
                  | Ok corr ->
                    let used_model1 =
                      model_spec_for_used specs corr.model_used
                      |> Option.value ~default:primary
                    in
                    let cost1 = cost_usd_of_usage corr.usage used_model1 in
                    let eval1 =
                      evaluate_memory_recall
                        ~user_message:message
                        ~assistant_reply:corr.content
                        ~candidates:recall_candidates
                    in
                    let evalf = { eval1 with initial_score = eval0.final_score } in
                    let merged_usage = merge_usage base_usage corr.usage in
                    ( corr.content, merged_usage, corr.model_used,
                      base_latency_ms + corr.latency_ms,
                      evalf, true, evalf.passed, false, base_cost_usd +. cost1,
                      tools_used )
              in
              let prompt_fallback_needed =
                eval_after_correction.performed
                && not eval_after_correction.passed
                && eval_after_correction.candidate_count > 0
              in
              let (content_after_prompt_fallback, usage_after_prompt_fallback,
                   model_after_prompt_fallback, latency_after_prompt_fallback,
                   eval_after_prompt_fallback, prompt_fallback_applied,
                   prompt_fallback_success, prompt_fallback_skipped_budget,
                   cost_after_prompt_fallback) =
                if not prompt_fallback_needed then
                  ( content_after_correction, usage_after_correction,
                    model_after_correction, latency_after_correction,
                    eval_after_correction, false, false, false, cost_after_correction )
                else if not (has_postpass_budget ()) then
                  ( content_after_correction, usage_after_correction,
                    model_after_correction, latency_after_correction,
                    eval_after_correction, false, false, true, cost_after_correction )
                else
                  let forced_prompt =
                    memory_forced_grounding_prompt
                      ~user_message:message
                      ~first_reply:content_after_correction
                      ~candidate_user_msgs:recall_candidates
                      ~expected_topic:eval_after_correction.expected_topic
                  in
                  let forced_requests =
                    List.map (fun (model : Llm_client.model_spec) ->
	                      ({
	                        Llm_client.model;
	                        messages = [
	                          Llm_client.system_msg turn_system_prompt;
	                          Llm_client.user_msg forced_prompt;
	                        ];
                        temperature = 0.0;
                        max_tokens = correction_max_tokens;
                        tools = [];
                        response_format = `Text;
                      } : Llm_client.completion_request)
                    ) specs
                  in
                  match run_cascade forced_requests with
                  | Error _ ->
                      ( content_after_correction, usage_after_correction,
                        model_after_correction, latency_after_correction,
                        eval_after_correction, true, false, false, cost_after_correction )
                  | Ok forced ->
                      let used_model2 =
                        model_spec_for_used specs forced.model_used
                        |> Option.value ~default:primary
                      in
                      let cost2 = cost_usd_of_usage forced.usage used_model2 in
                      let merged_usage = merge_usage usage_after_correction forced.usage in
                      let merged_latency = latency_after_correction + forced.latency_ms in
                      let grounded_content =
                        let c = String.trim forced.content in
                        if c = "" then content_after_correction else forced.content
                      in
                      let eval2 =
                        evaluate_memory_recall
                          ~user_message:message
                          ~assistant_reply:grounded_content
                          ~candidates:recall_candidates
                      in
                      let eval2 = { eval2 with initial_score = eval_after_correction.final_score } in
                      if eval2.passed then
                        ( grounded_content, merged_usage, forced.model_used,
                          merged_latency, eval2, true, true, false,
                          cost_after_correction +. cost2 )
                      else
                        ( content_after_correction, merged_usage, model_after_correction,
                          merged_latency, eval_after_correction, true, false, false,
                          cost_after_correction +. cost2 )
              in
              let (final_content, final_usage, final_model_used, final_latency_ms,
                   final_eval, correction_applied, correction_success,
                   recall_fallback_applied, total_cost_usd_turn) =
                match
                  deterministic_recall_fallback
                    ~meta
                    ~user_message:message
                    ~eval:eval_after_prompt_fallback
                    ~candidates:recall_candidates
                with
                | None ->
                    ( content_after_prompt_fallback, usage_after_prompt_fallback,
                      model_after_prompt_fallback, latency_after_prompt_fallback,
                      eval_after_prompt_fallback, correction_applied_after_correction,
                      (correction_success_after_correction || prompt_fallback_success), false,
                      cost_after_prompt_fallback )
                | Some (fallback_content, fallback_eval) ->
                    ( fallback_content, usage_after_prompt_fallback,
                      model_after_prompt_fallback, latency_after_prompt_fallback,
                      fallback_eval, true, fallback_eval.passed, true,
                      cost_after_prompt_fallback )
              in
              let postpass_budget_remaining_ms =
                if postpass_budget_ms <= 0 then -1 else postpass_remaining_ms ()
              in
              let memory_check_json =
                memory_eval_to_json final_eval
                  ~correction_applied
                  ~correction_success
                  ~correction_skipped_budget:correction_skipped_budget_after_correction
                  ~prompt_fallback_applied
                  ~prompt_fallback_success
                  ~prompt_fallback_skipped_budget
                  ~postpass_budget_ms
                  ~postpass_budget_remaining_ms
                  ~recall_fallback_applied
              in
	              let work_kind = work_kind_of_eval final_eval in
	              let tool_call_count = List.length tools_used in
	              let safe_reply_raw =
	                let trimmed = String.trim final_content in
	                if trimmed <> "" then final_content
	                else
	                  Printf.sprintf
	                    "Request processed. (generation=%d, trace=%s, model=%s)"
	                    meta.generation meta.trace_id final_model_used
	              in
		              let effective_skill_route =
		                match skill_selection_mode with
		                | SkillSelectHeuristic -> fallback_skill_route
		                | SkillSelectAgent ->
		                    (match agent_selected_skill_route_from_reply safe_reply_raw with
		                     | Some parsed -> parsed
		                     | None -> fallback_skill_route)
		              in
			              let safe_reply_with_skill =
			                if no_skill_route then
                            strip_skill_route_lines safe_reply_raw
                          else
			                    ensure_skill_route_header
			                      ~route:effective_skill_route
			                      safe_reply_raw
			              in
                          let safe_reply =
                            if no_state_block then
                              let stripped =
                                strip_state_blocks_text safe_reply_with_skill
                                |> String.trim
                              in
                              if stripped = "" then safe_reply_with_skill else stripped
                            else
                              safe_reply_with_skill
                          in
              let repetition_risk =
                repetition_risk_score
                  ~messages:ctx_work.messages
                  ~candidate_reply:(Some safe_reply)
              in
	              let goal_alignment =
	                goal_alignment_score
	                  ~meta
	                  ~user_message:(Some message)
	                  ~assistant_reply:(Some safe_reply)
	              in
              let response_alignment = jaccard_similarity message safe_reply in

		              let assistant_msg = Llm_client.assistant_msg safe_reply in
	              let ctx_work = Context_manager.append ctx_work assistant_msg in
              Context_manager.persist_message session assistant_msg;
              let now_ts = Time_compat.now () in
              let continuity_summary_from_reply =
                match parse_state_snapshot_from_reply safe_reply with
                | None -> meta.continuity_summary
                | Some snapshot -> keeper_state_snapshot_to_summary_text snapshot
              in
              let continuity_summary_from_reply = String.trim continuity_summary_from_reply in
              let last_continuity_update_ts =
                if
                  continuity_summary_from_reply <> ""
                  && String.trim meta.continuity_summary <> continuity_summary_from_reply
                then
                  now_ts
                else
                  meta.last_continuity_update_ts
              in
              let meta_for_compaction =
                {
                  meta with
                  continuity_summary = continuity_summary_from_reply;
                  last_continuity_update_ts;
                }
              in

              (* Compact opportunistically to control growth. *)
              let before_compact_tokens = ctx_work.token_count in
              let (ctx_work, compaction_trigger, compaction_decision) =
                compact_if_needed ~meta:meta_for_compaction ~now_ts ctx_work
              in
              let after_compact_tokens = ctx_work.token_count in
              let compacted = after_compact_tokens < before_compact_tokens in

              let ctx_ratio = Context_manager.context_ratio ctx_work in
              let meta_turn = { meta with
                updated_at = now_iso ();
                total_turns = meta.total_turns + 1;
                total_input_tokens = meta.total_input_tokens + final_usage.input_tokens;
                continuity_summary = continuity_summary_from_reply;
                last_continuity_update_ts;
                total_output_tokens = meta.total_output_tokens + final_usage.output_tokens;
                total_tokens = meta.total_tokens + final_usage.total_tokens;
                total_cost_usd = meta.total_cost_usd +. total_cost_usd_turn;
                last_turn_ts = now_ts;
                last_model_used = final_model_used;
                last_input_tokens = final_usage.input_tokens;
                last_output_tokens = final_usage.output_tokens;
                last_total_tokens = final_usage.total_tokens;
                last_latency_ms = final_latency_ms;
                compaction_count = meta.compaction_count + (if compacted then 1 else 0);
                last_compaction_ts = (if compacted then now_ts else meta.last_compaction_ts);
                last_compaction_before_tokens =
                  (if compacted then before_compact_tokens else meta.last_compaction_before_tokens);
                last_compaction_after_tokens =
                  (if compacted then after_compact_tokens else meta.last_compaction_after_tokens);
                last_compaction_check_ts = now_ts;
                last_compaction_decision = compaction_decision;
              } in
              let (meta_turn, drift_applied, drift_reason) =
                apply_self_model_drift
                  ~meta:meta_turn
                  ~user_message:message
                  ~work_kind
              in

              let (memory_notes_added, memory_note_kinds) =
                append_memory_notes_from_reply
                  ctx.config
                  meta_turn
                  ~turn:meta_turn.total_turns
                  ~reply:safe_reply
              in
              let memory_top_kind =
                match memory_note_kinds with
                | kind :: _ -> Some kind
                | [] -> None
              in
              let memory_compaction =
                compact_memory_bank_if_needed
                  ctx.config
                  meta_turn
              in

              (try ignore (save_checkpoint session ctx_work ~generation:meta_turn.generation)
               with exn -> Printf.eprintf "[keeper] save_checkpoint (turn) failed: %s\n%!" (Printexc.to_string exn));

		              let handoff_eval =
                let auto_rules =
                  evaluate_keeper_auto_rules
                    ~meta:meta_turn
                    ~context_ratio:ctx_ratio
                    ~message_count:(List.length ctx_work.messages)
                    ~token_count:ctx_work.token_count
                    ~repetition_risk
                    ~goal_alignment
                    ~response_alignment
                in
                (if auto_rules.guardrail_stop then
                   (try
                      ignore
                        (Room.broadcast
                           ctx.config
                           ~from_agent:meta_turn.agent_name
                           ~content:
                             (Printf.sprintf
                                "🛑 keeper guardrail_stop: %s"
                                (Option.value
                                   ~default:"policy threshold exceeded"
                                   auto_rules.guardrail_reason)))
                    with exn ->
                      Printf.eprintf "[keeper] room broadcast (guardrail_stop) failed: %s\n%!" (Printexc.to_string exn));
                   (* SSE: keeper_guardrail — dashboard real-time alert *)
                   (try Sse.broadcast (`Assoc [
                     ("type", `String "keeper_guardrail");
                     ("name", `String meta_turn.name);
                     ("reason", `String (Option.value ~default:"policy threshold exceeded"
                        auto_rules.guardrail_reason));
                   ]) with exn ->
                     Printf.eprintf "[keeper] SSE keeper_guardrail broadcast failed: %s\n%!" (Printexc.to_string exn)));
                let do_handoff =
                  auto_rules.handoff &&
		                (now_ts -. meta_turn.last_handoff_ts >= float_of_int meta_turn.handoff_cooldown_sec)
		              in
                (do_handoff, auto_rules)
	              in
	              let (do_handoff, auto_rules) = handoff_eval in

	              let metrics_path = keeper_metrics_path ctx.config meta_turn.name in
              let interesting_alert =
                try
                  maybe_emit_interesting_alert
                    ctx
                    ~meta:meta_turn
                    ~message
                    ~reply:safe_reply
                    ~work_kind
                    ~tool_call_count
                    ~context_ratio:ctx_ratio
                    ~goal_alignment
                    ~response_alignment
                    ~auto_rules
                with exn ->
                  {
                    empty_interesting_alert_result with
                    enabled = Env_config.KeeperAlert.enabled;
                    threshold = Env_config.KeeperAlert.min_score;
                    reasons = [ "fanout_exception" ];
                    keywords = [];
                    channels = [
                      {
                        channel = "fanout";
                        attempted = true;
                        success = false;
                        attempts = 1;
                        detail = Some (short_preview ~max_len:220 (Printexc.to_string exn));
                      };
                    ];
                  }
              in

              if not do_handoff then begin
                (match write_meta ctx.config meta_turn with
                 | Ok () -> ()
                 | Error e -> Printf.eprintf "[keeper:%s] failed to write meta: %s\n%!" meta_turn.name e);

                (try
                   let metrics_json = `Assoc [
                     ("ts", `String (now_iso ()));
                     ("ts_unix", `Float now_ts);
                     ("channel", `String "turn");
                     ("name", `String meta_turn.name);
                     ("agent_name", `String meta_turn.agent_name);
                     ("trace_id", `String meta_turn.trace_id);
                     ("generation", `Int meta_turn.generation);
                     ("model_used", `String final_model_used);
                     ("usage", `Assoc [
                       ("input_tokens", `Int final_usage.input_tokens);
                       ("output_tokens", `Int final_usage.output_tokens);
                       ("total_tokens", `Int final_usage.total_tokens);
                     ]);
                     ("latency_ms", `Int final_latency_ms);
                     ("cost_usd", `Float total_cost_usd_turn);
                     ("context_ratio", `Float ctx_ratio);
                     ("context_tokens", `Int ctx_work.token_count);
                     ("context_max", `Int ctx_work.max_tokens);
                     ("message_count", `Int (List.length ctx_work.messages));
                     ("compacted", `Bool compacted);
                     ("compaction_before_tokens", `Int before_compact_tokens);
                     ("compaction_after_tokens", `Int after_compact_tokens);
                     ( "compaction_trigger",
                       match compaction_trigger with
                       | Some reason -> `String reason
                       | None -> `Null );
                     ("compaction_decision", `String compaction_decision);
	                     ("work_kind", `String work_kind);
	                     ("tool_call_count", `Int tool_call_count);
	                     ("tools_used", `List (List.map (fun s -> `String s) tools_used));
		                     ("skill_primary", `String effective_skill_route.primary_skill);
		                     ("skill_secondary",
		                       `List (List.map (fun s -> `String s) effective_skill_route.secondary_skills));
			                     ("skill_reason", `String effective_skill_route.reason);
		                     ("memory_check", memory_check_json);
                     ("auto_rules", keeper_auto_rule_eval_to_json auto_rules);
                     ("reflection", keeper_reflection_payload_of_auto_rules auto_rules);
                     ("auto_reflect", `Bool auto_rules.reflect);
                     ("auto_plan", `Bool auto_rules.plan);
                     ("auto_compact", `Bool auto_rules.compact);
                     ("auto_handoff", `Bool auto_rules.handoff);
                     ("guardrail_stop", `Bool auto_rules.guardrail_stop);
                     ("guardrail_stop_reason",
                       match auto_rules.guardrail_reason with
                       | Some reason -> `String reason
                       | None -> `Null);
	                     ("repetition_risk", `Float repetition_risk);
	                     ("goal_alignment", `Float goal_alignment);
                     ("response_alignment", `Float response_alignment);
                     ("goal_drift", `Float auto_rules.goal_drift);
		                     ("drift", `Assoc [
	                       ("enabled", `Bool meta_turn.drift_enabled);
                       ("applied", `Bool drift_applied);
                       ("reason",
                         match drift_reason with
                         | Some reason -> `String reason
                         | None -> `Null);
                       ("min_turn_gap", `Int meta_turn.drift_min_turn_gap);
                       ("count_total", `Int meta_turn.drift_count_total);
                       ("last_turn", `Int meta_turn.last_drift_turn);
                       ("last_reason",
                         if String.trim meta_turn.last_drift_reason = ""
                         then `Null
                         else `String meta_turn.last_drift_reason);
                     ]);
                     ("memory_notes_added", `Int memory_notes_added);
                     ("memory_note_kinds",
                       `List (List.map (fun s -> `String s) memory_note_kinds));
                     ("memory_top_kind",
                       match memory_top_kind with
                       | Some kind -> `String kind
                       | None -> `Null);
                     ("memory_compaction_performed", `Bool memory_compaction.performed);
                     ("memory_compaction_reason",
                       match memory_compaction.reason with
                       | Some reason -> `String reason
                       | None -> `Null);
                     ("memory_compaction_target_notes", `Int memory_compaction.target_notes);
                     ("memory_compaction_before_notes", `Int memory_compaction.before_notes);
                     ("memory_compaction_after_notes", `Int memory_compaction.after_notes);
                     ("memory_compaction_dropped_notes", `Int memory_compaction.dropped_notes);
                     ("memory_compaction_dedup_dropped", `Int memory_compaction.dedup_dropped);
                     ("memory_compaction_invalid_dropped", `Int memory_compaction.invalid_dropped);
                     ("interesting_alert_triggered", `Bool interesting_alert.triggered);
                     ("interesting_alert_score", `Float interesting_alert.score);
                     ("interesting_alert", interesting_alert_result_to_json interesting_alert);
                     ("handoff", `Assoc [("performed", `Bool false)]);
                   ] in
                   append_jsonl_line metrics_path metrics_json
                 with exn ->
                   Printf.eprintf "[keeper] turn metrics JSONL write failed: %s\n%!" (Printexc.to_string exn));
                (* Harness: finalize trajectory with outcome *)
                (let traj_outcome =
                  if trajectory_acc.Trajectory.total_cost >= gate_config.Eval_gate.max_cost_usd then
                    Trajectory.CostExceeded
                  else
                    Trajectory.Completed
                in
                let _traj = Trajectory.finalize trajectory_acc traj_outcome in
                Printf.eprintf "[HARNESS] Trajectory finalized: %s turns=%d calls=%d cost=$%.4f outcome=%s\n%!"
                  meta_turn.trace_id
                  _traj.Trajectory.total_turns
                  _traj.Trajectory.total_tool_calls
                  _traj.Trajectory.total_cost_usd
                  (Trajectory.outcome_to_string traj_outcome));
                (* SSE: keeper_compaction — emitted only when compaction occurred *)
                (if compacted then
                  (try Sse.broadcast (`Assoc [
                    ("type", `String "keeper_compaction");
                    ("name", `String meta_turn.name);
                    ("saved_tokens", `Int (before_compact_tokens - after_compact_tokens));
                    ("trigger", match compaction_trigger with
                      | Some r -> `String r | None -> `Null);
                  ]) with exn ->
                    Printf.eprintf "[keeper] SSE keeper_compaction broadcast failed: %s\n%!" (Printexc.to_string exn)));

                let json = `Assoc [
                  ("name", `String meta_turn.name);
                  ("trace_id", `String meta_turn.trace_id);
                  ("generation", `Int meta_turn.generation);
                  ("soul_profile", `String meta_turn.soul_profile);
                  ("will", if String.trim meta_turn.will = "" then `Null else `String meta_turn.will);
                  ("needs", if String.trim meta_turn.needs = "" then `Null else `String meta_turn.needs);
                  ("desires", if String.trim meta_turn.desires = "" then `Null else `String meta_turn.desires);
                  ("model_used", `String final_model_used);
                  ("usage", `Assoc [
                    ("input_tokens", `Int final_usage.input_tokens);
                    ("output_tokens", `Int final_usage.output_tokens);
                    ("total_tokens", `Int final_usage.total_tokens);
                  ]);
                  ("latency_ms", `Int final_latency_ms);
                  ("cost_usd", `Float total_cost_usd_turn);
                  ("reply", `String safe_reply);
                  ("context_ratio", `Float ctx_ratio);
                  ("compacted", `Bool compacted);
                  ( "compaction_trigger",
                    match compaction_trigger with
                    | Some reason -> `String reason
                    | None -> `Null );
	                  ("work_kind", `String work_kind);
	                  ("tool_call_count", `Int tool_call_count);
	                  ("tools_used", `List (List.map (fun s -> `String s) tools_used));
		                  ("skill_primary", `String effective_skill_route.primary_skill);
		                  ("skill_secondary",
		                    `List (List.map (fun s -> `String s) effective_skill_route.secondary_skills));
			                  ("skill_reason", `String effective_skill_route.reason);
			                  ("memory_check", memory_check_json);
                  ("auto_rules", keeper_auto_rule_eval_to_json auto_rules);
                  ("reflection", keeper_reflection_payload_of_auto_rules auto_rules);
                  ("auto_reflect", `Bool auto_rules.reflect);
                  ("auto_plan", `Bool auto_rules.plan);
                  ("auto_compact", `Bool auto_rules.compact);
                  ("auto_handoff", `Bool auto_rules.handoff);
                  ("guardrail_stop", `Bool auto_rules.guardrail_stop);
                  ("guardrail_stop_reason",
                    match auto_rules.guardrail_reason with
                    | Some reason -> `String reason
                    | None -> `Null);
	                  ("repetition_risk", `Float repetition_risk);
	                  ("goal_alignment", `Float goal_alignment);
                  ("response_alignment", `Float response_alignment);
                  ("goal_drift", `Float auto_rules.goal_drift);
		                  ("drift", `Assoc [
	                    ("enabled", `Bool meta_turn.drift_enabled);
                    ("applied", `Bool drift_applied);
                    ("reason",
                      match drift_reason with
                      | Some reason -> `String reason
                      | None -> `Null);
                    ("min_turn_gap", `Int meta_turn.drift_min_turn_gap);
                    ("count_total", `Int meta_turn.drift_count_total);
                    ("last_turn", `Int meta_turn.last_drift_turn);
                    ("last_reason",
                      if String.trim meta_turn.last_drift_reason = ""
                      then `Null
                      else `String meta_turn.last_drift_reason);
                  ]);
                  ("memory_notes_added", `Int memory_notes_added);
                  ("memory_note_kinds",
                    `List (List.map (fun s -> `String s) memory_note_kinds));
                  ("memory_top_kind",
                    match memory_top_kind with
                    | Some kind -> `String kind
                    | None -> `Null);
                  ("memory_compaction_performed", `Bool memory_compaction.performed);
                  ("memory_compaction_reason",
                    match memory_compaction.reason with
                    | Some reason -> `String reason
                    | None -> `Null);
                  ("memory_compaction_target_notes", `Int memory_compaction.target_notes);
                  ("memory_compaction_before_notes", `Int memory_compaction.before_notes);
                  ("memory_compaction_after_notes", `Int memory_compaction.after_notes);
                  ("memory_compaction_dropped_notes", `Int memory_compaction.dropped_notes);
                  ("memory_compaction_dedup_dropped", `Int memory_compaction.dedup_dropped);
                  ("memory_compaction_invalid_dropped", `Int memory_compaction.invalid_dropped);
                  ("interesting_alert", interesting_alert_result_to_json interesting_alert);
                ] in
                (true, Yojson.Safe.pretty_to_string json)
              end else begin
                (* Auto-handoff: hydrate successor context + rotate trace_id. *)
                let next_model =
                  match specs with
                  | _m0 :: m1 :: _ -> m1
                  | m0 :: _ -> m0
                  | [] -> primary
                in
                let metrics = Succession.{
                  total_turns = meta_turn.total_turns;
                  total_tokens_used = meta_turn.total_tokens;
                  total_cost_usd = meta_turn.total_cost_usd;
                  tasks_completed = 0;
                  errors_encountered = 0;
                  elapsed_seconds = 0.0;
                } in
                let successor_trace = generate_trace_id () in
                let next_generation = meta_turn.generation + 1 in
                let dna = Succession.extract_dna
                  ~working_ctx:ctx_work
                  ~session_ctx:session
                  ~goal:meta_turn.goal
                  ~generation:next_generation
                  ~trace_id:successor_trace
                  ~metrics
                in
                let spec = Succession.{
                  model = next_model;
                  inherit_tools = false;
                  context_budget = meta_turn.context_budget;
                } in
                let successor_ctx = Succession.hydrate dna spec in
                let successor_session = Context_manager.create_session
                  ~session_id:successor_trace ~base_dir in
                (try ignore (save_checkpoint successor_session successor_ctx ~generation:next_generation)
                 with exn -> Printf.eprintf "[keeper] save_checkpoint (succession) failed: %s\n%!" (Printexc.to_string exn));

                let prev_trace_id = meta_turn.trace_id in
                let trace_history = take 20 (prev_trace_id :: meta_turn.trace_history) in
                let meta' = { meta_turn with
                  trace_id = successor_trace;
                  trace_history;
                  generation = next_generation;
                  last_handoff_ts = now_ts;
                  updated_at = now_iso ();
                } in
                (try ignore (write_meta ctx.config meta')
                 with exn -> Printf.eprintf "[keeper] write_meta (succession) failed: %s\n%!" (Printexc.to_string exn));

                (try
                   let metrics_json = `Assoc [
                     ("ts", `String (now_iso ()));
                     ("ts_unix", `Float now_ts);
                     ("channel", `String "turn");
                     ("name", `String meta'.name);
                     ("agent_name", `String meta'.agent_name);
                     ("trace_id", `String prev_trace_id);
                     ("generation", `Int meta_turn.generation);
                     ("model_used", `String final_model_used);
                     ("usage", `Assoc [
                       ("input_tokens", `Int final_usage.input_tokens);
                       ("output_tokens", `Int final_usage.output_tokens);
                       ("total_tokens", `Int final_usage.total_tokens);
                     ]);
                     ("latency_ms", `Int final_latency_ms);
                     ("cost_usd", `Float total_cost_usd_turn);
                     ("context_ratio", `Float ctx_ratio);
                     ("context_tokens", `Int ctx_work.token_count);
                     ("context_max", `Int ctx_work.max_tokens);
                     ("message_count", `Int (List.length ctx_work.messages));
                     ("compacted", `Bool compacted);
                     ("compaction_before_tokens", `Int before_compact_tokens);
                     ("compaction_after_tokens", `Int after_compact_tokens);
                     ( "compaction_trigger",
                       match compaction_trigger with
                       | Some reason -> `String reason
                       | None -> `Null );
	                     ("work_kind", `String work_kind);
	                     ("tool_call_count", `Int tool_call_count);
	                     ("tools_used", `List (List.map (fun s -> `String s) tools_used));
		                     ("skill_primary", `String effective_skill_route.primary_skill);
		                     ("skill_secondary",
		                       `List (List.map (fun s -> `String s) effective_skill_route.secondary_skills));
			                     ("skill_reason", `String effective_skill_route.reason);
			                     ("memory_check", memory_check_json);
                     ("auto_rules", keeper_auto_rule_eval_to_json auto_rules);
                     ("reflection", keeper_reflection_payload_of_auto_rules auto_rules);
                     ("auto_reflect", `Bool auto_rules.reflect);
                     ("auto_plan", `Bool auto_rules.plan);
                     ("auto_compact", `Bool auto_rules.compact);
                     ("auto_handoff", `Bool auto_rules.handoff);
                     ("guardrail_stop", `Bool auto_rules.guardrail_stop);
                     ("guardrail_stop_reason",
                       match auto_rules.guardrail_reason with
                       | Some reason -> `String reason
                       | None -> `Null);
	                     ("repetition_risk", `Float repetition_risk);
	                     ("goal_alignment", `Float goal_alignment);
                     ("response_alignment", `Float response_alignment);
                     ("goal_drift", `Float auto_rules.goal_drift);
		                     ("drift", `Assoc [
	                       ("enabled", `Bool meta_turn.drift_enabled);
                       ("applied", `Bool drift_applied);
                       ("reason",
                         match drift_reason with
                         | Some reason -> `String reason
                         | None -> `Null);
                       ("min_turn_gap", `Int meta_turn.drift_min_turn_gap);
                       ("count_total", `Int meta_turn.drift_count_total);
                       ("last_turn", `Int meta_turn.last_drift_turn);
                       ("last_reason",
                         if String.trim meta_turn.last_drift_reason = ""
                         then `Null
                         else `String meta_turn.last_drift_reason);
                     ]);
                     ("memory_notes_added", `Int memory_notes_added);
                     ("memory_note_kinds",
                       `List (List.map (fun s -> `String s) memory_note_kinds));
                     ("memory_top_kind",
                       match memory_top_kind with
                       | Some kind -> `String kind
                       | None -> `Null);
                     ("memory_compaction_performed", `Bool memory_compaction.performed);
                     ("memory_compaction_reason",
                       match memory_compaction.reason with
                       | Some reason -> `String reason
                       | None -> `Null);
                     ("memory_compaction_target_notes", `Int memory_compaction.target_notes);
                     ("memory_compaction_before_notes", `Int memory_compaction.before_notes);
                     ("memory_compaction_after_notes", `Int memory_compaction.after_notes);
                     ("memory_compaction_dropped_notes", `Int memory_compaction.dropped_notes);
                     ("memory_compaction_dedup_dropped", `Int memory_compaction.dedup_dropped);
                     ("memory_compaction_invalid_dropped", `Int memory_compaction.invalid_dropped);
                     ("interesting_alert_triggered", `Bool interesting_alert.triggered);
                     ("interesting_alert_score", `Float interesting_alert.score);
                     ("interesting_alert", interesting_alert_result_to_json interesting_alert);
                     ("handoff", `Assoc [
                       ("performed", `Bool true);
                       ("prev_trace_id", `String prev_trace_id);
                       ("new_trace_id", `String meta'.trace_id);
                       ("to_model", `String next_model.model_id);
                       ("new_generation", `Int meta'.generation);
                     ]);
                   ] in
                   append_jsonl_line metrics_path metrics_json
                 with exn ->
                   Printf.eprintf "[keeper] handoff metrics JSONL write failed: %s\n%!" (Printexc.to_string exn));
                (* SSE: keeper_handoff — generation succession event *)
                (try Sse.broadcast (`Assoc [
                  ("type", `String "keeper_handoff");
                  ("name", `String meta_turn.name);
                  ("from_generation", `Int meta_turn.generation);
                  ("to_generation", `Int next_generation);
                  ("to_model", `String next_model.model_id);
                ]) with exn ->
               Printf.eprintf "[keeper] SSE keeper_handoff broadcast failed: %s\n%!" (Printexc.to_string exn));

                let json = `Assoc [
                  ("name", `String meta'.name);
                  ("soul_profile", `String meta'.soul_profile);
                  ("will", if String.trim meta'.will = "" then `Null else `String meta'.will);
                  ("needs", if String.trim meta'.needs = "" then `Null else `String meta'.needs);
                  ("desires", if String.trim meta'.desires = "" then `Null else `String meta'.desires);
                  ("reply", `String safe_reply);
                  ("model_used", `String final_model_used);
                  ("latency_ms", `Int final_latency_ms);
                  ("cost_usd", `Float total_cost_usd_turn);
                  ("context_ratio", `Float ctx_ratio);
                  ("compacted", `Bool compacted);
                  ( "compaction_trigger",
                    match compaction_trigger with
                    | Some reason -> `String reason
                    | None -> `Null );
	                  ("work_kind", `String work_kind);
	                  ("tool_call_count", `Int tool_call_count);
	                  ("tools_used", `List (List.map (fun s -> `String s) tools_used));
		                  ("skill_primary", `String effective_skill_route.primary_skill);
		                  ("skill_secondary",
		                    `List (List.map (fun s -> `String s) effective_skill_route.secondary_skills));
			                  ("skill_reason", `String effective_skill_route.reason);
			                  ("memory_check", memory_check_json);
                  ("auto_rules", keeper_auto_rule_eval_to_json auto_rules);
                  ("reflection", keeper_reflection_payload_of_auto_rules auto_rules);
                  ("auto_reflect", `Bool auto_rules.reflect);
                  ("auto_plan", `Bool auto_rules.plan);
                  ("auto_compact", `Bool auto_rules.compact);
                  ("auto_handoff", `Bool auto_rules.handoff);
                  ("guardrail_stop", `Bool auto_rules.guardrail_stop);
                  ("guardrail_stop_reason",
                    match auto_rules.guardrail_reason with
                    | Some reason -> `String reason
                    | None -> `Null);
	                  ("repetition_risk", `Float repetition_risk);
	                  ("goal_alignment", `Float goal_alignment);
                  ("response_alignment", `Float response_alignment);
                  ("goal_drift", `Float auto_rules.goal_drift);
		                  ("drift", `Assoc [
	                    ("enabled", `Bool meta_turn.drift_enabled);
                    ("applied", `Bool drift_applied);
                    ("reason",
                      match drift_reason with
                      | Some reason -> `String reason
                      | None -> `Null);
                    ("min_turn_gap", `Int meta_turn.drift_min_turn_gap);
                    ("count_total", `Int meta_turn.drift_count_total);
                    ("last_turn", `Int meta_turn.last_drift_turn);
                    ("last_reason",
                      if String.trim meta_turn.last_drift_reason = ""
                      then `Null
                      else `String meta_turn.last_drift_reason);
                  ]);
                  ("memory_notes_added", `Int memory_notes_added);
                  ("memory_note_kinds",
                    `List (List.map (fun s -> `String s) memory_note_kinds));
                  ("memory_top_kind",
                    match memory_top_kind with
                    | Some kind -> `String kind
                    | None -> `Null);
                  ("memory_compaction_performed", `Bool memory_compaction.performed);
                  ("memory_compaction_reason",
                    match memory_compaction.reason with
                    | Some reason -> `String reason
                    | None -> `Null);
                  ("memory_compaction_target_notes", `Int memory_compaction.target_notes);
                  ("memory_compaction_before_notes", `Int memory_compaction.before_notes);
                  ("memory_compaction_after_notes", `Int memory_compaction.after_notes);
                  ("memory_compaction_dropped_notes", `Int memory_compaction.dropped_notes);
                  ("memory_compaction_dedup_dropped", `Int memory_compaction.dedup_dropped);
                  ("memory_compaction_invalid_dropped", `Int memory_compaction.invalid_dropped);
                  ("interesting_alert", interesting_alert_result_to_json interesting_alert);
                  ("handoff", `Assoc [
                    ("performed", `Bool true);
                    ("prev_trace_id", `String prev_trace_id);
                    ("new_trace_id", `String meta'.trace_id);
                    ("to_model", `String next_model.model_id);
                    ("new_generation", `Int meta'.generation);
                  ]);
                ] in
                (true, Yojson.Safe.pretty_to_string json)
              end))

let handle_keeper_down ctx args : tool_result =
  let name = get_string args "name" "" in
  if not (validate_name name) then
    (false, "❌ invalid keeper name")
  else
    let remove_meta = get_bool args "remove_meta" false in
    let remove_session = get_bool args "remove_session" false in
    stop_keepalive name;
    match read_meta ctx.config name with
    | Error e -> (false, "❌ " ^ e)
    | Ok None -> (true, Printf.sprintf "keeper already absent: %s" name)
    | Ok (Some m) ->
      if remove_meta then
        Safe_ops.remove_file_logged ~context:"keeper_down" (keeper_meta_path ctx.config name);
      if remove_session then begin
        let rec rm_rf path =
          if Sys.file_exists path then begin
            if Sys.is_directory path then begin
              Sys.readdir path |> Array.iter (fun entry ->
                rm_rf (Filename.concat path entry)
              );
              Unix.rmdir path
            end else
              Sys.remove path
          end
        in
        if validate_name m.trace_id then
          let dir = Filename.concat (session_base_dir ctx.config) m.trace_id in
          (try rm_rf dir with exn ->
          Printf.eprintf "[keeper] session dir cleanup failed: %s\n%!" (Printexc.to_string exn))
      end;
      let json = `Assoc [
        ("name", `String name);
        ("stopped", `Bool true);
        ("remove_meta", `Bool remove_meta);
        ("remove_session", `Bool remove_session);
      ] in
      (true, Yojson.Safe.pretty_to_string json)

let handle_keeper_list ctx args : tool_result =
  let limit = max 0 (get_int args "limit" 50) in
  let detailed = get_bool args "detailed" false in
  let dir = keeper_dir ctx.config in
  match Safe_ops.list_dir_safe dir with
  | Error e -> (false, "❌ " ^ e)
  | Ok files ->
    let keeper_names =
      files
      |> List.filter (fun f -> Filename.check_suffix f ".json")
      |> List.map Filename.remove_extension
      |> List.filter validate_name
      |> List.sort String.compare
      |> take limit
    in
    if not detailed then
      let json = `Assoc [
        ("count", `Int (List.length keeper_names));
        ("keepers", `List (List.map (fun k -> `String k) keeper_names));
      ] in
      (true, Yojson.Safe.pretty_to_string json)
    else
      let now_ts = Time_compat.now () in
      let keepers =
        List.filter_map (fun name ->
          match read_meta ctx.config name with
          | Error _ -> None
          | Ok None -> None
          | Ok (Some m) ->
            let created_ts =
              Resilience.Time.parse_iso8601_opt m.created_at |> Option.value ~default:0.0
            in
            let keeper_age_s = if created_ts <= 0.0 then 0.0 else now_ts -. created_ts in
            let last_turn_ago_s = if m.last_turn_ts <= 0.0 then 0.0 else now_ts -. m.last_turn_ts in
            let last_proactive_ago_s =
              if m.last_proactive_ts <= 0.0 then 0.0 else now_ts -. m.last_proactive_ts
            in
            let active_model = active_model_of_meta m in
            let next_model_hint = next_model_hint_of_meta m in
            let trace_history_count = List.length m.trace_history in
            let last_compaction_saved_tokens =
              max 0 (m.last_compaction_before_tokens - m.last_compaction_after_tokens)
            in
            let (compact_ratio_gate, compact_message_gate, compact_token_gate) =
              compaction_policy_of_keeper m
            in
	            let metrics_path = keeper_metrics_path ctx.config m.name in
	            let metrics_window_lines =
	              read_file_tail_lines metrics_path ~max_bytes:120000 ~max_lines:120
	            in
	            let last_metrics =
	              match List.rev metrics_window_lines with
	              | line :: _ -> (try Some (Yojson.Safe.from_string line) with Yojson.Json_error _ -> None)
	              | [] -> None
	            in
	            let metrics_overview =
	              summarize_metrics_lines metrics_window_lines ~default_generation:m.generation
	            in
	            let last_skill_metrics =
	              let rec find_latest = function
	                | [] -> None
	                | line :: tl ->
	                    (try
	                       let j = Yojson.Safe.from_string line in
	                       match Safe_ops.json_string_opt "skill_primary" j with
	                       | Some primary when String.trim primary <> "" -> Some j
	                       | _ -> find_latest tl
	                     with Yojson.Json_error _ -> find_latest tl)
	              in
	              find_latest (List.rev metrics_window_lines)
	            in
            let memory_bank_summary =
              read_keeper_memory_summary
                ctx.config
                ~name:m.name
                ~max_bytes:120000
                ~max_lines:180
                ~recent_limit:3
            in
            let memory_recent_note =
              match memory_bank_summary.recent_notes with
              | row :: _ -> Some row.text
              | [] -> None
            in
            let continuity_reflection_hold_s =
              let cooldown = Float.of_int m.continuity_compaction_cooldown_sec in
              let last_reflection_ts =
                max m.last_continuity_update_ts m.last_proactive_ts
              in
              if cooldown <= 0.0 then
                0.0
              else if last_reflection_ts <= 0.0 then
                cooldown
              else
                let elapsed = now_ts -. last_reflection_ts in
                max 0.0 (cooldown -. elapsed)
            in
	            let context_json =
	              match last_metrics with
	              | None -> `Assoc [("source", `String "none")]
	              | Some metrics ->
	                `Assoc [
	                  ("source", `String "metrics");
	                  ("context_ratio", `Float (Safe_ops.json_float "context_ratio" metrics));
	                  ("context_tokens", `Int (Safe_ops.json_int "context_tokens" metrics));
	                  ("context_max", `Int (Safe_ops.json_int "context_max" metrics));
	                  ("message_count", `Int (Safe_ops.json_int "message_count" metrics));
	                ]
	            in
	            let skill_route_json =
	              let open Yojson.Safe.Util in
	              match last_skill_metrics with
	              | None -> `Null
	              | Some metrics ->
	                  let primary = Safe_ops.json_string_opt "skill_primary" metrics in
	                  let secondary =
	                    match metrics |> member "skill_secondary" with
	                    | `List xs ->
	                        xs
	                        |> List.filter_map (fun v ->
	                             match v with `String s when String.trim s <> "" -> Some s | _ -> None)
	                    | _ -> []
	                  in
	                  let reason = Safe_ops.json_string_opt "skill_reason" metrics in
	                  `Assoc [
	                    ("primary", match primary with Some s -> `String s | None -> `Null);
	                    ("secondary", `List (List.map (fun s -> `String s) secondary));
	                    ("reason", match reason with Some s -> `String s | None -> `Null);
	                  ]
	            in
	            Some (`Assoc [
              ("name", `String m.name);
              ("agent_name", `String m.agent_name);
              ("trace_id", `String m.trace_id);
              ("generation", `Int m.generation);
              ("goal", `String m.goal);
              ("short_goal", `String m.short_goal);
              ("mid_goal", `String m.mid_goal);
              ("long_goal", `String m.long_goal);
              ("goal_horizons", `Assoc [
                ("short", `String m.short_goal);
                ("mid", `String m.mid_goal);
                ("long", `String m.long_goal);
              ]);
              ("soul_profile", `String m.soul_profile);
              ("will", if String.trim m.will = "" then `Null else `String m.will);
              ("needs", if String.trim m.needs = "" then `Null else `String m.needs);
              ("desires", if String.trim m.desires = "" then `Null else `String m.desires);
              ("keepalive_running", `Bool (Hashtbl.mem keepalives m.name));
              ("active_model", `String active_model);
              ("next_model_hint", match next_model_hint with Some s -> `String s | None -> `Null);
              ("keeper_age_s", `Float keeper_age_s);
              ("last_turn_ago_s", `Float last_turn_ago_s);
              ("last_proactive_ago_s", `Float last_proactive_ago_s);
              ("trace_history_count", `Int trace_history_count);
              ("handoff_count_total", `Int trace_history_count);
              ("compaction_count", `Int m.compaction_count);
              ("last_compaction_saved_tokens", `Int last_compaction_saved_tokens);
              ("compaction_profile", `String m.compaction_profile);
              ("compaction_ratio_gate", `Float compact_ratio_gate);
              ("compaction_message_gate", `Int compact_message_gate);
              ("compaction_token_gate", `Int compact_token_gate);
              ("proactive_enabled", `Bool m.proactive_enabled);
              ("proactive_idle_sec", `Int m.proactive_idle_sec);
              ("proactive_cooldown_sec", `Int m.proactive_cooldown_sec);
              ("proactive_count_total", `Int m.proactive_count_total);
              ("last_compaction_check_ts", `Float m.last_compaction_check_ts);
              ("last_compaction_decision",
                if String.trim m.last_compaction_decision = "" then `Null
                else `String m.last_compaction_decision);
              ("last_proactive_ts", `Float m.last_proactive_ts);
              ("last_proactive_reason",
                if String.trim m.last_proactive_reason = ""
                then `Null
                else `String m.last_proactive_reason);
              ("last_proactive_preview",
                if String.trim m.last_proactive_preview = ""
                then `Null
                else `String m.last_proactive_preview);
              ("continuity_summary",
                if String.trim m.continuity_summary = ""
                then `Null
                else `String m.continuity_summary);
              ("continuity_compaction_cooldown_sec", `Int m.continuity_compaction_cooldown_sec);
              ("continuity_reflection_hold_s", `Float continuity_reflection_hold_s);
              ("last_continuity_update_ts", `Float m.last_continuity_update_ts);
              ("drift_enabled", `Bool m.drift_enabled);
              ("drift_min_turn_gap", `Int m.drift_min_turn_gap);
              ("drift_count_total", `Int m.drift_count_total);
              ("last_drift_turn", `Int m.last_drift_turn);
              ("last_drift_reason",
                if String.trim m.last_drift_reason = ""
                then `Null
                else `String m.last_drift_reason);
              ("memory_note_count", `Int memory_bank_summary.total_notes);
              ("memory_top_kind",
                match memory_bank_summary.top_kind with
                | Some kind -> `String kind
                | None -> `Null);
	              ("memory_recent_note",
	                match memory_recent_note with
	                | Some text -> `String text
	                | None -> `Null);
	              ("context", context_json);
	              ("skill_route", skill_route_json);
	              ("metrics_overview", metrics_summary_to_json metrics_overview);
	              ("memory_bank", memory_summary_to_json memory_bank_summary);
              ("storage_paths", `Assoc [
                ("meta", `String (keeper_meta_path ctx.config m.name));
                ("metrics", `String metrics_path);
                ("memory_bank", `String (keeper_memory_bank_path ctx.config m.name));
                ("session_dir", `String (keeper_session_dir ctx.config m.trace_id));
                ("history", `String (keeper_history_path ctx.config m.trace_id));
              ]);
            ])
        ) keeper_names
      in
      let json = `Assoc [
        ("count", `Int (List.length keepers));
        ("keepers", `List keepers);
      ] in
      (true, Yojson.Safe.pretty_to_string json)

(* Start keepalive fibers for existing keepers (best-effort). *)
type keeper_bootstrap_stats = {
  enabled: bool;
  scanned: int;
  started: int;
  stale: int;
}

let bootstrap_existing_keepers ctx : keeper_bootstrap_stats =
  if not Env_config.KeeperBootstrap.enabled then
    { enabled = false; scanned = 0; started = 0; stale = 0 }
  else
    let dir = keeper_dir ctx.config in
    match Safe_ops.list_dir_safe dir with
    | Error _ -> { enabled = true; scanned = 0; started = 0; stale = 0 }
    | Ok files ->
        let now_ts = Time_compat.now () in
        let proactive_warmup_sec = keeper_bootstrap_proactive_warmup_sec () in
        let stale_turn_sec =
          max 0.0 Env_config.KeeperBootstrap.stale_turn_seconds
        in
        let max_scan =
          max 0 Env_config.KeeperBootstrap.max_scan
        in
        let max_keepers = Env_config.KeeperBootstrap.max_active_keepers in
        let remaining_slots =
          ref
            (if max_keepers > 0 then
               max 0 (max_keepers - running_keepers ())
             else
               max_int)
        in
        let names =
          files
          |> List.filter (fun f -> Filename.check_suffix f ".json")
          |> List.sort String.compare
          |> take max_scan
        in
        let (scanned, started, stale) =
          List.fold_left
            (fun (scanned_acc, started_acc, stale_acc) f ->
              let name = Filename.remove_extension f in
              match read_meta ctx.config name with
              | Ok (Some m) ->
                  let stale_now =
                    stale_turn_sec > 0.0
                    && (m.last_turn_ts <= 0.0
                        || now_ts -. m.last_turn_ts >= stale_turn_sec)
                  in
                  let already_running = Hashtbl.mem keepalives m.name in
                  let started_here =
                    if stale_now then false
                    else if already_running then false
                    else if max_keepers > 0 && !remaining_slots <= 0 then false
                    else (
                      start_keepalive ~proactive_warmup_sec ctx m;
                      if max_keepers > 0 then remaining_slots := !remaining_slots - 1;
                      true
                    )
                  in
                  ( scanned_acc + 1,
                    started_acc + (if started_here then 1 else 0),
                    stale_acc + (if stale_now then 1 else 0) )
              | _ -> (scanned_acc, started_acc, stale_acc))
            (0, 0, 0)
            names
        in
        { enabled = true; scanned; started; stale }

let existing_keepalive_bootstrap_done = ref false

let start_existing_keepalives ctx =
  if !existing_keepalive_bootstrap_done then ()
  else begin
    existing_keepalive_bootstrap_done := true;
    try
      let stats = bootstrap_existing_keepers ctx in
      if keeper_debug then
        Printf.eprintf
          "[KEEPER-DEBUG] bootstrap_existing_keepers enabled=%b scanned=%d started=%d stale=%d\n%!"
          stats.enabled stats.scanned stats.started stats.stale
    with exn ->
      (* Retry bootstrap on next keeper tool call if this attempt failed. *)
      existing_keepalive_bootstrap_done := false;
      raise exn
  end

(* ================================================================ *)
(* Phase 4: Keeper Autonomy MCP Tool Handlers                      *)
(* ================================================================ *)

let handle_keeper_autonomy ctx args : tool_result =
  let name = get_string args "name" "" in
  if not (validate_name name) then
    (false, "invalid keeper name")
  else
    match read_meta ctx.config name with
    | Error e -> (false, "read error: " ^ e)
    | Ok None -> (false, Printf.sprintf "keeper not found: %s" name)
    | Ok (Some m) ->
      let level_opt = get_string_opt args "level" in
      (match level_opt with
       | None ->
         (* GET mode: return current autonomy info *)
         let info = Printf.sprintf
           "Keeper: %s\nAutonomy Level: %s\nActive Goals: [%s]\nAutonomous Actions: %d\nLast Autonomous Action: %s"
           m.name
           (String.uppercase_ascii m.autonomy_level)
           (String.concat ", " m.active_goal_ids)
           m.autonomous_action_count
           (if m.last_autonomous_action_at = "" then "never" else m.last_autonomous_action_at)
         in
         (true, info)
       | Some level_str ->
         (* SET mode: validate and update autonomy level *)
         (match Keeper_autonomy.autonomy_level_of_string level_str with
          | None ->
            (false, Printf.sprintf "invalid autonomy level: %s (use L1_Reactive..L5_Independent)" level_str)
          | Some al ->
            let canonical = Keeper_autonomy.autonomy_level_to_string al in
            let updated = { m with autonomy_level = String.lowercase_ascii canonical } in
            (match write_meta ctx.config updated with
             | Error e -> (false, "write error: " ^ e)
             | Ok () ->
               (true, Printf.sprintf "Keeper %s autonomy level updated to %s" name canonical))))

let handle_keeper_goals ctx args : tool_result =
  let name = get_string args "name" "" in
  if not (validate_name name) then
    (false, "invalid keeper name")
  else
    match read_meta ctx.config name with
    | Error e -> (false, "read error: " ^ e)
    | Ok None -> (false, Printf.sprintf "keeper not found: %s" name)
    | Ok (Some m) ->
      let action = get_string_opt args "action" in
      (match action with
       | None ->
         (* LIST mode: show active goals with details *)
         let goals = Goal_store.list_goals ctx.config () in
         let active =
           List.filter
             (fun (g : Goal_store.goal) -> List.mem g.id m.active_goal_ids)
             goals
         in
         if active = [] then
           (true, Printf.sprintf "Keeper %s has no active goals." name)
         else
           let lines =
             List.map
               (fun (g : Goal_store.goal) ->
                 Printf.sprintf "- [%s] %s (horizon:%s, priority:%d, status:%s)"
                   g.id g.title g.horizon g.priority g.status)
               active
           in
           (true, Printf.sprintf "Keeper %s goals (%d):\n%s"
              name (List.length active) (String.concat "\n" lines))
       | Some "link" ->
         let goal_id = get_string args "goal_id" "" in
         if goal_id = "" then
           (false, "goal_id is required for link action")
         else if List.mem goal_id m.active_goal_ids then
           (true, Printf.sprintf "Goal %s already linked to keeper %s" goal_id name)
         else begin
           (* Verify goal exists *)
           let goals = Goal_store.list_goals ctx.config () in
           match List.find_opt (fun (g : Goal_store.goal) -> g.id = goal_id) goals with
           | None -> (false, Printf.sprintf "Goal %s not found in goal_store" goal_id)
           | Some g ->
             let updated = { m with active_goal_ids = goal_id :: m.active_goal_ids } in
             (match write_meta ctx.config updated with
              | Error e -> (false, "write error: " ^ e)
              | Ok () ->
                (true, Printf.sprintf "Linked goal [%s] %s to keeper %s" g.id g.title name))
         end
       | Some "unlink" ->
         let goal_id = get_string args "goal_id" "" in
         if goal_id = "" then
           (false, "goal_id is required for unlink action")
         else if not (List.mem goal_id m.active_goal_ids) then
           (true, Printf.sprintf "Goal %s not linked to keeper %s" goal_id name)
         else
           let updated = { m with
             active_goal_ids = List.filter (fun gid -> gid <> goal_id) m.active_goal_ids
           } in
           (match write_meta ctx.config updated with
            | Error e -> (false, "write error: " ^ e)
            | Ok () ->
              (true, Printf.sprintf "Unlinked goal %s from keeper %s" goal_id name))
       | Some other ->
         (false, Printf.sprintf "unknown action: %s (use link | unlink)" other))

let handle_keeper_trajectory ctx args : tool_result =
  let name = get_string args "name" "" in
  if not (validate_name name) then
    (false, "invalid keeper name")
  else
    match read_meta ctx.config name with
    | Error e -> (false, "read error: " ^ e)
    | Ok None -> (false, Printf.sprintf "keeper not found: %s" name)
    | Ok (Some m) ->
      let limit = get_int args "limit" 20 in
      let masc_root = Filename.concat ctx.config.base_path ".masc" in
      let entries =
        Trajectory.read_entries ~masc_root ~keeper_name:m.name ~trace_id:m.trace_id
      in
      let total = List.length entries in
      (* Take the last N entries (most recent) *)
      let recent =
        if total <= limit then entries
        else
          let drop = total - limit in
          List.filteri (fun i _e -> i >= drop) entries
      in
      if recent = [] then
        (true, Printf.sprintf "Keeper %s (trace: %s) has no trajectory entries." name m.trace_id)
      else
        let json_list = List.map Trajectory.entry_to_json recent in
        let json = `Assoc [
          ("keeper", `String name);
          ("trace_id", `String m.trace_id);
          ("generation", `Int m.generation);
          ("total_entries", `Int total);
          ("showing", `Int (List.length recent));
          ("entries", `List json_list);
        ] in
        (true, Yojson.Safe.pretty_to_string json)

let handle_keeper_eval ctx args : tool_result =
  let name = get_string args "name" "" in
  if not (validate_name name) then
    (false, "invalid keeper name")
  else
    match read_meta ctx.config name with
    | Error e -> (false, "read error: " ^ e)
    | Ok None -> (false, Printf.sprintf "keeper not found: %s" name)
    | Ok (Some m) ->
      let scenario_file = get_string_opt args "scenario_file" in
      let masc_root = Filename.concat ctx.config.base_path ".masc" in
      let entries =
        Trajectory.read_entries ~masc_root ~keeper_name:m.name ~trace_id:m.trace_id
      in
      if entries = [] then
        (true, Printf.sprintf "Keeper %s has no trajectory data to evaluate." name)
      else
        let total = List.length entries in
        (* Build a lightweight eval summary from trajectory *)
        let tool_names =
          List.map (fun (e : Trajectory.tool_call_entry) -> e.tool_name) entries
        in
        let unique_tools =
          List.sort_uniq String.compare tool_names
        in
        let tool_counts =
          List.map
            (fun tn ->
              let c = List.length (List.filter (fun n -> n = tn) tool_names) in
              (tn, c))
            unique_tools
        in
        let tool_stats =
          List.map
            (fun (tn, c) -> `Assoc [("tool", `String tn); ("count", `Int c)])
            (List.sort (fun (_, a) (_, b) -> compare b a) tool_counts)
        in
        (* Check if scenario file is provided for deeper eval *)
        let scenario_info =
          match scenario_file with
          | None -> `String "none (trajectory-only eval)"
          | Some sf ->
            (match Eval_harness.load_scenarios_from_file sf with
             | Error e -> `String (Printf.sprintf "failed to load: %s" e)
             | Ok scenarios ->
               `String (Printf.sprintf "loaded %d scenarios from %s"
                 (List.length scenarios) sf))
        in
        let json = `Assoc [
          ("keeper", `String name);
          ("trace_id", `String m.trace_id);
          ("generation", `Int m.generation);
          ("total_tool_calls", `Int total);
          ("unique_tools", `Int (List.length unique_tools));
          ("tool_distribution", `List tool_stats);
          ("scenario_file", scenario_info);
          ("autonomy_level", `String m.autonomy_level);
          ("autonomous_action_count", `Int m.autonomous_action_count);
        ] in
        (true, Yojson.Safe.pretty_to_string json)

let dispatch ctx ~name ~args : tool_result option =
  (* Lazy boot: when any keeper tool is used, attach keepalives for existing keepers. *)
  (try start_existing_keepalives ctx with exn ->
    Printf.eprintf "[keeper] start_existing_keepalives failed: %s\n%!" (Printexc.to_string exn));
  match name with
  | "masc_keeper_up" -> Some (handle_keeper_up ctx args)
  | "masc_keeper_status" -> Some (handle_keeper_status ctx args)
  | "masc_keeper_msg" -> Some (handle_keeper_msg ctx args)
  | "masc_keeper_down" -> Some (handle_keeper_down ctx args)
  | "masc_keeper_list" -> Some (handle_keeper_list ctx args)
  | "masc_keeper_autonomy" -> Some (handle_keeper_autonomy ctx args)
  | "masc_keeper_goals" -> Some (handle_keeper_goals ctx args)
  | "masc_keeper_trajectory" -> Some (handle_keeper_trajectory ctx args)
  | "masc_keeper_eval" -> Some (handle_keeper_eval ctx args)
  | _ -> None
