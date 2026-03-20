(** Cascade — MASC LLM call module.

    Model types, cascade profile defaults, model spec parsing,
    and {!complete} which delegates to OAS [Cascade_config.complete_named].

    Public entry points:
    - {!call} — prompt-in/text-out convenience (returns cascade_result)
    - {!call_raw} — prompt-in, returns full api_response
    - {!call_with_tools} — messages + tools, returns full api_response

    All three route through OAS Cascade_config.complete_named.

    @since 2.114.0 — original
    @since 2.115.0 — delegated to OAS Cascade_config
    @since 2.116.0 — call_raw, call_with_tools added *)

(* ================================================================ *)
(* Model types and helpers — absorbed from Masc_model               *)
(* ================================================================ *)


open Printf

let int_of_env_default name ~default ~min_v ~max_v =
  match Sys.getenv_opt name with
  | None -> default
  | Some raw ->
      let v =
        try int_of_string (String.trim raw)
        with Failure _ -> default
      in
      max min_v (min max_v v)

type provider =
  | Llama
  | Claude
  | OpenAI
  | Gemini
  | Glm_cloud
  | OpenRouter
  | Custom of string

type model_spec = {
  provider : provider;
  model_id : string;
  max_context : int;
  api_url : string;
  api_key_env : string option;
  cost_per_1k_input : float;
  cost_per_1k_output : float;
}

type tool_def = {
  tool_name : string;
  tool_description : string;
  parameters : Yojson.Safe.t;
}

(** Compute total tokens from OAS api_usage. *)
let total_tokens (u : Agent_sdk.Types.api_usage) = u.input_tokens + u.output_tokens

(** Zero usage sentinel. *)
let zero_usage : Agent_sdk.Types.api_usage =
  { Agent_sdk.Types.input_tokens = 0;
    output_tokens = 0;
    cache_creation_input_tokens = 0;
    cache_read_input_tokens = 0 }

(** Extract usage from an api_response, defaulting to zero. *)
let usage_of_response (resp : Llm_provider.Types.api_response) : Agent_sdk.Types.api_usage =
  match resp.usage with Some u -> u | None -> zero_usage

(** Extract text content from an api_response. *)
let text_of_response (resp : Llm_provider.Types.api_response) : string =
  Agent_sdk.Types.text_of_content resp.content

(** Measure wall-clock latency of a thunk in milliseconds.
    Use at call sites that need per-call timing (keeper tool loops, etc.). *)
let timed (f : unit -> 'a) : 'a * int =
  let t0 = Time_compat.now () in
  let result = f () in
  let ms = int_of_float ((Time_compat.now () -. t0) *. 1000.0) in
  (result, ms)

(** Check if an api_response contains any ToolUse blocks. *)
let has_tool_use (resp : Llm_provider.Types.api_response) : bool =
  List.exists
    (function Agent_sdk.Types.ToolUse _ -> true | _ -> false)
    resp.content

let string_of_provider = function
  | Llama -> "llama"
  | Claude -> "claude"
  | OpenAI -> "openai"
  | Gemini -> "gemini"
  | Glm_cloud -> "glm_cloud"
  | OpenRouter -> "openrouter"
  | Custom s -> sprintf "custom(%s)" s

let llama_default = {
  provider = Llama;
  model_id = Env_config.Llama.default_model;
  max_context = 128000;
  api_url = Env_config.Llama.server_url;
  api_key_env = None;
  cost_per_1k_input = 0.0;
  cost_per_1k_output = 0.0;
}

let claude_opus = {
  provider = Claude;
  model_id = Env_config.Claude.default_model;
  max_context = 200000;
  api_url = "https://api.anthropic.com";
  api_key_env = Some "ANTHROPIC_API_KEY";
  cost_per_1k_input = 0.015;
  cost_per_1k_output = 0.075;
}

let claude_sonnet = {
  provider = Claude;
  model_id = Env_config.Claude.default_model;
  max_context = 200000;
  api_url = "https://api.anthropic.com";
  api_key_env = Some "ANTHROPIC_API_KEY";
  cost_per_1k_input = 0.003;
  cost_per_1k_output = 0.015;
}

let openai_default = {
  provider = OpenAI;
  model_id = Env_config.OpenAI.default_model;
  max_context = 400000;
  api_url = "https://api.openai.com";
  api_key_env = Some "OPENAI_API_KEY";
  cost_per_1k_input = 0.0;
  cost_per_1k_output = 0.0;
}

let glm_cloud = {
  provider = Glm_cloud;
  model_id = Env_config.Llm.default_model;
  max_context = 128000;
  api_url = "https://api.z.ai";
  api_key_env = Some "ZAI_API_KEY";
  cost_per_1k_input = 0.001;
  cost_per_1k_output = 0.002;
}

let gemini_pro = {
  provider = Gemini;
  model_id = Env_config.Gemini.default_model;
  max_context = 1000000;
  api_url = "https://generativelanguage.googleapis.com";
  api_key_env = Some "GEMINI_API_KEY";
  cost_per_1k_input = 0.0;
  cost_per_1k_output = 0.0;
}

let tool_msg ~name:_ ~call_id text =
  Agent_sdk.Types.tool_result_msg ~tool_use_id:call_id ~content:text ()

(* ================================================================ *)
(* UTF-8 Sanitization                                               *)
(* ================================================================ *)

let sanitize_text_utf8 (s : string) : string =
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

let sanitize_message_utf8 (m : Agent_sdk.Types.message) : Agent_sdk.Types.message =
  { m with
    content = List.map (fun block ->
      match block with
      | Agent_sdk.Types.Text s -> Agent_sdk.Types.Text (sanitize_text_utf8 s)
      | Agent_sdk.Types.ToolResult { tool_use_id; content; is_error } ->
          Agent_sdk.Types.ToolResult {
            tool_use_id = sanitize_text_utf8 tool_use_id;
            content = sanitize_text_utf8 content;
            is_error }
      | other -> other
    ) m.content;
  }

let sanitize_messages_utf8 (msgs : Agent_sdk.Types.message list) : Agent_sdk.Types.message list =
  List.map sanitize_message_utf8 msgs

(** Heuristic: ~4 characters per token (conservative estimate). *)
let estimate_tokens (msgs : Agent_sdk.Types.message list) =
  List.fold_left (fun acc (m : Agent_sdk.Types.message) -> acc + (String.length (Agent_sdk.Types.text_of_message m) / 4) + 4) 0 msgs



(* ================================================================ *)
(* Concurrency diagnostics (observability only, no throttling)       *)
(* ================================================================ *)

(** Maximum concurrent LLM calls — retained for diagnostics/dashboard.
    No longer enforced via semaphore: llama-server handles slot-based
    parallelism internally, and cloud APIs return rate-limit errors. *)
let max_concurrent_llm =
  int_of_env_default "MASC_MAX_CONCURRENT_LLM" ~default:8 ~min_v:1 ~max_v:128

(** Atomic counter tracking in-flight LLM calls (observability only). *)
let inflight = Atomic.make 0

let llm_semaphore_available () = max_concurrent_llm - Atomic.get inflight
let llm_permits_in_use () = Atomic.get inflight

(* ================================================================ *)

(** Locate config/cascade.json via CWD or ME_ROOT.
    Falls back to legacy config/llm_cascade.json if new name not found.
    Returns [Some path] when the file exists on disk. *)
let default_config_path () : string option =
  let base dir name = Filename.concat (Filename.concat dir "config") name in
  let cwd = Sys.getcwd () in
  let me_root =
    Sys.getenv_opt "ME_ROOT"
    |> Option.value
         ~default:(Sys.getenv_opt "HOME" |> Option.value ~default:"/tmp")
  in
  let masc_root = Filename.concat me_root "workspace/yousleepwhen/masc-mcp" in
  let candidates =
    [ base cwd "cascade.json";
      base masc_root "cascade.json";
      base cwd "llm_cascade.json";
      base masc_root "llm_cascade.json" ]
  in
  List.find_opt Sys.file_exists candidates

(** Build a provider:model label, filtering out empty models. *)
let label provider model =
  if model = "" then None
  else Some (Printf.sprintf "%s:%s" provider model)

(** Build a label list, discarding entries with empty models. *)
let labels_of pairs =
  List.filter_map (fun (p, m) -> label p m) pairs

let default_model_strings ~cascade_name =
  let llama_model = Env_config.Llama.default_model in
  let glm_model = Env_config.Llm.default_model in
  let glm_flash = Env_config.Llm.flash_model in
  (* llama + glm:auto — Glm_pool selects model at runtime *)
  let llama_glm =
    (if llama_model <> "" then [ Printf.sprintf "llama:%s" llama_model ] else [])
    @ [ "glm:auto" ]
  in
  match cascade_name with
  (* heartbeat — llama first, glm fallback *)
  | "heartbeat_action" | "heartbeat_wake" -> llama_glm
  (* sentinel — llama first, glm fallback *)
  | "sentinel_board" | "sentinel_task" | "sentinel_keeper" -> llama_glm
  (* lodge subsystems — llama first, glm fallback *)
  | "lodge_direct" | "lodge_context_rewrite" | "lodge_trait_gen"
  | "lodge_comment" | "lodge_agent_match" ->
      llama_glm
  (* gardener — llama first, glm fallback *)
  | "gardener_spawn" | "gardener_retire" -> llama_glm
  (* classification — local llama, glm fallback *)
  | "classification" | "context_router" | "capability_match" -> llama_glm
  (* theory of mind — local llama, glm fallback *)
  | "tom" -> llama_glm
  (* verifier — local llama, glm fallback *)
  | "verifier" | "code_swarm_verify" | "code_swarm" -> llama_glm
  (* keeper — local llama, glm fallback *)
  | "keeper_autonomy" | "keeper_proactive" | "keeper_deliberation"
  | "keeper_reply" | "keeper_social" | "keeper_turn" -> llama_glm
  (* routing — local llama, glm fallback *)
  | "routing_judge" | "team_router" -> llama_glm
  (* chain — local llama, glm fallback *)
  | "chain_llm" -> llama_glm
  (* autoresearch — local llama, glm fallback *)
  | "autoresearch" -> llama_glm
  (* trpg — local llama, glm fallback *)
  | "trpg_intent" -> llama_glm
  (* briefing — llama first, flash-tier cloud chain, glm fallback *)
  | "briefing" ->
      (if llama_model <> "" then [ Printf.sprintf "llama:%s" llama_model ] else [])
      @ labels_of [ ("glm", glm_flash); ("gemini", Env_config.Gemini.flash_model) ]
      @ [ "glm:auto" ]
  | "governance_judge" | "operator_judge" -> llama_glm
  (* walph — default execution models *)
  | "walph" -> llama_glm
  (* auto_responder — agent_type-specific cascades *)
  | "auto_responder_claude" ->
      labels_of [ ("claude", Env_config.Claude.default_model) ]
      @ [ "glm:auto" ]
  | "auto_responder_gemini" ->
      labels_of [ ("gemini", Env_config.Gemini.flash_model) ]
      @ [ "glm:auto" ]
  | "auto_responder_glm" ->
      labels_of [ ("glm", glm_model) ]
      @ [ "glm:auto" ]
  | "auto_responder" -> llama_glm
  (* spawn glm — cloud cascade via Glm_pool *)
  | "spawn_glm" ->
      labels_of [ ("glm", glm_model); ("glm", glm_flash) ]
      @ [ "glm:auto" ]
  (* mitosis — cell division / handoff *)
  | "mitosis" -> llama_glm
  (* topic extraction — fast local model, glm fallback *)
  | "topic_extraction" -> llama_glm
  (* unregistered cascade: llama + glm as safety net *)
  | _ -> llama_glm

(* ================================================================ *)
(* Model spec parsing (moved from Masc_model)                        *)
(* ================================================================ *)

let rec model_spec_of_string s =
  let s = String.trim s in
  if String.equal (String.lowercase_ascii s) "default" then
    match Provider_adapter.default_model_label_result () with
    | Ok label -> model_spec_of_string label
    | Error _ as e -> e
  else if
    String.length s > 8
    && String.equal
         (String.lowercase_ascii (String.sub s 0 8))
         "default:"
  then
    let override_model =
      String.sub s 8 (String.length s - 8) |> String.trim
    in
    (match Provider_adapter.default_model_override_label_result override_model with
    | Ok label -> model_spec_of_string label
    | Error _ as e -> e)
  else
  match String.index_opt s ':' with
  | None ->
    Error
      (Printf.sprintf
         "Cannot parse model spec: %s (expected provider:model or default[:model])"
         s)
  | Some idx ->
    if idx = 0 || idx >= String.length s - 1 then
      Error
        (Printf.sprintf
           "Cannot parse model spec: %s (expected provider:model or default[:model])"
           s)
    else
      let provider = String.sub s 0 idx |> String.lowercase_ascii in
      let model_id =
        String.sub s (idx + 1) (String.length s - idx - 1)
        |> String.trim
      in
      if model_id = "" then
        Error
          (Printf.sprintf
             "Cannot parse model spec: %s (expected provider:model or default[:model])"
             s)
      else
        match Provider_adapter.resolve_direct_adapter provider with
        | Some adapter when adapter.canonical_name = "llama" ->
          Ok { llama_default with model_id }
        | Some adapter when adapter.canonical_name = "gemini-api" ->
          if model_id = "pro" then Ok gemini_pro
          else if model_id = "flash" then
            let flash = Env_config_governance.Gemini.flash_model in
            Ok { gemini_pro with model_id = (if flash = "" then "flash" else flash) }
          else
            Ok { gemini_pro with model_id }
        | Some adapter when adapter.canonical_name = "claude-api" ->
          if model_id = "opus" then Ok claude_opus
          else if model_id = "sonnet" then Ok claude_sonnet
          else Ok { claude_opus with model_id }
        | Some adapter when adapter.canonical_name = "codex-api" ->
          Ok { openai_default with model_id }
        | Some adapter when adapter.canonical_name = "glm" ->
          (* "auto" or empty -> Glm_pool selects at runtime *)
          let effective_id = if model_id = "auto" then "" else model_id in
          Ok { glm_cloud with model_id = effective_id }
        | Some adapter when adapter.canonical_name = "openrouter" ->
          Ok {
            provider = OpenRouter;
            model_id;
            max_context = 128000;
            api_url = "https://openrouter.ai/api";
            api_key_env = Some "OPENROUTER_API_KEY";
            cost_per_1k_input = 0.001;
            cost_per_1k_output = 0.002;
          }
        | Some _ ->
          Error (Printf.sprintf "Cannot parse model spec: %s (unsupported direct adapter '%s')" s provider)
        | None ->
          match provider with
        | "custom" ->
          (* Format: custom:model@http://host:port or custom:model *)
          let actual_model, url =
            match String.index_opt model_id '@' with
            | Some at_idx ->
              ( String.sub model_id 0 at_idx,
                String.sub model_id (at_idx + 1)
                  (String.length model_id - at_idx - 1) )
            | None -> (model_id, Env_config_runtime.Custom_llm.default_server_url)
          in
          Ok {
            provider = Custom actual_model;
            model_id = actual_model;
            max_context = 128000;
            api_url = url;
            api_key_env = None;
            cost_per_1k_input = 0.0;
            cost_per_1k_output = 0.0;
          }
        | _ ->
          Error
            (Printf.sprintf
               "Cannot parse model spec: %s (unsupported provider '%s'; supported: llama, claude, gemini, glm, openrouter, custom)"
               s provider)

let configured_default_model_label () =
  match Provider_adapter.configured_default_model_label_result () with
  | Ok label -> Some label
  | Error _ -> None

let default_execution_model_labels () =
  Provider_adapter.preferred_execution_model_labels ()

let default_verifier_model_labels () =
  Provider_adapter.preferred_verifier_model_labels ()

let available_model_specs_of_strings model_strs =
  model_strs
  |> List.filter_map (fun model_str ->
         match model_spec_of_string model_str with
         | Error err ->
             Log.LlmClient.warn "ignoring invalid model spec %s: %s"
               model_str err;
             None
         | Ok spec -> (
             match spec.api_key_env with
             | Some env_name ->
                 let value = Sys.getenv_opt env_name |> Option.value ~default:"" in
                 if String.trim value = "" then (
                   Log.LlmClient.debug "skipping %s: %s not set"
                     model_str env_name;
                   None)
                 else Some spec
             | None -> Some spec))

let first_available_model_spec labels =
  match available_model_specs_of_strings labels with
  | spec :: _ -> Ok spec
  | [] ->
      Error
        "No default model available. Set MASC_DEFAULT_CASCADE, \
         MASC_DEFAULT_PROVIDER/MASC_DEFAULT_MODEL, or provider credentials for the \
         preferred fallback chain, or pass an explicit model."

let default_execution_model_spec () =
  first_available_model_spec (default_execution_model_labels ())

let default_verifier_model_spec () =
  first_available_model_spec (default_verifier_model_labels ())

let default_local_model_spec () =
  match configured_default_model_label () with
  | Some label -> (
      match model_spec_of_string label with
      | Ok spec -> spec
      | Error _ -> (
          match default_execution_model_spec () with
          | Ok spec -> spec
          | Error _ -> glm_cloud))
  | None -> (
      match default_execution_model_spec () with
      | Ok spec -> spec
      | Error _ -> glm_cloud)

(** Backward compat: return MASC model_spec list.
    Prefer {!call}, {!call_raw}, or {!call_with_tools} instead. *)
let get_cascade ?(config_path = "") ~cascade_name () :
    model_spec list =
  let defaults = default_model_strings ~cascade_name in
  let configured =
    if String.length config_path > 0 then
      let from_file =
        Llm_provider.Cascade_config.load_profile
          ~config_path ~name:cascade_name
      in
      if from_file <> [] then from_file else defaults
    else
      match default_config_path () with
      | Some path ->
        let from_file =
          Llm_provider.Cascade_config.load_profile
            ~config_path:path ~name:cascade_name
        in
        if from_file <> [] then from_file else defaults
      | None -> defaults
  in
  let specs = available_model_specs_of_strings configured in
  if specs <> [] then specs
  else
    let fallback = default_model_strings ~cascade_name in
    if configured = fallback then (
      Printf.eprintf
        "[cascade] %s: no callable models from built-in defaults\n%!"
        cascade_name;
      [])
    else (
      Printf.eprintf
        "[cascade] %s: configured models unavailable — retrying built-in defaults\n%!"
        cascade_name;
      available_model_specs_of_strings fallback)

(** Accept validator type: Llm_provider.Types.api_response -> bool.
    Now that MASC validators use api_response directly, no bridging needed. *)

(** Format OAS http_error as cascade error string. *)
let format_cascade_error ~cascade_name = function
  | Llm_provider.Http_client.HttpError { code; body } ->
    Printf.sprintf "[cascade] %s: HTTP %d: %s" cascade_name code
      (if String.length body > 200
       then String.sub body 0 200 ^ "..."
       else body)
  | Llm_provider.Http_client.NetworkError { message } ->
    Printf.sprintf "[cascade] %s: %s" cascade_name message

(** Direct OAS bridge — single entry point for all LLM cascade calls.
    Replaces {!call}, {!call_raw}, and {!call_with_tools}.
    Returns OAS [api_response] directly; error formatted as string. *)
let complete ~cascade_name ~messages
    ?(config_path = "") ?(temperature = 0.3) ?(timeout_sec = 30)
    ?(max_tokens = 500) ?(accept = fun _ -> true) ?tools () =
  let env = Masc_eio_env.get () in
  let defaults = default_model_strings ~cascade_name in
  let config_path_opt =
    if String.length config_path > 0 then Some config_path
    else default_config_path ()
  in
  match
    Llm_provider.Cascade_config.complete_named
      ~sw:env.sw ~net:env.net ?clock:env.clock
      ?config_path:config_path_opt
      ~name:cascade_name ~defaults ~messages
      ?tools ~temperature ~max_tokens ~accept ~timeout_sec ()
  with
  | Ok resp -> Ok resp
  | Error err -> Error (format_cascade_error ~cascade_name err)

(* call, call_raw, call_with_tools removed — use {!complete} directly.
   Callers build messages and handle api_response/errors themselves. *)
