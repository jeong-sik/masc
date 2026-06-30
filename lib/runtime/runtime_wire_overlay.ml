(** Wire-layer overlays that MASC applies after OAS resolves a provider config.

    This module owns transport-shape repairs, not provider/model identity.
    Provider and model truth remains in OAS plus runtime.toml. *)

let auth_header_authorization = "Authorization"

let api_key_from_env name =
  match String.trim name with
  | "" -> ""
  | env_name ->
    (match Sys.getenv_opt env_name with
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

let agent_capabilities_of_llm_capabilities
      (caps : Llm_provider.Capabilities.capabilities)
  : Agent_sdk.Provider.capabilities
  =
  { max_context_tokens = caps.max_context_tokens
  ; max_output_tokens = caps.max_output_tokens
  ; supports_tools = caps.supports_tools
  ; supports_tool_choice = caps.supports_tool_choice
  ; supports_required_tool_choice = caps.supports_required_tool_choice
  ; supports_named_tool_choice = caps.supports_named_tool_choice
  ; supports_parallel_tool_calls = caps.supports_parallel_tool_calls
  ; supports_runtime_mcp_tools = caps.supports_runtime_mcp_tools
  ; supports_runtime_tool_events = caps.supports_runtime_tool_events
  ; assistant_tool_content_format = caps.assistant_tool_content_format
  ; supports_reasoning = caps.supports_reasoning
  ; supports_extended_thinking = caps.supports_extended_thinking
  ; supports_reasoning_budget = caps.supports_reasoning_budget
  ; accepted_reasoning_efforts = caps.accepted_reasoning_efforts
  ; thinking_control_format = caps.thinking_control_format
  ; preserve_thinking_control_format = caps.preserve_thinking_control_format
  ; reasoning_replay_override = caps.reasoning_replay_override
  ; supports_response_format_json = caps.supports_response_format_json
  ; supports_structured_output = caps.supports_structured_output
  ; supports_multimodal_inputs = caps.supports_multimodal_inputs
  ; supports_image_input = caps.supports_image_input
  ; supports_audio_input = caps.supports_audio_input
  ; supports_video_input = caps.supports_video_input
  ; modality_priority = caps.modality_priority
  ; supports_native_streaming = caps.supports_native_streaming
  ; supports_system_prompt = caps.supports_system_prompt
  ; supports_caching = caps.supports_caching
  ; supports_prompt_caching = caps.supports_prompt_caching
  ; prompt_cache_alignment = caps.prompt_cache_alignment
  ; supports_top_k = caps.supports_top_k
  ; supports_min_p = caps.supports_min_p
  ; supports_seed = caps.supports_seed
  ; supports_seed_with_images = caps.supports_seed_with_images
  ; supports_computer_use = caps.supports_computer_use
  ; supports_code_execution = caps.supports_code_execution
  ; emits_usage_tokens = caps.emits_usage_tokens
  ; supported_models = caps.supported_models
  }
;;

let register_capability_overlay_provider
      ~(name : string)
      ~(provider_cfg : Llm_provider.Provider_config.t)
  =
  let capabilities =
    Agent_sdk.Provider_runtime_binding.capabilities_for_provider_config provider_cfg
    |> agent_capabilities_of_llm_capabilities
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
