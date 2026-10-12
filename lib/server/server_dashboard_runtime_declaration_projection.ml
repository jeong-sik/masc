let runtime_inventory_source = Config_dir_resolver.runtime_toml_filename

let runtime_transport_string = function
  | Runtime_schema.Http _ -> "http"
  | Runtime_schema.Cli _ -> "cli"
;;

let runtime_auth_kind_of_credential = function
  | None -> "none"
  | Some (Runtime_schema.Env key) -> "env:" ^ key
  | Some (Runtime_schema.File path) -> "file:" ^ path
  | Some (Runtime_schema.Inline _) -> "inline"
;;

(* Canonical wire strings for the thinking-control-format capability, matching
   the forms lib/runtime/runtime_toml.ml's parser accepts so the projection
   round-trips. Exhaustive by construction — a new variant fails to compile
   here rather than silently emitting a stale label. *)
let thinking_control_format_wire : Runtime_schema.thinking_control_format -> string = function
  | Runtime_schema.No_thinking_control -> "none"
  | Runtime_schema.Thinking_object -> "thinking-object"
  | Runtime_schema.Thinking_object_adaptive -> "thinking-object-adaptive"
  | Runtime_schema.Thinking_object_only -> "thinking-object-only"
  | Runtime_schema.Chat_template_kwargs -> "chat-template-kwargs"
  | Runtime_schema.Chat_template_token _ -> "chat-template-token"
  | Runtime_schema.Ollama_think -> "ollama-think"
  | Runtime_schema.Reasoning_effort -> "reasoning-effort"
;;

let preserve_thinking_control_format_wire
  : Llm_provider.Capabilities.preserve_thinking_control_format -> string
  = function
  | No_preserve_thinking_control -> "none"
  | Thinking_object_keep_all -> "thinking-object-keep-all"
  | Thinking_object_clear_thinking -> "thinking-object-clear-thinking"
  | Chat_template_kwargs_preserve_thinking -> "chat-template-kwargs-preserve-thinking"
  | Always_preserved_thinking -> "always-preserved-thinking"
;;

let assistant_tool_content_format_wire
  : Llm_provider.Capabilities.assistant_tool_content_format -> string
  = function
  | Assistant_tool_content_null -> "null"
  | Assistant_tool_content_empty_string -> "empty-string"
;;

let reasoning_output_format_wire : Llm_provider.Capabilities.reasoning_output_format -> string =
  function
  | No_reasoning_output_format -> "none"
  | Split_reasoning_fields -> "split-reasoning-fields"
;;

let reasoning_streaming_format_json
  : Llm_provider.Capabilities.reasoning_streaming_format -> Yojson.Safe.t
  = function
  | Default_reasoning_streaming -> `Assoc [ "kind", `String "default" ]
  | No_reasoning_streaming -> `Assoc [ "kind", `String "none" ]
  | Delta_reasoning_field field ->
    `Assoc [ "kind", `String "delta-reasoning-field"; "field", `String field ]
  | Delta_reasoning_field_and_details field ->
    `Assoc
      [ "kind", `String "delta-reasoning-field-and-details"; "field", `String field ]
  | Template_reasoning_streaming -> `Assoc [ "kind", `String "template" ]
;;

let reasoning_replay_override_wire
  : Llm_provider.Capabilities.reasoning_replay_override -> string
  = function
  | Default_reasoning_replay -> "default"
  | Force_no_replay -> "force-no-replay"
  | Force_drop_without_tool_preserve_with_tool -> "drop-without-tool-preserve-with-tool"
  | Force_preserve_always -> "preserve-always"
  | Force_latest_user_turn_tool_calls -> "latest-user-turn-tool-calls"
;;

let task_json : Llm_provider.Capabilities.task option -> Yojson.Safe.t = function
  | None -> `Null
  | Some Transcription -> `String "transcription"
  | Some Speech -> `String "speech"
  | Some Image_generation -> `String "image-generation"
  | Some Video_generation -> `String "video-generation"
;;

let modality_priority_wire : Llm_provider.Modality.priority -> string = function
  | Preserve_input_order -> "preserve-input-order"
  | Visual_first -> "visual-first"
;;

let tool_choice_json : Llm_provider.Types.tool_choice option -> Yojson.Safe.t = function
  | None -> `Null
  | Some Llm_provider.Types.Auto -> `Assoc [ "kind", `String "auto" ]
  | Some Llm_provider.Types.Any -> `Assoc [ "kind", `String "required" ]
  | Some Llm_provider.Types.None_ -> `Assoc [ "kind", `String "none" ]
  | Some (Llm_provider.Types.Tool name) ->
    `Assoc [ "kind", `String "tool"; "name", `String name ]
;;

let response_format_json : Llm_provider.Types.response_format -> Yojson.Safe.t = function
  | Llm_provider.Types.Off -> `Assoc [ "kind", `String "off"; "has_schema", `Bool false ]
  | Llm_provider.Types.JsonMode ->
    `Assoc [ "kind", `String "json_mode"; "has_schema", `Bool false ]
  | Llm_provider.Types.JsonSchema _ ->
    `Assoc [ "kind", `String "json_schema"; "has_schema", `Bool true ]
;;

let runtime_request_config_json (rt : Runtime_instance.t) =
  match rt.execution with
  | Runtime_execution.Codex_app_server config ->
    `Assoc
      [ "source", `String "official-client-runtime"
      ; "execution", `String "codex_app_server"
      ; "model", Json_util.string_opt_to_json config.model
      ; "timeout_s", `Float config.timeout_s
      ; "verified", `Bool false
      ]
  | Runtime_execution.Antigravity_cli config ->
    `Assoc
      [ "source", `String "official-client-runtime"
      ; "execution", `String "antigravity_cli"
      ; "model", `String config.model
      ; "agent", Json_util.string_opt_to_json config.agent
      ; ( "effort"
        , Json_util.string_opt_to_json
            (Option.map
               (function
                 | Runtime_antigravity.Low -> "low"
                 | Runtime_antigravity.Medium -> "medium"
                 | Runtime_antigravity.High -> "high")
               config.effort) )
      ; "execution_mode", `String "plan"
      ; "sandbox", `Bool true
      ; "disable_slash_commands", `Bool true
      ; "timeout_s", `Float config.timeout_s
      ; "verified", `Bool false
      ]
  | Runtime_execution.Claude_code config ->
    `Assoc
      [ "source", `String "official-client-runtime"
      ; "execution", `String "claude_code"
      ; "model", Json_util.string_opt_to_json config.model
      ; "timeout_s", `Float config.timeout_s
      ; "execution_mode", `String "masc_mcp_only"
      ; "verified", `Bool false
      ]
  | Runtime_execution.Muse_serve config ->
    `Assoc
      [ "source", `String "official-client-runtime"
      ; "execution", `String (Runtime_execution.label rt.execution)
      ; "model", `String config.model
      ; "timeout_s", `Float config.timeout_s
      ; "verified", `Bool false
      ]
  | Runtime_execution.Agent_core cfg ->
    `Assoc
    [ "source", `String "agent_core-provider-config"
    ; "provider_kind", `String (Llm_provider.Provider_config.string_of_provider_kind cfg.kind)
    ; "request_path", `String cfg.request_path
    ; ( "request_path_targets_responses_api"
      , `Bool (Llm_provider.Provider_config.request_path_targets_responses_api cfg.request_path)
      )
    ; "max_tokens", Json_util.int_opt_to_json cfg.max_tokens
    ; "max_context", Json_util.int_opt_to_json cfg.max_context
    ; "temperature", Json_util.float_opt_to_json cfg.temperature
    ; "top_p", Json_util.float_opt_to_json cfg.top_p
    ; "top_k", Json_util.int_opt_to_json cfg.top_k
    ; "min_p", Json_util.float_opt_to_json cfg.min_p
    ; "has_system_prompt", `Bool (Option.is_some cfg.system_prompt)
    ; "enable_thinking", Json_util.bool_opt_to_json cfg.enable_thinking
    ; "preserve_thinking", Json_util.bool_opt_to_json cfg.preserve_thinking
    ; "clear_thinking", Json_util.bool_opt_to_json cfg.clear_thinking
    ; ( "resolved_reasoning_effort"
      , Json_util.string_opt_to_json
          (Option.map Llm_provider.Reasoning_effort.to_string cfg.reasoning_effort) )
    ; "tool_stream", `Bool cfg.tool_stream
    ; "tool_choice", tool_choice_json cfg.tool_choice
    ; "disable_parallel_tool_use", `Bool cfg.disable_parallel_tool_use
    ; "response_format", response_format_json cfg.response_format
    ; "cache_system_prompt", `Bool cfg.cache_system_prompt
    ; ( "supports_structured_output_override"
      , Json_util.bool_opt_to_json cfg.supports_structured_output_override )
    ; "has_model_capabilities_override", `Bool (Option.is_some cfg.model_capabilities_override)
    ; "keep_alive", Json_util.string_opt_to_json cfg.keep_alive
    ; "internal_model_rotation_count", Json_util.int_opt_to_json cfg.internal_model_rotation_count
    ; "num_ctx", Json_util.int_opt_to_json cfg.num_ctx
    ; "return_progress", `Bool cfg.return_progress
    ; "seed", Json_util.int_opt_to_json cfg.seed
    ; "has_previous_response_id", `Bool (Option.is_some cfg.previous_response_id)
    ; "connect_timeout_s", Json_util.float_opt_to_json cfg.connect_timeout_s
    ]
;;

let runtime_api_format_wire : Runtime_schema.api_format -> string = function
  | Runtime_schema.Messages_api -> "messages"
  | Runtime_schema.Chat_completions_api -> "chat-completions"
  | Runtime_schema.Ollama_api -> "ollama"
  | Runtime_schema.Gemini_api -> "gemini"
  | Runtime_schema.Vertex_gemini_api -> "vertex-gemini"
  | Runtime_schema.Codex_app_server_runtime -> "codex-app-server"
  | Runtime_schema.Antigravity_cli_runtime -> "antigravity-cli"
  | Runtime_schema.Claude_code_runtime -> "claude-code"
  | Runtime_schema.Muse_serve_runtime -> "muse-serve"
;;

let runtime_provider_behavior_capabilities_json
    (capabilities : Runtime_schema.capabilities option) =
  match capabilities with
  | None -> `Null
  | Some caps ->
    `Assoc
      [ "supports_inline_tools", `Bool caps.supports_inline_tools
      ; "argv_prompt_preflight", `Bool caps.argv_prompt_preflight
      ; "uses_anthropic_caching", `Bool caps.uses_anthropic_caching
      ]
;;

let runtime_declared_model_capabilities_json
    (capabilities : Runtime_schema.model_capabilities option) =
  match capabilities with
  | None -> `Null
  | Some caps ->
    `Assoc
      [ "source", `String runtime_inventory_source
      ; "max_output_tokens", Json_util.int_opt_to_json caps.max_output_tokens
      ; "supports_tool_choice", Json_util.bool_opt_to_json caps.supports_tool_choice
      ; "supports_required_tool_choice", Json_util.bool_opt_to_json caps.supports_required_tool_choice
      ; "supports_named_tool_choice", Json_util.bool_opt_to_json caps.supports_named_tool_choice
      ; "supports_parallel_tool_calls", Json_util.bool_opt_to_json caps.supports_parallel_tool_calls
      ; "thinking_control_format", `String (thinking_control_format_wire caps.thinking_control_format)
      ; "supports_image_input", Json_util.bool_opt_to_json caps.supports_image_input
      ; "supports_audio_input", Json_util.bool_opt_to_json caps.supports_audio_input
      ; "supports_video_input", Json_util.bool_opt_to_json caps.supports_video_input
      ; "supports_multimodal_inputs", Json_util.bool_opt_to_json caps.supports_multimodal_inputs
      ; "supports_response_format_json", Json_util.bool_opt_to_json caps.supports_response_format_json
      ; "supports_structured_output", Json_util.bool_opt_to_json caps.supports_structured_output
      ; "supports_system_prompt", Json_util.bool_opt_to_json caps.supports_system_prompt
      ; "supports_assistant_prefill", Json_util.bool_opt_to_json caps.supports_assistant_prefill
      ; "supports_prompt_caching", Json_util.bool_opt_to_json caps.supports_prompt_caching
      ; "supports_top_k", Json_util.bool_opt_to_json caps.supports_top_k
      ; "supports_min_p", Json_util.bool_opt_to_json caps.supports_min_p
      ; "supports_seed", Json_util.bool_opt_to_json caps.supports_seed
      ; "emits_usage_tokens", Json_util.bool_opt_to_json caps.emits_usage_tokens
      ]
;;

let runtime_declared_spec_json (rt : Runtime_instance.t) =
  `Assoc
    [ "source", `String runtime_inventory_source
    ; ( "provider"
      , `Assoc
          [ "id", `String rt.provider.id
          ; "display_name", `String rt.provider.display_name
          ; "protocol", `String rt.provider.protocol
          ; "max_context", Json_util.int_opt_to_json rt.provider.max_context
          ; "api_format", `String (runtime_api_format_wire rt.provider.api_format)
          ; "transport", `String (runtime_transport_string rt.provider.transport)
          ; "auth_kind", `String (runtime_auth_kind_of_credential rt.provider.credentials)
          ; "is_non_interactive", `Bool rt.provider.is_non_interactive
          ; "has_capabilities", `Bool (Option.is_some rt.provider.capabilities)
          ; ( "behavior_capabilities"
            , runtime_provider_behavior_capabilities_json rt.provider.capabilities )
          ; ( "custom_header_count"
            , `Int
                (match rt.provider.headers with
                 | None -> 0
                 | Some headers -> List.length headers) )
          ; "connect_timeout_s", Json_util.float_opt_to_json rt.provider.connect_timeout_s
          ; "exact_body_timeout_s", Json_util.float_opt_to_json rt.provider.exact_body_timeout_s
          ] )
    ; ( "model"
      , `Assoc
          [ "id", `String rt.model.id
          ; "api_name", `String rt.model.api_name
          ; "tools_support", `Bool rt.model.tools_support
          ; "max_context", Json_util.int_opt_to_json rt.model.max_context
          ; "thinking_support", Json_util.bool_opt_to_json rt.model.thinking_support
          ; "preserve_thinking", Json_util.bool_opt_to_json rt.model.preserve_thinking
          ; "streaming", `Bool rt.model.streaming
          ; "temperature", Json_util.float_opt_to_json rt.model.temperature
          ; "top_p", Json_util.float_opt_to_json rt.model.top_p
          ; "top_k", Json_util.int_opt_to_json rt.model.top_k
          ; "min_p", Json_util.float_opt_to_json rt.model.min_p
          ; "capabilities", runtime_declared_model_capabilities_json rt.model.capabilities
          ] )
    ; ( "binding"
      , `Assoc
          [ "provider_id", `String rt.binding.provider_id
          ; "model_id", `String rt.binding.model_id
          ; "max_context", Json_util.int_opt_to_json rt.binding.max_context
          ; "is_default", `Bool rt.binding.is_default
          ; "max_concurrent", Json_util.int_opt_to_json rt.binding.max_concurrent
          ; "disable_parallel_tool_use", `Bool rt.binding.disable_parallel_tool_use
          ; "price_input", Json_util.float_opt_to_json rt.binding.price_input
          ; "price_output", Json_util.float_opt_to_json rt.binding.price_output
          ; "keep_alive", Json_util.string_opt_to_json rt.binding.keep_alive
          ; "num_ctx", Json_util.int_opt_to_json rt.binding.num_ctx
          ; "return_progress", Json_util.bool_opt_to_json rt.binding.return_progress
          ] )
    ]
;;
