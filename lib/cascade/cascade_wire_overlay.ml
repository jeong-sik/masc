(** Wire-layer overlays that MASC applies after OAS resolves a provider config.

    This module owns transport-shape repairs, not provider/model identity.
    Provider and model truth remains in OAS plus cascade.toml. *)

let auth_header_authorization = "Authorization"

let apply
      ~(provider_cfg : Llm_provider.Provider_config.t)
      (provider : Agent_sdk.Provider.config)
  : Agent_sdk.Provider.config
  =
  match provider_cfg.kind, provider.provider with
  | Llm_provider.Provider_config.OpenAI_compat, Agent_sdk.Provider.Local { base_url }
    when not
           (String.equal
              provider_cfg.request_path
              Masc_network_defaults.openai_chat_completions_path) ->
    let api_key_trimmed = String.trim provider_cfg.api_key in
    let auth_header =
      if String.equal api_key_trimmed "" then None else Some auth_header_authorization
    in
    let static_token =
      if String.equal api_key_trimmed "" then None else Some api_key_trimmed
    in
    { provider with
      provider =
        Agent_sdk.Provider.OpenAICompat
          { base_url; auth_header; path = provider_cfg.request_path; static_token }
    }
  | _ -> provider
;;
