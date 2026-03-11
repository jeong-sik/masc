(** Keeper_types — shared types, meta record, serialization, path helpers,
    and model-resolution utilities used by all keeper-related modules.

    Includes [Keeper_config] so consumers get config defaults and parsing. *)

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

