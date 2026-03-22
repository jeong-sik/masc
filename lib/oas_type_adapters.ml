(** OAS type adapters — convert MASC model types to OAS (Agent SDK) types.

    Thin wrappers bridging {!Model_spec.model_spec} and {!Agent_sdk.Types.message}
    to their OAS counterparts.  Most conversions are structural identity
    (shared type aliases); [to_oas_provider] performs actual mapping.

    Phase 1 migration: uses {!Model_spec.to_provider_config} bridge
    where possible, with provider-specific overrides for Llama (Local)
    and Claude (Anthropic) which need Agent_sdk.Provider-specific constructors.

    @since 2.130.0
    @since 2.133.0 — Phase 1: migrated to Model_spec bridge *)

let to_oas_provider (spec : Model_spec.model_spec) : Agent_sdk.Provider.config option =
  (* Use the Provider_config bridge for base_url, model_id, api_key *)
  let pc = Model_spec.to_provider_config spec in
  let rn = Model_spec.registry_name_of_provider spec.provider in
  match rn with
  | "claude" ->
    Some { Agent_sdk.Provider.provider = Anthropic;
           model_id = pc.model_id;
           api_key_env =
             if pc.api_key <> "" then pc.api_key
             else "ANTHROPIC_API_KEY" }
  | "llama" ->
    Some { provider = Local { base_url = pc.base_url };
           model_id = pc.model_id; api_key_env = "" }
  | "gemini" ->
    Some { provider = OpenAICompat { base_url = pc.base_url; auth_header = None;
             path = pc.request_path; static_token = None };
           model_id = pc.model_id;
           api_key_env =
             if pc.api_key <> "" then pc.api_key
             else "GEMINI_API_KEY" }
  | _ ->
    (* glm, openrouter, custom: all OpenAI_compat wire format *)
    Some { provider = OpenAICompat { base_url = pc.base_url; auth_header = None;
             path = pc.request_path; static_token = None };
           model_id = pc.model_id;
           api_key_env = pc.api_key }

let to_oas_message (m : Agent_sdk.Types.message) : Agent_sdk.Types.message option =
  match m.role with System -> None | _ -> Some m

let of_oas_message (m : Agent_sdk.Types.message) : Agent_sdk.Types.message = m
let of_oas_usage (u : Agent_sdk.Types.api_usage) : Agent_sdk.Types.api_usage = u
let to_oas_usage (u : Agent_sdk.Types.api_usage) : Agent_sdk.Types.api_usage = u
