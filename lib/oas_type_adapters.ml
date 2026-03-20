(** OAS type adapters — convert MASC model types to OAS (Agent SDK) types.

    Thin wrappers bridging {!Model_spec.model_spec} and {!Agent_sdk.Types.message}
    to their OAS counterparts.  Most conversions are structural identity
    (shared type aliases); [to_oas_provider] performs actual mapping.

    @since 2.130.0 *)

let to_oas_provider (spec : Model_spec.model_spec) : Agent_sdk.Provider.config option =
  match spec.provider with
  | Claude ->
    Some { Agent_sdk.Provider.provider = Anthropic;
           model_id = spec.model_id;
           api_key_env = Option.value ~default:"ANTHROPIC_API_KEY" spec.api_key_env }
  | Llama ->
    Some { provider = Local { base_url = spec.api_url };
           model_id = spec.model_id; api_key_env = "" }
  | Glm_cloud | OpenAI | OpenRouter ->
    Some { provider = OpenAICompat { base_url = spec.api_url; auth_header = None;
             path = "/v1/chat/completions"; static_token = None };
           model_id = spec.model_id;
           api_key_env = Option.value ~default:"" spec.api_key_env }
  | Gemini ->
    Some { provider = OpenAICompat { base_url = spec.api_url; auth_header = None;
             path = "/v1beta/chat/completions"; static_token = None };
           model_id = spec.model_id;
           api_key_env = Option.value ~default:"GEMINI_API_KEY" spec.api_key_env }
  | Custom _ ->
    Some { provider = OpenAICompat { base_url = spec.api_url; auth_header = None;
             path = "/v1/chat/completions"; static_token = None };
           model_id = spec.model_id;
           api_key_env = Option.value ~default:"" spec.api_key_env }

let to_oas_message (m : Agent_sdk.Types.message) : Agent_sdk.Types.message option =
  match m.role with System -> None | _ -> Some m

let of_oas_message (m : Agent_sdk.Types.message) : Agent_sdk.Types.message = m
let of_oas_usage (u : Agent_sdk.Types.api_usage) : Agent_sdk.Types.api_usage = u
let to_oas_usage (u : Agent_sdk.Types.api_usage) : Agent_sdk.Types.api_usage = u
