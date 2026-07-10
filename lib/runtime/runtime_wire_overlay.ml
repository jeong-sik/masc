(** Wire-layer overlays that MASC applies after OAS resolves a provider config.

    This module owns transport-shape repairs, not provider/model identity.
    Provider and model truth remains in OAS plus runtime.toml. *)

let auth_header_authorization = "Authorization"

let api_key_from_env name =
  match String.trim name with
  | "" -> ""
  | env_name ->
    (match Env_config_core.raw_value_opt env_name with
     | Some value -> value
     | None -> "")
;;

let headers_for_provider_cfg (provider_cfg : Llm_provider.Provider_config.t) =
  provider_cfg.headers
;;

let request_kind_of_provider_cfg (provider_cfg : Llm_provider.Provider_config.t) =
  match provider_cfg.kind with
  | Anthropic -> Agent_sdk.Provider.Anthropic_messages
  | OpenAI_compat
  | Ollama
  | Gemini
  | Glm
  | Kimi
  | DashScope -> Agent_sdk.Provider.Openai_chat_completions
;;

let register_capability_overlay_provider
      ~(name : string)
      ~(provider_cfg : Llm_provider.Provider_config.t)
  =
  (* OAS 0.208.7 (#2355) exposes
     [Provider.capabilities = Llm_provider.Capabilities.capabilities], so
     [capabilities_for_provider_config] already returns the registration type.
     The former 41-field hand-copy (agent_capabilities_of_llm_capabilities) was
     the identity and is removed — this ends the recurring capability-mirror
     drift where adding an OAS field (e.g. reasoning_output_format /
     reasoning_streaming_format) broke the copy until each field was mirrored. *)
  let capabilities =
    Agent_sdk.Provider_runtime_binding.capabilities_for_provider_config provider_cfg
  in
  Agent_sdk.Provider.register_provider
    { name
    ; request_kind = request_kind_of_provider_cfg provider_cfg
    ; request_path = provider_cfg.request_path
    ; capabilities
    ; build_body =
        (fun ~config:_ ~messages:_ ?tools:_ () ->
           invalid_arg
             "MASC runtime capability overlay providers require an injected \
              Llm_transport")
    ; parse_response =
        (fun _ ->
           invalid_arg
             "MASC runtime capability overlay providers require an injected \
              Llm_transport")
    ; resolve =
        (fun provider ->
           let api_key =
             if Llm_provider.Secret.is_empty provider_cfg.api_key
             then api_key_from_env provider.Agent_sdk.Provider.api_key_env
             else Llm_provider.Secret.header_value provider_cfg.api_key
           in
           Ok
             ( provider_cfg.base_url
             , api_key
             , headers_for_provider_cfg provider_cfg ))
    }
;;

let apply_capability_overlay
      ~(provider_cfg : Llm_provider.Provider_config.t)
      (provider : Agent_sdk.Provider.config)
  =
  match provider_cfg.supports_tool_choice_override with
  | None -> provider
  | Some _ ->
    let name = Llm_provider.Provider_registry.provider_name_of_config provider_cfg in
    let registry = Llm_provider.Provider_registry.default () in
    (match Llm_provider.Provider_registry.find registry name with
     | None -> provider
     | Some _ ->
       register_capability_overlay_provider ~name ~provider_cfg;
       { provider with provider = Agent_sdk.Provider.Custom_registered { name } })
;;

let apply
      ~(provider_cfg : Llm_provider.Provider_config.t)
      (provider : Agent_sdk.Provider.config)
  : Agent_sdk.Provider.config
  =
  let provider =
    match provider_cfg.kind, provider.provider with
    | ( Llm_provider.Provider_config.OpenAI_compat
      , Agent_sdk.Provider.Local { base_url } )
      when not
             (String.equal
                provider_cfg.request_path
                Masc_network_defaults.openai_chat_completions_path) ->
      let api_key_value = Llm_provider.Secret.header_value provider_cfg.api_key in
      let auth_header =
        if String.equal api_key_value "" then None else Some auth_header_authorization
      in
      let static_token =
        if String.equal api_key_value "" then None else Some api_key_value
      in
      { provider with
        provider =
          Agent_sdk.Provider.OpenAICompat
            { base_url; auth_header; path = provider_cfg.request_path; static_token }
      }
    | _ -> provider
  in
  apply_capability_overlay ~provider_cfg provider
;;
