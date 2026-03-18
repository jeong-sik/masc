(** Lodge Cascade — thin wrapper over OAS Cascade_config.

    MASC defines cascade name -> model list policy (default_model_strings).
    OAS handles config loading, model parsing, health filtering, and execution.

    @since 2.114.0 — original
    @since 2.115.0 — delegated to OAS Cascade_config *)

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
  | "verifier" -> llama_glm
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

(** Backward compat: return MASC model_spec list for callers that need
    to pass specs to Llm_orchestration directly. Uses OAS Cascade_config
    for config loading, then maps back to Llm_types. *)
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

(** Bridge MASC accept validator (completion_response -> bool)
    to OAS accept validator (api_response -> bool).
    Constructs a minimal completion_response from the OAS api_response. *)
let adapt_accept (masc_accept : Llm_types.completion_response -> bool) :
    Llm_provider.Types.api_response -> bool =
 fun (oas_resp : Llm_provider.Types.api_response) ->
  let usage : Agent_sdk.Types.api_usage =
    match oas_resp.usage with
    | Some u -> u
    | None ->
      { input_tokens = 0; output_tokens = 0;
        cache_creation_input_tokens = 0; cache_read_input_tokens = 0 }
  in
  let fake_resp : Llm_types.completion_response =
    { content = oas_resp.content;
      tool_calls = [];
      usage;
      model_used = oas_resp.model;
      latency_ms = 0;
    }
  in
  masc_accept fake_resp

(** Call LLM cascade. Routes directly through OAS Cascade_config.complete_named,
    bypassing MASC's Llm_orchestration. *)
let call ~cascade_name ~prompt
    ?(config_path = "") ?(temperature = 0.3) ?(timeout_sec = 30)
    ?(max_tokens = 500) ?(accept = fun _ -> true) ?system () =
  ignore timeout_sec;
  let env = Llm_eio_env.get () in
  let defaults = default_model_strings ~cascade_name in
  let config_path_opt =
    if String.length config_path > 0 then Some config_path
    else default_config_path ()
  in
  let messages : Llm_provider.Types.message list =
    (match system with
     | Some s -> [ Llm_provider.Types.system_msg s ]
     | None -> [])
    @ [ Llm_provider.Types.user_msg prompt ]
  in
  let oas_accept = adapt_accept accept in
  let t0 = Time_compat.now () in
  match
    Llm_provider.Cascade_config.complete_named
      ~sw:env.sw ~net:env.net ?clock:env.clock
      ?config_path:config_path_opt
      ~name:cascade_name ~defaults ~messages
      ~temperature ~max_tokens ~accept:oas_accept ()
  with
  | Ok resp ->
    let t1 = Time_compat.now () in
    let duration_ms = int_of_float ((t1 -. t0) *. 1000.0) in
    Ok
      {
        response = Llm_provider.Cascade_config.text_of_response resp;
        llm_used = resp.Llm_provider.Types.model;
        duration_ms;
      }
  | Error (Llm_provider.Http_client.HttpError { code; body }) ->
    Error (Printf.sprintf "[cascade] %s: HTTP %d: %s" cascade_name code
             (if String.length body > 200
              then String.sub body 0 200 ^ "..."
              else body))
  | Error (Llm_provider.Http_client.NetworkError { message }) ->
    Error (Printf.sprintf "[cascade] %s: %s" cascade_name message)
