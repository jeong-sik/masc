(** OAS type adapters — convert MASC model labels and Provider_config to
    OAS (Agent SDK) types.

    All conversions use OAS Cascade_config and Provider_registry directly.
    No dependency on Model_spec types or functions.

    @since 2.130.0
    @since 2.133.0 — Phase 1: migrated to Model_spec bridge
    @since 2.134.0 — Phase 6: eliminated Model_spec.model_spec exposure (legacy)
    @since 2.135.0 — Phase 7: eliminated Model_spec function calls *)

(** Convert OAS Provider_config.t to OAS Provider.config for Agent Builder.
    Provider_config.t already contains resolved API key and endpoint;
    Provider.config is the Builder-level discriminated union. *)
let provider_config_to_oas (cfg : Llm_provider.Provider_config.t)
    : Agent_sdk.Provider.config =
  match cfg.kind with
  | Anthropic ->
    { Agent_sdk.Provider.provider = Anthropic;
      model_id = cfg.model_id;
      api_key_env = if cfg.api_key <> "" then cfg.api_key else "ANTHROPIC_API_KEY" }
  | Gemini ->
    { provider = OpenAICompat { base_url = cfg.base_url; auth_header = None;
        path = cfg.request_path; static_token = None };
      model_id = cfg.model_id;
      api_key_env = if cfg.api_key <> "" then cfg.api_key else "GEMINI_API_KEY" }
  | Glm ->
    { provider = OpenAICompat { base_url = cfg.base_url; auth_header = None;
        path = cfg.request_path; static_token = None };
      model_id = cfg.model_id;
      api_key_env = if cfg.api_key <> "" then cfg.api_key else "ZAI_API_KEY" }
  | OpenAI_compat ->
    { provider =
        (if String.length cfg.base_url > 0
            && (String.sub cfg.base_url 0 (min 16 (String.length cfg.base_url))
                = "http://127.0.0.1"
                || String.sub cfg.base_url 0 (min 16 (String.length cfg.base_url))
                   = "http://localhost")
         then Local { base_url = cfg.base_url }
         else OpenAICompat { base_url = cfg.base_url; auth_header = None;
                path = cfg.request_path; static_token = None });
      model_id = cfg.model_id;
      api_key_env = cfg.api_key }
  | Claude_code ->
    { provider = OpenAICompat { base_url = cfg.base_url; auth_header = None;
        path = cfg.request_path; static_token = None };
      model_id = cfg.model_id;
      api_key_env = cfg.api_key }

(** Convert a model label string (e.g. "llama:qwen3.5") to an OAS Provider.config.
    Parses via OAS Cascade_config.parse_model_string which uses
    Provider_registry as SSOT. Returns None only if parsing fails. *)
let to_oas_provider_of_label (label : string) : Agent_sdk.Provider.config option =
  match Llm_provider.Cascade_config.parse_model_string label with
  | None -> None
  | Some pc -> Some (provider_config_to_oas pc)

let to_oas_message (m : Agent_sdk.Types.message) : Agent_sdk.Types.message option =
  match m.role with System -> None | _ -> Some m

let of_oas_message (m : Agent_sdk.Types.message) : Agent_sdk.Types.message = m
let of_oas_usage (u : Agent_sdk.Types.api_usage) : Agent_sdk.Types.api_usage = u
let to_oas_usage (u : Agent_sdk.Types.api_usage) : Agent_sdk.Types.api_usage = u
