(** Model_spec — OAS-backed model identity and resolution.

    Types and parsing remain for MASC-specific alias resolution
    (Provider_adapter) and "default"/"default:override" forms.
    Metadata (URLs, API keys, context sizes, costs) is sourced
    from OAS Provider_registry and Pricing — single source of truth.

    @since 2.117.0 — original extraction from Cascade
    @since 2.123.0 — rewritten as OAS facade *)

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
(* OAS registry + pricing helpers                                    *)
(* ================================================================ *)

let default_registry = Llm_provider.Provider_registry.default ()

(** Build a model_spec from OAS registry entry + pricing. *)
let make_of_entry
    (entry : Llm_provider.Provider_registry.entry)
    ~model_id ~provider : model_spec =
  let pricing = Llm_provider.Pricing.pricing_for_model model_id in
  let api_key_env =
    let e = entry.defaults.api_key_env in
    if e = "" then None else Some e
  in
  { provider;
    model_id;
    max_context = entry.max_context;
    api_url = entry.defaults.base_url;
    api_key_env;
    cost_per_1k_input = pricing.input_per_million /. 1000.0;
    cost_per_1k_output = pricing.output_per_million /. 1000.0 }

(** Build from registry name with fallback for unknown entries. *)
let make_of_registry ~registry_name ~model_id ~provider : model_spec =
  match Llm_provider.Provider_registry.find default_registry registry_name with
  | Some entry -> make_of_entry entry ~model_id ~provider
  | None ->
    let pricing = Llm_provider.Pricing.pricing_for_model model_id in
    { provider; model_id; max_context = 128_000;
      api_url = "http://127.0.0.1:8085";
      api_key_env = None;
      cost_per_1k_input = pricing.input_per_million /. 1000.0;
      cost_per_1k_output = pricing.output_per_million /. 1000.0 }

(* ================================================================ *)
(* Preset specs — sourced from OAS Provider_registry + Pricing       *)
(* ================================================================ *)

let llama_default =
  make_of_registry ~registry_name:"llama"
    ~model_id:Env_config.Llama.default_model ~provider:Llama

let claude_opus =
  let base = make_of_registry ~registry_name:"claude"
    ~model_id:Env_config.Claude.default_model ~provider:Claude in
  (* Opus pricing tier — use full wire model ID for lookup *)
  let pricing = Llm_provider.Pricing.pricing_for_model "claude-opus-4-6" in
  { base with
    cost_per_1k_input = pricing.input_per_million /. 1000.0;
    cost_per_1k_output = pricing.output_per_million /. 1000.0 }

let claude_sonnet =
  let pricing = Llm_provider.Pricing.pricing_for_model "claude-sonnet-4-6" in
  { claude_opus with
    cost_per_1k_input = pricing.input_per_million /. 1000.0;
    cost_per_1k_output = pricing.output_per_million /. 1000.0 }

let openai_default =
  make_of_registry ~registry_name:"openrouter"
    ~model_id:Env_config.OpenAI.default_model ~provider:OpenAI

let glm_cloud =
  make_of_registry ~registry_name:"glm"
    ~model_id:Env_config.Glm.default_model ~provider:Glm_cloud

let gemini_pro =
  make_of_registry ~registry_name:"gemini"
    ~model_id:Env_config.Gemini.default_model ~provider:Gemini

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
          let effective_id = if model_id = "auto" then "" else model_id in
          Ok { glm_cloud with model_id = effective_id }
        | Some adapter when adapter.canonical_name = "openrouter" ->
          Ok (make_of_registry ~registry_name:"openrouter"
                ~model_id ~provider:OpenRouter)
        | Some _ ->
          Error (Printf.sprintf "Cannot parse model spec: %s (unsupported direct adapter '%s')" s provider)
        | None ->
          match provider with
        | "custom" ->
          let actual_model, url =
            match String.index_opt model_id '@' with
            | Some at_idx ->
              ( String.sub model_id 0 at_idx,
                String.sub model_id (at_idx + 1)
                  (String.length model_id - at_idx - 1) )
            | None -> (model_id, Env_config_runtime.Custom_model.default_server_url)
          in
          let pricing = Llm_provider.Pricing.pricing_for_model actual_model in
          Ok {
            provider = Custom actual_model;
            model_id = actual_model;
            max_context = 128_000;
            api_url = url;
            api_key_env = None;
            cost_per_1k_input = pricing.input_per_million /. 1000.0;
            cost_per_1k_output = pricing.output_per_million /. 1000.0;
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
             Log.ModelClient.warn "ignoring invalid model spec %s: %s"
               model_str err;
             None
         | Ok spec -> (
             match spec.api_key_env with
             | Some env_name ->
                 let value = Sys.getenv_opt env_name |> Option.value ~default:"" in
                 if String.trim value = "" then (
                   Log.ModelClient.debug "skipping %s: %s not set"
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
