(** Model_spec — LLM provider types, preset specs, and model spec parsing.

    Extracted from {!Cascade} to decouple model identity from cascade orchestration.

    @since 2.117.0 *)

open Printf

(* ================================================================ *)
(* Types                                                             *)
(* ================================================================ *)

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

(* ================================================================ *)
(* String conversion                                                 *)
(* ================================================================ *)

let string_of_provider = function
  | Llama -> "llama"
  | Claude -> "claude"
  | OpenAI -> "openai"
  | Gemini -> "gemini"
  | Glm_cloud -> "glm_cloud"
  | OpenRouter -> "openrouter"
  | Custom s -> sprintf "custom(%s)" s

(* ================================================================ *)
(* Preset specs                                                      *)
(* ================================================================ *)

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

(* ================================================================ *)
(* Model spec parsing                                                *)
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

(* ================================================================ *)
(* Default model label helpers                                       *)
(* ================================================================ *)

let configured_default_model_label () =
  match Provider_adapter.configured_default_model_label_result () with
  | Ok label -> Some label
  | Error _ -> None

let default_execution_model_labels () =
  Provider_adapter.preferred_execution_model_labels ()

let default_verifier_model_labels () =
  Provider_adapter.preferred_verifier_model_labels ()

(* ================================================================ *)
(* Available spec filtering                                          *)
(* ================================================================ *)

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

(* ================================================================ *)
(* Default model spec resolvers                                      *)
(* ================================================================ *)

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
