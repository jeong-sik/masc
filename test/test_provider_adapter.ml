open Alcotest

module Adapter = Masc_mcp.Provider_adapter

let with_env name value f =
  let previous = Sys.getenv_opt name in
  (match value with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let test_resolve_direct_aliases () =
  let claude = Option.get (Adapter.resolve_direct_adapter "anthropic") in
  check string "claude alias" "claude-api" claude.canonical_name;
  let gemini = Option.get (Adapter.resolve_direct_adapter "google") in
  check string "gemini alias" "gemini-api" gemini.canonical_name;
  let codex = Option.get (Adapter.resolve_direct_adapter "openai") in
  check string "codex-api alias" "codex-api" codex.canonical_name;
  let kimi = Option.get (Adapter.resolve_direct_adapter "kimi-api") in
  check string "kimi direct canonical" "kimi-api" kimi.canonical_name

let test_resolve_cli_canonical_names () =
  let claude = Option.get (Adapter.resolve_direct_adapter "claude") in
  check string "claude canonical" "claude" claude.canonical_name;
  check string "claude runtime" "cli_agent"
    (Adapter.string_of_runtime_kind claude.runtime_kind);
  let gemini = Option.get (Adapter.resolve_direct_adapter "gemini") in
  check string "gemini canonical" "gemini" gemini.canonical_name;
  let kimi = Option.get (Adapter.resolve_direct_adapter "kimi") in
  check string "kimi canonical" "kimi" kimi.canonical_name;
  let codex = Option.get (Adapter.resolve_direct_adapter "codex") in
  check string "codex canonical" "codex" codex.canonical_name

let test_kimi_direct_auth_accepts_primary_and_fallback_envs () =
  with_env "KIMI_API_KEY_SB" None (fun () ->
      with_env "KIMI_API_KEY" (Some "kimi-key") (fun () ->
          check bool "kimi direct auth available via fallback env" true
            (Adapter.provider_auth_available "kimi-api");
          check (list string) "kimi direct env keys"
            [ "KIMI_API_KEY_SB"; "KIMI_API_KEY" ]
            (Adapter.auth_env_keys_of_provider_kind
               Llm_provider.Provider_config.Kimi)))

let test_provider_kind_string_uses_oas_ssot () =
  check string "anthropic ssot" "anthropic"
    (Adapter.string_of_provider_kind Llm_provider.Provider_config.Anthropic);
  check string "openai_compat ssot" "openai_compat"
    (Adapter.string_of_provider_kind Llm_provider.Provider_config.OpenAI_compat);
  check string "claude_code ssot" "claude_code"
    (Adapter.string_of_provider_kind Llm_provider.Provider_config.Claude_code)

let test_cascade_prefix_of_provider_kind_keeps_adapter_mapping () =
  check string "anthropic prefix" "claude"
    (Adapter.cascade_prefix_of_provider_kind
       Llm_provider.Provider_config.Anthropic);
  check string "openai compat prefix" "openai"
    (Adapter.cascade_prefix_of_provider_kind
       Llm_provider.Provider_config.OpenAI_compat);
  check string "codex cli prefix" "codex_cli"
    (Adapter.cascade_prefix_of_provider_kind
       Llm_provider.Provider_config.Codex_cli)

let test_auth_env_keys_of_provider_kind_defaults () =
  check (list string) "anthropic env keys" [ "ANTHROPIC_API_KEY" ]
    (Adapter.auth_env_keys_of_provider_kind
       Llm_provider.Provider_config.Anthropic);
  check (list string) "openai compat env keys" [ "OPENAI_API_KEY" ]
    (Adapter.auth_env_keys_of_provider_kind
       Llm_provider.Provider_config.OpenAI_compat);
  check (list string) "glm env keys" [ "ZAI_API_KEY" ]
    (Adapter.auth_env_keys_of_provider_kind Llm_provider.Provider_config.Glm);
  check (list string) "ollama env keys" []
    (Adapter.auth_env_keys_of_provider_kind
       Llm_provider.Provider_config.Ollama);
  check (list string) "claude code env keys" []
    (Adapter.auth_env_keys_of_provider_kind
       Llm_provider.Provider_config.Claude_code)

let test_gemini_auth_env_key_paths () =
  check (list string) "gemini inventory env keys"
    [ "GOOGLE_CLOUD_PROJECT"; "GOOGLE_CLOUD_LOCATION" ]
    (Adapter.auth_env_keys_of_provider_kind
       Llm_provider.Provider_config.Gemini);
  let config =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.Gemini
      ~model_id:"gemini-3.1-pro-preview"
      ~base_url:"https://generativelanguage.googleapis.com"
      ()
  in
  check (list string) "gemini docker env keys" [ "GEMINI_API_KEY" ]
    (Adapter.docker_auth_env_keys_of_provider_config config)

let test_gemini_direct_auth_vertex_adc () =
  with_env "GOOGLE_CLOUD_PROJECT" (Some "demo-project") (fun () ->
      with_env "GOOGLE_CLOUD_LOCATION" (Some "asia-northeast3") (fun () ->
          with_env "GEMINI_API_KEY" None (fun () ->
              match Adapter.resolve_gemini_direct_auth () with
              | Adapter.Gemini_vertex_adc { project; location } ->
                  check string "project" "demo-project" project;
                  check string "location" "asia-northeast3" location
              | _ -> fail "expected vertex adc")))

let test_gemini_direct_auth_api_key_fallback () =
  with_env "GOOGLE_CLOUD_PROJECT" None (fun () ->
      with_env "GEMINI_API_KEY" (Some "dummy-key") (fun () ->
          match Adapter.resolve_gemini_direct_auth () with
          | Adapter.Gemini_api_key -> ()
          | _ -> fail "expected api key fallback"))

let test_gemini_direct_auth_missing () =
  with_env "GOOGLE_CLOUD_PROJECT" None (fun () ->
      with_env "GEMINI_API_KEY" None (fun () ->
          match Adapter.resolve_gemini_direct_auth () with
          | Adapter.Gemini_auth_missing message ->
              check bool "actionable message" true (String.length message > 0)
          | _ -> fail "expected missing auth"))

let test_vertex_base_url () =
  check string "vertex base url"
    "https://aiplatform.googleapis.com/v1/projects/demo/locations/global/endpoints/openapi"
    (Adapter.gemini_vertex_openai_base_url ~project:"demo" ~location:"global")

let test_default_cli_agent_name () =
  check string "default cli agent" "auto"
    (Adapter.default_cli_agent_name ())

let test_default_local_model_label () =
  with_env "MASC_DEFAULT_PROVIDER" (Some "test-provider") (fun () ->
      with_env "MASC_DEFAULT_MODEL" (Some "test-model") (fun () ->
          match Adapter.default_model_label_result () with
          | Ok label ->
              check string "default local label" "test-provider:test-model" label
          | Error msg -> fail msg))

let test_default_model_provider_prefix_result () =
  with_env "MASC_DEFAULT_PROVIDER" (Some "test-provider") (fun () ->
      with_env "MASC_DEFAULT_MODEL" (Some "test-model") (fun () ->
          match Adapter.default_model_provider_prefix_result () with
          | Ok prefix -> check string "default provider prefix" "test-provider" prefix
          | Error msg -> fail msg))

let test_default_model_override_label_result () =
  with_env "MASC_DEFAULT_PROVIDER" (Some "gemini") (fun () ->
      with_env "MASC_DEFAULT_MODEL" (Some "gemini-3.1-pro-preview") (fun () ->
          match Adapter.default_model_override_label_result "gemini-3-flash-preview" with
          | Ok label ->
              check string "override keeps provider" "gemini:gemini-3-flash-preview"
                label
          | Error msg -> fail msg))

let test_resolve_voice_aliases () =
  let elevenlabs = Option.get (Adapter.resolve_voice_adapter "elevenlabs") in
  check string "elevenlabs alias" "elevenlabs-direct" elevenlabs.canonical_name;
  let openai_compat = Option.get (Adapter.resolve_voice_adapter "openai_compat") in
  check string "openai compat alias" "voice-openai-compat"
    openai_compat.canonical_name

let test_voice_auth_env_resolution () =
  let elevenlabs = Option.get (Adapter.resolve_voice_adapter "elevenlabs-direct") in
  check (option string) "elevenlabs auth env"
    (Some "ELEVENLABS_API_KEY")
    (Adapter.voice_auth_env_name elevenlabs);
  let openai_compat = Option.get (Adapter.resolve_voice_adapter "voice-openai-compat") in
  check (option string) "endpoint override auth env"
    (Some "VOICE_PROXY_KEY")
    (Adapter.voice_auth_env_name ~endpoint_api_key_env:"VOICE_PROXY_KEY" openai_compat)

let test_stt_request_elevenlabs_direct () =
  let endpoint : Masc_mcp.Voice_config.endpoint =
    { id = "test-stt"; kind = Elevenlabs_direct;
      base_url = Some "https://api.elevenlabs.io/v1";
      mcp_url = None; health_url = None;
      api_key_env = Some "ELEVENLABS_API_KEY";
      enabled = true; timeout_seconds = Some 30.0; max_retries = Some 2 }
  in
  with_env "ELEVENLABS_API_KEY" (Some "test-key-123") (fun () ->
    match Adapter.voice_stt_request_for_endpoint endpoint
            ~api_key:"test-key-123" ~audio_file:"/tmp/test.wav"
            ~model:"scribe_v2" with
    | Ok req ->
        check string "url" "https://api.elevenlabs.io/v1/speech-to-text" req.url;
        check bool "has xi-api-key header" true
          (List.exists (fun (k, _) -> k = "xi-api-key") req.headers);
        check bool "model_id in form_fields" true
          (List.exists (fun (k, v) -> k = "model_id" && v = "scribe_v2")
             req.form_fields);
        let field_name, file_path = req.file_field in
        check string "file field name" "file" field_name;
        check string "file path" "/tmp/test.wav" file_path
    | Error err -> fail (Printf.sprintf "expected Ok, got Error: %s" err))

let test_stt_request_openai_compat () =
  let endpoint : Masc_mcp.Voice_config.endpoint =
    { id = "test-openai-stt"; kind = Openai_compat;
      base_url = Some "https://api.openai.com/v1";
      mcp_url = None; health_url = None;
      api_key_env = Some "OPENAI_API_KEY";
      enabled = true; timeout_seconds = Some 30.0; max_retries = Some 2 }
  in
  match Adapter.voice_stt_request_for_endpoint endpoint
          ~api_key:"sk-test" ~audio_file:"/tmp/test.wav"
          ~model:"whisper-1" with
  | Ok req ->
      check string "url" "https://api.openai.com/v1/audio/transcriptions" req.url;
      check bool "has Authorization header" true
        (List.exists (fun (k, _) -> k = "Authorization") req.headers);
      check bool "model in form_fields" true
        (List.exists (fun (k, v) -> k = "model" && v = "whisper-1")
           req.form_fields)
  | Error err -> fail (Printf.sprintf "expected Ok, got Error: %s" err)

let test_requires_discovery_llama () =
  check bool "llama requires discovery" true
    (Adapter.requires_discovery "llama");
  check bool "llamacpp requires discovery" true
    (Adapter.requires_discovery "llamacpp");
  check bool "LLAMA case insensitive" true
    (Adapter.requires_discovery "LLAMA")

let test_requires_discovery_cloud () =
  check bool "claude does not require discovery" false
    (Adapter.requires_discovery "claude");
  check bool "gemini does not require discovery" false
    (Adapter.requires_discovery "gemini");
  check bool "custom does not require discovery" false
    (Adapter.requires_discovery "custom")

let test_is_local_provider_llama () =
  check bool "llama is local" true
    (Adapter.is_local_provider "llama");
  check bool "llamacpp is local" true
    (Adapter.is_local_provider "llamacpp")

let test_is_local_provider_custom () =
  check bool "custom is local" true
    (Adapter.is_local_provider "custom");
  check bool "CUSTOM case insensitive" true
    (Adapter.is_local_provider "CUSTOM")

let test_is_local_provider_cloud () =
  check bool "claude is not local" false
    (Adapter.is_local_provider "claude");
  check bool "gemini is not local" false
    (Adapter.is_local_provider "gemini");
  check bool "unknown is not local" false
    (Adapter.is_local_provider "unknown-provider")

let test_make_local_label () =
  check string "make_local_label basic" "llama:qwen3.5"
    (Adapter.make_local_label "qwen3.5");
  check string "make_local_label preserves model id" "llama:some-model"
    (Adapter.make_local_label "some-model");
  (* Verify make_local_label uses the same prefix as the llama adapter *)
  check string "prefix matches cn_llama" Adapter.local_cascade_prefix
    Adapter.cn_llama

let test_default_local_fallback_label () =
  let label = Adapter.default_local_fallback_label () in
  check bool "fallback label contains colon" true
    (String.contains label ':');
  check bool "fallback label ends with :auto" true
    (let suffix = ":auto" in
     let slen = String.length label in
     let plen = String.length suffix in
     slen >= plen && String.sub label (slen - plen) plen = suffix)

let test_stt_request_mcp_rejected () =
  let endpoint : Masc_mcp.Voice_config.endpoint =
    { id = "test-mcp-stt"; kind = Voice_mcp;
      base_url = None; mcp_url = Some "http://localhost:8936";
      health_url = None; api_key_env = None;
      enabled = true; timeout_seconds = Some 5.0; max_retries = Some 1 }
  in
  match Adapter.voice_stt_request_for_endpoint endpoint
          ~api_key:"" ~audio_file:"/tmp/test.wav" ~model:"scribe_v2" with
  | Ok _ -> fail "expected Error for voice_mcp endpoint"
  | Error _ -> ()

let test_auto_models_use_declared_policy () =
  with_env "MASC_KIMI_CLI_AUTO_MODELS" None (fun () ->
      check (option (list string)) "kimi cli declared default"
        (Some [ "kimi-for-coding" ])
        (Adapter.auto_models_for_cascade_prefix "kimi_cli");
      with_env "MASC_GEMINI_CLI_AUTO_MODELS" None (fun () ->
          with_env "GEMINI_DEFAULT_MODEL" (Some "gemini-3-flash-preview") (fun () ->
              check (option (list string)) "gemini cli prefers explicit default model env"
                (Some [ "gemini-3-flash-preview" ])
                (Adapter.auto_models_for_cascade_prefix "gemini_cli"))))

let test_runtime_mcp_header_support_uses_declared_policy () =
  let kimi_cli_cfg =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.Kimi_cli
      ~model_id:"kimi-for-coding"
      ~base_url:""
      ()
  in
  let codex_cli_cfg =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.Codex_cli
      ~model_id:"gpt-5.4"
      ~base_url:""
      ()
  in
  check bool "kimi cli supports runtime MCP headers" true
    (Adapter.supports_runtime_mcp_http_headers_for_config kimi_cli_cfg);
  check bool "codex cli does not support runtime MCP headers" false
    (Adapter.supports_runtime_mcp_http_headers_for_config codex_cli_cfg);
  check bool "claude code model label supports runtime MCP headers" true
    (Adapter.supports_runtime_mcp_http_headers_for_model_label
       "claude_code:auto");
  check bool "kimi cli model label supports runtime MCP headers" true
    (Adapter.supports_runtime_mcp_http_headers_for_model_label
       "kimi_cli:kimi-for-coding");
  check bool "bare exact cascade prefix uses registry" true
    (Adapter.supports_runtime_mcp_http_headers_for_model_label "kimi_cli");
  check bool "codex cli model label keeps declared false" false
    (Adapter.supports_runtime_mcp_http_headers_for_model_label
       "codex_cli:gpt-5.4");
  check bool "bare model id does not guess by substring" false
    (Adapter.supports_runtime_mcp_http_headers_for_model_label "gpt-5.4")

let test_provider_label_of_config_preserves_cli_vs_api_identity () =
  let kimi_api_cfg =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat
      ~model_id:"kimi-k2.5"
      ~base_url:"https://api.moonshot.ai/v1"
      ~request_path:"/chat/completions"
      ()
  in
  let kimi_cli_cfg =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.Kimi_cli
      ~model_id:"kimi-for-coding"
      ~base_url:""
      ()
  in
  check string "kimi api label" "kimi"
    (Adapter.provider_label_of_config kimi_api_cfg);
  check string "kimi cli label" "kimi_cli"
    (Adapter.provider_label_of_config kimi_cli_cfg);
  check string "kimi cli model label" "kimi_cli:kimi-for-coding"
    (Adapter.model_label_of_config kimi_cli_cfg)

let test_provider_health_key_is_provider_scoped () =
  let cfg label =
    match Masc_mcp.Cascade_config.parse_model_string label with
    | Some cfg -> cfg
    | None -> fail ("expected model label to parse: " ^ label)
  in
  let claude_auto = cfg "claude_code:auto" in
  let claude_sonnet = cfg "claude_code:claude-sonnet-4-6" in
  let gemini_auto = cfg "gemini_cli:auto" in
  check string "same provider shares health key" "claude_code"
    (Adapter.provider_health_key_of_config claude_auto);
  check string "same provider different model shares health key"
    (Adapter.provider_health_key_of_config claude_auto)
    (Adapter.provider_health_key_of_config claude_sonnet);
  check bool "same model id across providers remains isolated" true
    (Adapter.provider_health_key_of_config claude_auto
     <> Adapter.provider_health_key_of_config gemini_auto)

let test_local_openai_compat_health_key_is_endpoint_scoped () =
  let cfg label =
    match Masc_mcp.Cascade_config.parse_model_string label with
    | Some cfg -> cfg
    | None -> fail ("expected model label to parse: " ^ label)
  in
  let primary = cfg "custom:primary@http://127.0.0.1:11111" in
  let fallback = cfg "custom:primary@http://127.0.0.1:22222" in
  check bool "same local model on different endpoints is isolated" true
    (Adapter.provider_health_key_of_config primary
     <> Adapter.provider_health_key_of_config fallback)

let test_provider_model_health_key_is_model_scoped () =
  let cfg label =
    match Masc_mcp.Cascade_config.parse_model_string label with
    | Some cfg -> cfg
    | None -> fail ("expected model label to parse: " ^ label)
  in
  let glm_code = cfg "glm-coding:glm-5-code" in
  let glm_51 = cfg "glm-coding:glm-5.1" in
  check string "provider health key stays provider scoped" "glm-coding"
    (Adapter.provider_health_key_of_config glm_code);
  check string "model health key includes concrete model" "glm-coding:glm-5-code"
    (Adapter.provider_model_health_key_of_config glm_code);
  check bool "sibling models do not share model health key" true
    (Adapter.provider_model_health_key_of_config glm_code
     <> Adapter.provider_model_health_key_of_config glm_51);
  check string "sibling models still share provider health key"
    (Adapter.provider_health_key_of_config glm_code)
    (Adapter.provider_health_key_of_config glm_51)

let test_provider_of_model_label_uses_typed_boundaries () =
  check string "explicit prefix wins over coarse kind" "glm-coding"
    (Adapter.provider_of_model_label
       ~provider_kind:Llm_provider.Provider_config.OpenAI_compat
       "glm-coding:glm-5.1");
  check string "bare labels do not guess" "unknown"
    (Adapter.provider_of_model_label "gpt-5.4");
  check string "typed bare label uses provider kind" "openai"
    (Adapter.provider_of_model_label
       ~provider_kind:Llm_provider.Provider_config.OpenAI_compat
       "gpt-5.4");
  check string "unknown explicit prefix stays unknown" "unknown"
    (Adapter.provider_of_model_label "private-provider:model-x")

let test_unmetered_provider_uses_declared_telemetry_policy () =
  check bool "kimi cli usage missing by design" true
    (Adapter.is_structurally_unmetered_provider "kimi_cli");
  check bool "codex cli usage missing by design" true
    (Adapter.is_structurally_unmetered_provider "codex_cli");
  check bool "gemini cli usage missing by design" true
    (Adapter.is_structurally_unmetered_provider "gemini_cli");
  check bool "claude code usage missing by design" true
    (Adapter.is_structurally_unmetered_provider "claude_code");
  check bool "ollama usage missing by design" true
    (Adapter.is_structurally_unmetered_provider "ollama");
  check bool "direct openai reports usage" false
    (Adapter.is_structurally_unmetered_provider "openai");
  check bool "unknown provider is not silently exempt" false
    (Adapter.is_structurally_unmetered_provider "unknown")

(* RFC-0058 Phase 5.6 boundary helper: apply_wire_overlay.

   These tests seal the invariant that the keeper layer no longer
   needs to pattern-match on [provider_cfg.kind] and the SDK's
   [provider] variant: every shape gets routed by this single helper
   inside [Provider_adapter]. *)

let agent_sdk_local_cfg ~base_url ~model_id ~api_key_env =
  { Agent_sdk.Provider.provider = Agent_sdk.Provider.Local { base_url }
  ; model_id
  ; api_key_env
  }

let agent_sdk_anthropic_cfg ~model_id ~api_key_env =
  { Agent_sdk.Provider.provider = Agent_sdk.Provider.Anthropic
  ; model_id
  ; api_key_env
  }

let test_apply_wire_overlay_rewraps_openai_compat_local_custom_path () =
  let cfg =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat
      ~model_id:"qwen3.6:35b-a3b-mlx-bf16"
      ~base_url:"http://127.0.0.1:11434"
      ~request_path:"/api/chat" (* non-default ollama-native path *)
      ~api_key:"secret-token"
      ()
  in
  let sdk_cfg =
    agent_sdk_local_cfg
      ~base_url:"http://127.0.0.1:11434"
      ~model_id:"qwen3.6:35b-a3b-mlx-bf16"
      ~api_key_env:""
  in
  let result = Adapter.apply_wire_overlay ~provider_cfg:cfg sdk_cfg in
  match result.provider with
  | Agent_sdk.Provider.OpenAICompat
      { base_url; auth_header; path; static_token } ->
    check string "base_url preserved" "http://127.0.0.1:11434" base_url;
    check (option string) "auth_header set when api_key non-empty"
      (Some "Authorization") auth_header;
    check string "non-default path forwarded" "/api/chat" path;
    check (option string) "static_token preserved" (Some "secret-token")
      static_token
  | _ -> fail "expected OpenAICompat overlay"

let test_apply_wire_overlay_keeps_local_when_path_is_default () =
  let cfg =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat
      ~model_id:"qwen3.6:35b-a3b-mlx-bf16"
      ~base_url:"http://127.0.0.1:11434"
      ~request_path:"/v1/chat/completions" (* canonical OpenAI path *)
      ()
  in
  let sdk_cfg =
    agent_sdk_local_cfg
      ~base_url:"http://127.0.0.1:11434"
      ~model_id:"qwen3.6:35b-a3b-mlx-bf16"
      ~api_key_env:""
  in
  let result = Adapter.apply_wire_overlay ~provider_cfg:cfg sdk_cfg in
  match result.provider with
  | Agent_sdk.Provider.Local { base_url } ->
    check string "default path leaves Local untouched"
      "http://127.0.0.1:11434" base_url
  | _ -> fail "default path must not trigger overlay"

let test_apply_wire_overlay_passthrough_for_anthropic () =
  let cfg =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.Claude_api
      ~model_id:"claude-sonnet-4-5"
      ~base_url:"https://api.anthropic.com"
      ()
  in
  let sdk_cfg =
    agent_sdk_anthropic_cfg ~model_id:"claude-sonnet-4-5"
      ~api_key_env:"ANTHROPIC_API_KEY"
  in
  let result = Adapter.apply_wire_overlay ~provider_cfg:cfg sdk_cfg in
  match result.provider with
  | Agent_sdk.Provider.Anthropic -> ()
  | _ -> fail "non-OpenAI_compat kind must pass through"

let test_apply_wire_overlay_omits_auth_header_when_key_blank () =
  let cfg =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat
      ~model_id:"local-model"
      ~base_url:"http://127.0.0.1:8000"
      ~request_path:"/api/chat"
      ~api_key:"   " (* whitespace-only treated as blank *)
      ()
  in
  let sdk_cfg =
    agent_sdk_local_cfg ~base_url:"http://127.0.0.1:8000"
      ~model_id:"local-model" ~api_key_env:""
  in
  let result = Adapter.apply_wire_overlay ~provider_cfg:cfg sdk_cfg in
  match result.provider with
  | Agent_sdk.Provider.OpenAICompat { auth_header; static_token; _ } ->
    check (option string) "auth_header None when key blank" None auth_header;
    check (option string) "static_token None when key blank" None static_token
  | _ -> fail "expected OpenAICompat overlay even with blank key"

let test_openai_compat_provider_identity_uses_endpoint_metadata () =
  let kimi_endpoint_cfg =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat
      ~model_id:"anything"
      ~base_url:"https://api.moonshot.ai/v1/"
      ~request_path:"/chat/completions"
      ()
  in
  let openai_endpoint_cfg =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat
      ~model_id:"kimi-k2.5"
      ~base_url:"https://api.openai.com"
      ~request_path:"/v1/chat/completions"
      ()
  in
  check string "moonshot endpoint maps to kimi adapter" "kimi"
    (Adapter.provider_label_of_config kimi_endpoint_cfg);
  check string "model id alone does not imply kimi" "openai"
    (Adapter.provider_label_of_config openai_endpoint_cfg)

(* RFC-0058 §2.4 SSOT bridge — cascade-decl capabilities → tool_policy. *)

let test_tool_policy_of_cascade_capabilities_none_is_conservative () =
  let policy = Adapter.tool_policy_of_cascade_capabilities None in
  check bool "None: supports_runtime_mcp_http_headers = false" false
    policy.supports_runtime_mcp_http_headers;
  check bool "None: requires_per_keeper_bridging = false" false
    policy.requires_per_keeper_bridging_for_bound_actor_tools;
  check (list string) "None: identity_runtime_mcp_header_keys = []" []
    policy.identity_runtime_mcp_header_keys;
  check bool "None: argv_prompt_preflight = false" false
    policy.argv_prompt_preflight;
  check bool "None: uses_anthropic_caching = false" false
    policy.uses_anthropic_caching;
  check (option int) "None: max_turns_per_attempt = None" None
    policy.max_turns_per_attempt;
  check bool "None: tolerates_bound_actor_fallback = false" false
    policy.tolerates_bound_actor_fallback

let test_tool_policy_of_cascade_capabilities_some_maps_subset () =
  let caps : Cascade_declarative_types.cascade_capabilities =
    {
      Cascade_declarative_types.cascade_capabilities_default with
      supports_runtime_mcp_http_headers = true;
      requires_per_keeper_bridging_for_bound_actor_tools = true;
      identity_runtime_mcp_header_keys = [ "authorization"; "x-openai-beta" ];
      argv_prompt_preflight = true;
      uses_anthropic_caching = true;
      max_turns_per_attempt = Some 8;
      tolerates_bound_actor_fallback = true;
    }
  in
  let policy = Adapter.tool_policy_of_cascade_capabilities (Some caps) in
  check bool "Some: supports_runtime_mcp_http_headers" true
    policy.supports_runtime_mcp_http_headers;
  check bool "Some: requires_per_keeper_bridging" true
    policy.requires_per_keeper_bridging_for_bound_actor_tools;
  check (list string) "Some: identity_runtime_mcp_header_keys"
    [ "authorization"; "x-openai-beta" ]
    policy.identity_runtime_mcp_header_keys;
  check bool "Some: argv_prompt_preflight" true
    policy.argv_prompt_preflight;
  check bool "Some: uses_anthropic_caching" true
    policy.uses_anthropic_caching;
  check (option int) "Some: max_turns_per_attempt" (Some 8)
    policy.max_turns_per_attempt;
  check bool "Some: tolerates_bound_actor_fallback" true
    policy.tolerates_bound_actor_fallback

let test_tool_policy_of_cascade_capabilities_default_matches_none () =
  let from_default =
    Adapter.tool_policy_of_cascade_capabilities
      (Some Cascade_declarative_types.cascade_capabilities_default)
  in
  let from_none = Adapter.tool_policy_of_cascade_capabilities None in
  check bool "default Some matches None: supports_runtime_mcp_http_headers"
    from_none.supports_runtime_mcp_http_headers
    from_default.supports_runtime_mcp_http_headers;
  check bool "default Some matches None: requires_per_keeper_bridging"
    from_none.requires_per_keeper_bridging_for_bound_actor_tools
    from_default.requires_per_keeper_bridging_for_bound_actor_tools;
  check (list string) "default Some matches None: identity headers"
    from_none.identity_runtime_mcp_header_keys
    from_default.identity_runtime_mcp_header_keys;
  check bool "default Some matches None: tolerates_bound_actor_fallback"
    from_none.tolerates_bound_actor_fallback
    from_default.tolerates_bound_actor_fallback

let () =
  run "Provider Adapter"
    [
      ( "registry",
        [
          test_case "resolve direct aliases" `Quick test_resolve_direct_aliases;
          test_case "resolve cli canonicals" `Quick test_resolve_cli_canonical_names;
          test_case "kimi direct auth accepts fallback envs" `Quick
            test_kimi_direct_auth_accepts_primary_and_fallback_envs;
          test_case "provider kind string uses oas ssot" `Quick
            test_provider_kind_string_uses_oas_ssot;
          test_case "cascade prefix keeps adapter mapping" `Quick
            test_cascade_prefix_of_provider_kind_keeps_adapter_mapping;
          test_case "provider kind auth env defaults" `Quick
            test_auth_env_keys_of_provider_kind_defaults;
          test_case "gemini auth env key paths" `Quick
            test_gemini_auth_env_key_paths;
          test_case "gemini vertex adc" `Quick test_gemini_direct_auth_vertex_adc;
          test_case "gemini api key fallback" `Quick
            test_gemini_direct_auth_api_key_fallback;
          test_case "gemini missing auth" `Quick test_gemini_direct_auth_missing;
          test_case "vertex base url" `Quick test_vertex_base_url;
          test_case "default cli agent" `Quick test_default_cli_agent_name;
          test_case "default local model label" `Quick test_default_local_model_label;
          test_case "default provider prefix" `Quick
            test_default_model_provider_prefix_result;
          test_case "default override label" `Quick
            test_default_model_override_label_result;
          test_case "declared auto model policy" `Quick
            test_auto_models_use_declared_policy;
          test_case "declared runtime MCP header policy" `Quick
            test_runtime_mcp_header_support_uses_declared_policy;
          test_case "provider label keeps cli vs api identity" `Quick
            test_provider_label_of_config_preserves_cli_vs_api_identity;
          test_case "provider health key is provider scoped" `Quick
            test_provider_health_key_is_provider_scoped;
          test_case "local openai compat health key is endpoint scoped" `Quick
            test_local_openai_compat_health_key_is_endpoint_scoped;
          test_case "provider model health key is model scoped" `Quick
            test_provider_model_health_key_is_model_scoped;
          test_case "provider model label uses typed boundaries" `Quick
            test_provider_of_model_label_uses_typed_boundaries;
          test_case "unmetered provider uses telemetry policy" `Quick
            test_unmetered_provider_uses_declared_telemetry_policy;
          test_case "openai compat identity uses endpoint metadata" `Quick
            test_openai_compat_provider_identity_uses_endpoint_metadata;
          test_case "resolve voice aliases" `Quick test_resolve_voice_aliases;
          test_case "voice auth env resolution" `Quick
            test_voice_auth_env_resolution;
          test_case "tool_policy_of_cascade_capabilities None is conservative"
            `Quick
            test_tool_policy_of_cascade_capabilities_none_is_conservative;
          test_case "tool_policy_of_cascade_capabilities Some maps subset"
            `Quick test_tool_policy_of_cascade_capabilities_some_maps_subset;
          test_case "tool_policy_of_cascade_capabilities default matches None"
            `Quick
            test_tool_policy_of_cascade_capabilities_default_matches_none;
        ] );
      ( "local_provider",
        [
          test_case "requires_discovery llama" `Quick
            test_requires_discovery_llama;
          test_case "requires_discovery cloud" `Quick
            test_requires_discovery_cloud;
          test_case "is_local_provider llama" `Quick
            test_is_local_provider_llama;
          test_case "is_local_provider custom" `Quick
            test_is_local_provider_custom;
          test_case "is_local_provider cloud" `Quick
            test_is_local_provider_cloud;
          test_case "make_local_label" `Quick test_make_local_label;
          test_case "default_local_fallback_label" `Quick
            test_default_local_fallback_label;
        ] );
      ( "stt",
        [
          test_case "stt request elevenlabs direct" `Quick
            test_stt_request_elevenlabs_direct;
          test_case "stt request openai compat" `Quick
            test_stt_request_openai_compat;
          test_case "stt request mcp rejected" `Quick
            test_stt_request_mcp_rejected;
        ] );
      ( "apply_wire_overlay",
        [
          test_case "rewraps Local->OpenAICompat for custom path" `Quick
            test_apply_wire_overlay_rewraps_openai_compat_local_custom_path;
          test_case "keeps Local on default OpenAI path" `Quick
            test_apply_wire_overlay_keeps_local_when_path_is_default;
          test_case "passthrough for Anthropic kind" `Quick
            test_apply_wire_overlay_passthrough_for_anthropic;
          test_case "blank api_key yields no auth header" `Quick
            test_apply_wire_overlay_omits_auth_header_when_key_blank;
        ] );
    ]
