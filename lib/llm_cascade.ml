(** LLM Cascade — thin wrapper over OAS Cascade_config.

    MASC defines cascade name -> model list policy (default_model_strings).
    OAS handles config loading, model parsing, health filtering, and execution.

    Public entry points:
    - {!call} — prompt-in/text-out convenience (returns cascade_result)
    - {!call_raw} — prompt-in, returns full api_response
    - {!call_with_tools} — messages + tools, returns full api_response

    All three route through OAS Cascade_config.complete_named.

    @since 2.114.0 — original
    @since 2.115.0 — delegated to OAS Cascade_config
    @since 2.116.0 — call_raw, call_with_tools added *)

(* ================================================================ *)
(* Concurrency diagnostics (observability only, no throttling)       *)
(* ================================================================ *)

(** Maximum concurrent LLM calls — retained for diagnostics/dashboard.
    No longer enforced via semaphore: llama-server handles slot-based
    parallelism internally, and cloud APIs return rate-limit errors. *)
let max_concurrent_llm =
  Llm_types.int_of_env_default "MASC_MAX_CONCURRENT_LLM" ~default:8 ~min_v:1 ~max_v:128

(** Atomic counter tracking in-flight LLM calls (observability only). *)
let inflight = Atomic.make 0

let llm_semaphore_available () = max_concurrent_llm - Atomic.get inflight
let llm_permits_in_use () = Atomic.get inflight

(* ================================================================ *)

type cascade_result = {
  response : string;
  llm_used : string;
  duration_ms : int;
}

(** Locate config/llm_cascade.json via CWD or ME_ROOT.
    Returns [Some path] when the file exists on disk. *)
let default_config_path () : string option =
  let candidates =
    let cwd_candidate =
      Filename.concat (Sys.getcwd ()) "config/llm_cascade.json"
    in
    let me_root_candidate =
      let me =
        Sys.getenv_opt "ME_ROOT"
        |> Option.value
             ~default:(Sys.getenv_opt "HOME" |> Option.value ~default:"/tmp")
      in
      Filename.concat
        (Filename.concat me "workspace/yousleepwhen/masc-mcp")
        "config/llm_cascade.json"
    in
    [ cwd_candidate; me_root_candidate ]
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
  | "gardener_spawn" -> llama_glm
  (* classification — local llama, glm fallback *)
  | "classification" | "context_router" | "capability_match" -> llama_glm
  (* theory of mind — local llama, glm fallback *)
  | "tom" -> llama_glm
  (* verifier — local llama, glm fallback *)
  | "verifier" | "code_swarm_verify" -> llama_glm
  (* keeper — local llama, glm fallback *)
  | "keeper_autonomy" -> llama_glm
  (* routing — local llama, glm fallback *)
  | "routing_judge" -> llama_glm
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
  (* topic extraction — fast local model, glm fallback *)
  | "topic_extraction" -> llama_glm
  (* unregistered cascade: llama + glm as safety net *)
  | _ -> llama_glm

(** Backward compat: return MASC model_spec list.
    Prefer {!call}, {!call_raw}, or {!call_with_tools} instead. *)
let get_cascade ?(config_path = "") ~cascade_name () :
    Llm_types.model_spec list =
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
  let specs = Llm_types.available_model_specs_of_strings configured in
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
      Llm_types.available_model_specs_of_strings fallback)

(** Accept validator type: api_response -> bool.
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

(** Internal: resolve config, call OAS complete_named, map errors to string. *)
let complete_cascade ~cascade_name ~messages
    ?(config_path = "") ?(temperature = 0.3) ?(timeout_sec = 30)
    ?(max_tokens = 500) ?(accept = fun _ -> true) ?tools () =
  let env = Llm_eio_env.get () in
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

(** Prompt-in, text-out convenience. Returns {!cascade_result}. *)
let call ~cascade_name ~prompt
    ?(config_path = "") ?(temperature = 0.3) ?(timeout_sec = 30)
    ?(max_tokens = 500) ?(accept = fun _ -> true) ?system () =
  let messages : Llm_provider.Types.message list =
    (match system with
     | Some s -> [ Llm_provider.Types.system_msg s ]
     | None -> [])
    @ [ Llm_provider.Types.user_msg prompt ]
  in
  let t0 = Time_compat.now () in
  match
    complete_cascade ~cascade_name ~messages
      ~config_path ~temperature ~timeout_sec ~max_tokens ~accept ()
  with
  | Ok resp ->
    let duration_ms = int_of_float ((Time_compat.now () -. t0) *. 1000.0) in
    Ok
      {
        response = Llm_provider.Cascade_config.text_of_response resp;
        llm_used = resp.Llm_provider.Types.model;
        duration_ms;
      }
  | Error _ as e -> e

(** Prompt-in, full api_response out. Use when callers need model name,
    tool_calls, or usage from the response. *)
let call_raw ~cascade_name ~prompt
    ?(config_path = "") ?(temperature = 0.3) ?(timeout_sec = 30)
    ?(max_tokens = 500) ?(accept = fun _ -> true) ?system () =
  let messages : Llm_provider.Types.message list =
    (match system with
     | Some s -> [ Llm_provider.Types.system_msg s ]
     | None -> [])
    @ [ Llm_provider.Types.user_msg prompt ]
  in
  complete_cascade ~cascade_name ~messages
    ~config_path ~temperature ~timeout_sec ~max_tokens ~accept ()

(** Messages + tools in, full api_response out. For tool-using LLM calls. *)
let call_with_tools ~cascade_name ~messages
    ?(config_path = "") ?(temperature = 0.3) ?(timeout_sec = 30)
    ?(max_tokens = 500) ?(accept = fun _ -> true) ?tools () =
  complete_cascade ~cascade_name ~messages
    ~config_path ~temperature ~timeout_sec ~max_tokens ~accept ?tools ()
