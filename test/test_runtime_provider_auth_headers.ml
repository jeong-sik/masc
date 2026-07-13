open Alcotest
open Masc

let header_count name headers =
  headers
  |> List.filter (fun (k, _) -> String.equal k name)
  |> List.length

let normalized_header_count name headers =
  let name = String.lowercase_ascii name in
  headers
  |> List.filter (fun (k, _) -> String.equal name (String.lowercase_ascii k))
  |> List.length

let normalized_header_value name headers =
  let name = String.lowercase_ascii name in
  headers
  |> List.find_map (fun (k, v) ->
    if String.equal name (String.lowercase_ascii k) then Some v else None)

let with_env key value f =
  let previous = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some previous -> Unix.putenv key previous
      | None -> Unix.putenv key "")
    f

let runpod_provider =
  { Runtime_schema.id = "runpod_mtp"
  ; display_name = "RunPod"
  ; protocol = "openai-compatible-http"
  ; api_format = Chat_completions_api
  ; transport = Http "https://example-runpod.proxy.runpod.net/v1"
  ; is_non_interactive = true
  ; credentials = Some (Inline "rp-test-token")
  ; capabilities = None
  ; healthcheck_path = None
  ; headers = None
  ; connect_timeout_s = None
  }

let qwen_model =
  { Runtime_schema.id = "qwen"
  ; api_name = "qwen"
  ; tools_support = true
  ; max_context = Some 160000
  ; thinking_support = true
  ; preserve_thinking = Some false
  ; max_thinking_budget = None
  ; streaming = true
  ; temperature = None
  ; top_p = None
  ; top_k = None
  ; min_p = None
  ; capabilities = None
  ; match_prefixes = []
  }

let runpod_binding =
  { Runtime_schema.provider_id = "runpod_mtp"
  ; model_id = "qwen"
  ; is_default = true
  ; wizard_default = false
  ; max_concurrent = None
  ; price_input = None
  ; price_output = None
  ; keep_alive = None
  ; num_ctx = None
  }

let runtime_toml_with_credentials ?(provider_extra = "") ?(model_extra = "") credentials =
  Printf.sprintf
    {|
[runtime]
default = "runpod_mtp.qwen"

[providers.runpod_mtp]
display-name = "RunPod"
protocol = "openai-compatible-http"
endpoint = "https://example-runpod.proxy.runpod.net/v1"

%s

%s

[models.qwen]
api-name = "qwen"
max-context = 160000
tools-support = true
%s

[runpod_mtp.qwen]
is-default = true
max-concurrent = 4
|}
    provider_extra
    credentials
    model_extra

let check_parse_error errors expected_path expected_message =
  let matches =
    List.exists
      (fun (err : Runtime_toml.parse_error) ->
         String.equal err.path expected_path
         && String.equal err.message expected_message)
      errors
  in
  check bool "expected parse error" true matches

let check_parse_error_contains errors expected_path expected_message_fragment =
  let matches =
    List.exists
      (fun (err : Runtime_toml.parse_error) ->
         String.equal err.path expected_path
         && String_util.contains_substring err.message expected_message_fragment)
      errors
  in
  check bool "expected parse error" true matches

let inline_credentials =
  {|
[providers.runpod_mtp.credentials]
type = "inline"
value = "rp-test-token"
|}

let test_runtime_toml_rejects_blank_env_credential_key () =
  let content =
    runtime_toml_with_credentials
      {|
[providers.runpod_mtp.credentials]
type = "env"
key = ""
|}
  in
  match Runtime_toml.parse_string content with
  | Ok _ -> fail "expected runtime TOML credential parse error"
  | Error errors ->
    check_parse_error
      errors
      "providers.runpod_mtp.credentials.key"
      "credential type 'env' requires non-empty 'key'"

let test_runtime_toml_threads_provider_connect_timeout () =
  let content =
    runtime_toml_with_credentials
      ~provider_extra:(Runtime_schema.connect_timeout_s_key ^ " = 123.5")
      inline_credentials
  in
  match Runtime_toml.parse_string content with
  | Error errors ->
    failf
      "expected runtime TOML connect-timeout-s to parse: %s"
      (String.concat
         "; "
         (List.map
            (fun (err : Runtime_toml.parse_error) ->
               Printf.sprintf "%s: %s" err.path err.message)
            errors))
  | Ok cfg ->
    (match cfg.providers, cfg.bindings with
     | [ provider ], [ binding ] ->
       check (option (float 0.0)) "provider connect timeout" (Some 123.5)
         provider.Runtime_schema.connect_timeout_s;
       (match Runtime_adapter.binding_to_provider_config cfg binding with
        | Error msg -> failf "unexpected adapter error: %s" msg
        | Ok provider_cfg ->
          check (option (float 0.0)) "provider config connect timeout"
            (Some 123.5) provider_cfg.connect_timeout_s)
     | providers, bindings ->
       failf "expected one provider/binding, got %d/%d"
         (List.length providers)
         (List.length bindings))

let test_runtime_toml_threads_model_sampling_config () =
  let content =
    runtime_toml_with_credentials
      ~model_extra:{|top-p = 0.91
top-k = 42
min-p = 0.07
|}
      inline_credentials
  in
  match Runtime_toml.parse_string content with
  | Error errors ->
    failf
      "expected runtime TOML model sampling config to parse: %s"
      (String.concat
         "; "
         (List.map
            (fun (err : Runtime_toml.parse_error) ->
               Printf.sprintf "%s: %s" err.path err.message)
            errors))
  | Ok cfg ->
    (match cfg.models, cfg.bindings with
     | [ model ], [ binding ] ->
       check (option (float 0.0001)) "model top_p" (Some 0.91)
         model.Runtime_schema.top_p;
       check (option int) "model top_k" (Some 42) model.Runtime_schema.top_k;
       check (option (float 0.0001)) "model min_p" (Some 0.07)
         model.Runtime_schema.min_p;
       (match Runtime_adapter.binding_to_provider_config cfg binding with
        | Error msg -> failf "unexpected adapter error: %s" msg
        | Ok provider_cfg ->
          check (option (float 0.0001)) "provider config top_p" (Some 0.91)
            provider_cfg.top_p;
          check (option int) "provider config top_k" (Some 42)
            provider_cfg.top_k;
          check (option (float 0.0001)) "provider config min_p" (Some 0.07)
            provider_cfg.min_p)
     | models, bindings ->
       failf "expected one model/binding, got %d/%d"
         (List.length models)
         (List.length bindings))

let test_runtime_toml_rejects_non_positive_provider_connect_timeout () =
  let content =
    runtime_toml_with_credentials
      ~provider_extra:(Runtime_schema.connect_timeout_s_key ^ " = 0.0")
      inline_credentials
  in
  match Runtime_toml.parse_string content with
  | Ok _ -> fail "expected runtime TOML connect-timeout-s parse error"
  | Error errors ->
    check_parse_error_contains
      errors
      "providers.runpod_mtp.connect-timeout-s"
      "positive finite float"

let test_runtime_toml_rejects_wrong_typed_provider_connect_timeout () =
  let content =
    runtime_toml_with_credentials
      ~provider_extra:(Runtime_schema.connect_timeout_s_key ^ " = \"600\"")
      inline_credentials
  in
  match Runtime_toml.parse_string content with
  | Ok _ -> fail "expected runtime TOML connect-timeout-s type error"
  | Error errors ->
    check_parse_error_contains
      errors
      "providers.runpod_mtp.connect-timeout-s"
      (Runtime_schema.connect_timeout_s_key ^ " must be a float")

let test_runtime_toml_rejects_missing_env_credential_key () =
  let content =
    runtime_toml_with_credentials
      {|
[providers.runpod_mtp.credentials]
type = "env"
|}
  in
  match Runtime_toml.parse_string content with
  | Ok _ -> fail "expected runtime TOML credential parse error"
  | Error errors ->
    check_parse_error
      errors
      "providers.runpod_mtp.credentials.key"
      "credential type 'env' requires non-empty 'key'"

let test_runtime_toml_trims_env_credential_key () =
  let content =
    runtime_toml_with_credentials
      {|
[providers.runpod_mtp.credentials]
type = "env"
key = " OLLAMA_CLOUD_API_KEY "
|}
  in
  match Runtime_toml.parse_string content with
  | Error _ -> fail "expected runtime TOML to parse"
  | Ok config ->
    (match config.providers with
     | [ provider ] ->
       (match provider.credentials with
        | Some (Runtime_schema.Env key) ->
          check string "trimmed env key" "OLLAMA_CLOUD_API_KEY" key
        | Some _ -> fail "expected env credential"
        | None -> fail "expected credential")
     | _ -> fail "expected one provider")

let test_runtime_toml_rejects_legacy_protocol_aliases () =
  let content =
    {|
[runtime]
default = "legacy_openai_compat.test_model"

[providers.legacy_openai_compat]
display-name = "Legacy OpenAI-Compatible"
protocol = "openai-http"
endpoint = "https://legacy-openai-compatible.example/v1"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[legacy_openai_compat.test_model]
max-concurrent = 1
|}
  in
  match Runtime_toml.parse_string content with
  | Ok _ -> fail "expected runtime TOML to reject legacy provider-letter alias"
  | Error errors ->
    check bool "rejects openai-http"
      true
      (List.exists
         (fun (err : Runtime_toml.parse_error) ->
            String.equal err.path "providers.legacy_openai_compat.protocol"
            && String.equal err.message
                 "unknown protocol \"openai-http\": expected one of \
                  messages-cli, messages-http, openai-compatible-cli, \
                  openai-compatible-http, ollama-http")
         errors)

let test_runtime_toml_accepts_messages_caching_capability () =
  let content =
    {|
[runtime]
default = "anthropic.claude-opus-4"

[providers.anthropic]
display-name = "Anthropic"
protocol = "messages-http"
endpoint = "https://api.anthropic.com"

[providers.anthropic.capabilities]
uses-messages-caching = true

[models.claude-opus-4]
api-name = "claude-opus-4"
max-context = 200000
tools-support = true
streaming = true

[anthropic.claude-opus-4]
max-concurrent = 2
|}
  in
  match Runtime_toml.parse_string content with
  | Error errors ->
    fail
      (errors
       |> List.map (fun (err : Runtime_toml.parse_error) ->
         err.path ^ ": " ^ err.message)
       |> String.concat "; ")
  | Ok config ->
    (match config.providers with
     | [ provider ] ->
       (match provider.Runtime_schema.capabilities with
        | Some caps ->
          check bool "uses_anthropic_caching from uses-messages-caching" true
            caps.uses_anthropic_caching
        | None -> fail "expected provider capabilities")
     | _ -> fail "expected one provider")

let kimi_runtime_toml =
  {|
[runtime]
default = "kimi.kimi-for-coding"

[providers.kimi]
display-name = "Kimi Code Plan"
protocol = "messages-http"
endpoint = "https://example.invalid/kimi"

[providers.kimi.credentials]
type = "inline"
value = "test-kimi-key"

[models.kimi-for-coding]
api-name = "kimi-for-coding"
max-context = 256000
tools-support = true
streaming = true

[kimi.kimi-for-coding]
|}

let kimi_runtime_config_or_fail () =
  match Runtime_toml.parse_string kimi_runtime_toml with
  | Ok cfg -> cfg
  | Error errors ->
    failf
      "expected Kimi runtime TOML to parse: %s"
      (String.concat
         "; "
         (List.map
            (fun (err : Runtime_toml.parse_error) ->
               Printf.sprintf "%s: %s" err.path err.message)
            errors))

let test_runtime_adapter_materializes_kimi_messages_http () =
  let cfg = kimi_runtime_config_or_fail () in
  match cfg.bindings with
  | [ binding ] ->
    (match Runtime_adapter.binding_to_provider_config cfg binding with
     | Error msg -> failf "unexpected Kimi messages-http adapter error: %s" msg
     | Ok provider_cfg ->
       check string "base url" "https://example.invalid/kimi" provider_cfg.base_url;
       check string "request path" "/v1/messages" provider_cfg.request_path;
       check
         string
         "api key"
         "test-kimi-key"
         (Llm_provider.Secret.header_value provider_cfg.api_key);
       (match provider_cfg.kind with
        | Llm_provider.Provider_config.Kimi -> ()
        | other ->
          failf
            "expected Kimi provider kind, got %s"
            (Llm_provider.Provider_config.string_of_provider_kind other)))
  | bindings -> failf "expected one Kimi binding, got %d" (List.length bindings)

let unregistered_messages_http_toml =
  {|
[runtime]
default = "local.model"

[providers.local]
display-name = "Local Messages API"
protocol = "messages-http"
endpoint = "https://example.invalid/messages"

[models.model]
api-name = "model"
max-context = 8192
tools-support = true
streaming = true

[local.model]
|}

let incompatible_messages_http_toml =
  {|
[runtime]
default = "deepseek.model"

[providers.deepseek]
display-name = "DeepSeek over wrong protocol"
protocol = "messages-http"
endpoint = "https://api.deepseek.com/v1/messages"

[models.model]
api-name = "model"
max-context = 8192
tools-support = true
streaming = true

[deepseek.model]
|}

let test_runtime_adapter_rejects_unregistered_messages_http () =
  match Runtime_toml.parse_string unregistered_messages_http_toml with
  | Error errors ->
    failf
      "expected unregistered messages-http runtime TOML to parse: %s"
      (String.concat
         "; "
         (List.map
            (fun (err : Runtime_toml.parse_error) ->
               Printf.sprintf "%s: %s" err.path err.message)
            errors))
  | Ok cfg ->
    (match cfg.bindings with
     | [ binding ] ->
       (match Runtime_adapter.binding_to_provider_config cfg binding with
        | Ok provider_cfg ->
          failf
            "unregistered messages-http provider must fail closed, got kind %s"
            (Llm_provider.Provider_config.string_of_provider_kind provider_cfg.kind)
        | Error _ -> ())
     | bindings -> failf "expected one local binding, got %d" (List.length bindings))

let test_runtime_adapter_rejects_incompatible_messages_http_kind () =
  match Runtime_toml.parse_string incompatible_messages_http_toml with
  | Error errors ->
    failf
      "expected incompatible messages-http runtime TOML to parse: %s"
      (String.concat
         "; "
         (List.map
            (fun (err : Runtime_toml.parse_error) ->
               Printf.sprintf "%s: %s" err.path err.message)
            errors))
  | Ok cfg ->
    (match cfg.bindings with
     | [ binding ] ->
       (match Runtime_adapter.binding_to_provider_config cfg binding with
        | Ok provider_cfg ->
          failf
            "incompatible messages-http provider must fail closed, got kind %s"
            (Llm_provider.Provider_config.string_of_provider_kind provider_cfg.kind)
        | Error msg ->
          check
            bool
            "error names messages compatibility policy"
            true
            (String_util.contains_substring msg "messages-compatible");
          check
            bool
            "error names provider"
            true
            (String_util.contains_substring msg "deepseek"))
     | bindings -> failf "expected one DeepSeek binding, got %d" (List.length bindings))

let deepseek_runtime_toml =
  {|
[runtime]
default = "deepseek.deepseek-v4-pro"

[providers.deepseek]
display-name = "DeepSeek API"
protocol = "openai-compatible-http"
endpoint = "https://api.deepseek.com"

[providers.deepseek.credentials]
type = "env"
key = "DEEPSEEK_API_KEY"

[models.deepseek-v4-pro]
api-name = "deepseek-v4-pro"
max-context = 1000000
tools-support = true
thinking-support = true
streaming = true

[models.deepseek-v4-pro.capabilities]
max-output-tokens = 384000
supports-tool-choice = true
supports-extended-thinking = true
supports-reasoning-budget = true
thinking-control-format = "reasoning-effort"
supports-native-streaming = true
supports-response-format-json = true
supports-structured-output = true

[deepseek.deepseek-v4-pro]
max-concurrent = 2
|}

let deepseek_runtime_config_or_fail () =
  match Runtime_toml.parse_string deepseek_runtime_toml with
  | Ok cfg -> cfg
  | Error errors ->
    failf
      "expected DeepSeek runtime TOML to parse: %s"
      (String.concat
         "; "
         (List.map
            (fun (err : Runtime_toml.parse_error) ->
               Printf.sprintf "%s: %s" err.path err.message)
            errors))

let deepseek_provider_config_or_fail () =
  let cfg = deepseek_runtime_config_or_fail () in
  match cfg.bindings with
  | [ binding ] ->
    (match Runtime_adapter.binding_to_provider_config cfg binding with
     | Ok provider_cfg -> provider_cfg
     | Error msg -> failf "unexpected DeepSeek adapter error: %s" msg)
  | bindings -> failf "expected one DeepSeek binding, got %d" (List.length bindings)

let with_deepseek_env deepseek f = with_env "DEEPSEEK_API_KEY" deepseek f

let glm_coding_runtime_toml =
  {|
[runtime]
default = "glm-coding.glm-4-7-coding"

[providers.glm-coding]
display-name = "GLM Coding Plan"
protocol = "openai-compatible-http"
endpoint = "https://api.z.ai/api/coding/paas/v4"

[providers.glm-coding.credentials]
type = "env"
key = "ZAI_CODING_API_KEY"

[models.glm-4-7-coding]
api-name = "glm-4.7"
max-context = 200000
tools-support = true
thinking-support = true
preserve-thinking = true
streaming = true

[models.glm-4-7-coding.capabilities]
max-output-tokens = 128000
supports-tool-choice = false
supports-extended-thinking = true
supports-native-streaming = true
supports-response-format-json = true
supports-structured-output = false

[glm-coding.glm-4-7-coding]
max-concurrent = 3
|}

let glm_coding_runtime_config_or_fail () =
  match Runtime_toml.parse_string glm_coding_runtime_toml with
  | Ok cfg -> cfg
  | Error errors ->
    failf
      "expected GLM Coding Plan runtime TOML to parse: %s"
      (String.concat
         "; "
         (List.map
            (fun (err : Runtime_toml.parse_error) ->
               Printf.sprintf "%s: %s" err.path err.message)
            errors))

let glm_coding_provider_config_or_fail () =
  let cfg = glm_coding_runtime_config_or_fail () in
  match cfg.bindings with
  | [ binding ] ->
    (match Runtime_adapter.binding_to_provider_config cfg binding with
     | Ok provider_cfg -> provider_cfg
     | Error msg -> failf "unexpected GLM Coding Plan adapter error: %s" msg)
  | bindings ->
    failf "expected one GLM Coding Plan binding, got %d" (List.length bindings)

let with_glm_coding_env general coding f =
  with_env "ZAI_API_KEY" general (fun () -> with_env "ZAI_CODING_API_KEY" coding f)

let test_runtime_toml_accepts_deepseek_reasoning_effort_capability () =
  let cfg = deepseek_runtime_config_or_fail () in
  match cfg.models with
  | [ model ] ->
    (match model.capabilities with
     | Some caps ->
       check bool "reasoning effort parsed" true
         (caps.thinking_control_format = Runtime_schema.Reasoning_effort);
       check (option int) "max output" (Some 384000) caps.max_output_tokens
     | None -> fail "expected model capabilities")
  | models -> failf "expected one model, got %d" (List.length models)

let test_runtime_toml_accepts_chat_template_token_capability () =
  let toml =
    {|
[runtime]
default = "ollama.gemma4"

[providers.ollama]
display-name = "Local Ollama"
protocol = "ollama-http"
endpoint = "http://localhost:11434"

[models.gemma4]
api-name = "hf.co/unsloth/gemma-4-26B-A4B-it-qat-GGUF:UD-Q4_K_XL"
max-context = 262144
tools-support = true
thinking-support = true
streaming = true

[models.gemma4.capabilities]
thinking-control-format = "chat_template_token"
thinking-control-token = "<|think|>"

[ollama.gemma4]
max-concurrent = 1
|}
  in
  match Runtime_toml.parse_string toml with
  | Error errors ->
    failf
      "expected Gemma4 runtime TOML to parse: %s"
      (String.concat
         "; "
         (List.map
            (fun (err : Runtime_toml.parse_error) ->
               Printf.sprintf "%s: %s" err.path err.message)
            errors))
  | Ok cfg ->
    (match cfg.models with
     | [ model ] ->
       (match model.capabilities with
        | Some caps ->
          check bool "chat template token parsed" true
            (caps.thinking_control_format
             = Runtime_schema.Chat_template_token "<|think|>")
        | None -> fail "expected model capabilities")
     | models -> failf "expected one model, got %d" (List.length models))

let test_runtime_adapter_materializes_deepseek_openai_compat () =
  with_deepseek_env "ds-test-key" (fun () ->
    let provider_cfg = deepseek_provider_config_or_fail () in
    check bool "kind" true
      (provider_cfg.kind = Llm_provider.Provider_config.OpenAI_compat);
    check string "base_url" "https://api.deepseek.com" provider_cfg.base_url;
    check string "request_path" "/chat/completions" provider_cfg.request_path;
    check string "model_id" "deepseek-v4-pro" provider_cfg.model_id;
    check string "api key" "ds-test-key" (Llm_provider.Secret.header_value provider_cfg.api_key);
    check (option int) "max_context" (Some 1000000) provider_cfg.max_context;
    check (option int) "max_tokens is not synthesized from capability" None
      provider_cfg.max_tokens;
    check int "Authorization header count" 0
      (normalized_header_count "Authorization" provider_cfg.headers))

let test_runtime_adapter_max_tokens_wire_omission_and_explicit_override () =
  with_deepseek_env "ds-test-key" (fun () ->
    let provider_cfg = deepseek_provider_config_or_fail () in
    let body =
      Llm_provider.Backend_openai.build_request_assoc
        ~config:provider_cfg
        ~messages:[]
        ()
    in
    (match body with
     | `Assoc fields ->
       check bool "catalog capability does not become a wire max_tokens field"
         false
         (List.mem_assoc "max_tokens" fields)
     | _ -> fail "expected OpenAI request object");
    let explicit_cfg =
      { provider_cfg with Llm_provider.Provider_config.max_tokens = Some 2048 }
    in
    let explicit_body =
      Llm_provider.Backend_openai.build_request_assoc
        ~config:explicit_cfg
        ~messages:[]
        ()
    in
    match explicit_body with
    | `Assoc fields ->
      check (option (of_pp Yojson.Safe.pp))
        "explicit override reaches wire unchanged"
        (Some (`Int 2048))
        (List.assoc_opt "max_tokens" fields)
    | _ -> fail "expected explicit OpenAI request object")

let test_runtime_toml_accepts_glm_coding_capability () =
  let cfg = glm_coding_runtime_config_or_fail () in
  match cfg.models with
  | [ model ] ->
    check bool "thinking enabled" true model.thinking_support;
    check (option bool) "preserve thinking" (Some true) model.preserve_thinking;
    (match model.capabilities with
     | Some caps ->
       check (option int) "max output" (Some 128000) caps.max_output_tokens;
       check bool "forced tool choice disabled" false caps.supports_tool_choice;
       check bool "extended thinking" true caps.supports_extended_thinking
     | None -> fail "expected model capabilities")
  | models -> failf "expected one model, got %d" (List.length models)

let test_runtime_adapter_materializes_glm_coding_provider () =
  with_glm_coding_env "general-key" "coding-key" (fun () ->
    let provider_cfg = glm_coding_provider_config_or_fail () in
    check bool "kind" true
      (provider_cfg.kind = Llm_provider.Provider_config.Glm);
    check string "base_url" "https://api.z.ai/api/coding/paas/v4"
      provider_cfg.base_url;
    check string "request_path" "/chat/completions" provider_cfg.request_path;
    check string "model_id" "glm-4.7" provider_cfg.model_id;
    check string "api key uses coding lane" "coding-key" (Llm_provider.Secret.header_value provider_cfg.api_key);
    check (option int) "max_context" (Some 200000) provider_cfg.max_context;
    check (option int) "max_tokens is not synthesized from capability" None
      provider_cfg.max_tokens;
    check (option bool) "tool choice override" (Some false)
      provider_cfg.supports_tool_choice_override;
    check int "Authorization header count" 0
      (normalized_header_count "Authorization" provider_cfg.headers))

let test_runtime_adapter_keeps_auth_out_of_headers () =
  let cfg =
    { Runtime_schema.providers = [ runpod_provider ]
    ; models = [ qwen_model ]
    ; bindings = [ runpod_binding ]
    ; default_runtime_id = Some "runpod_mtp.qwen"
    ; librarian_runtime_id = None
    ; structured_judge_runtime_id = None
    ; hitl_summary_runtime_id = None
    ; cross_verifier_runtime_id = None
    ; keeper_assignments = []
    ; media_failover = []
    ; lane_decls = []
    }
  in
  match Runtime_adapter.binding_to_provider_config cfg runpod_binding with
  | Error msg -> failf "unexpected adapter error: %s" msg
  | Ok provider_cfg ->
    check string "api key" "rp-test-token" (Llm_provider.Secret.header_value provider_cfg.api_key);
    check int "Authorization header count" 0
      (header_count "Authorization" provider_cfg.headers);
    check int "Content-Type header count" 1
      (header_count "Content-Type" provider_cfg.headers)

let test_runtime_adapter_filters_toml_auth_headers () =
  let provider =
    { runpod_provider with
      headers =
        Some
          [ "Authorization", "Bearer from-toml"
          ; "X-API-Key", "from-toml"
          ; "Content-Type", "application/custom+json"
          ; "X-Trace-Id", "trace-1"
          ]
    }
  in
  let cfg =
    { Runtime_schema.providers = [ provider ]
    ; models = [ qwen_model ]
    ; bindings = [ runpod_binding ]
    ; default_runtime_id = Some "runpod_mtp.qwen"
    ; librarian_runtime_id = None
    ; structured_judge_runtime_id = None
    ; hitl_summary_runtime_id = None
    ; cross_verifier_runtime_id = None
    ; keeper_assignments = []
    ; media_failover = []
    ; lane_decls = []
    }
  in
  match Runtime_adapter.binding_to_provider_config cfg runpod_binding with
  | Error msg -> failf "unexpected adapter error: %s" msg
  | Ok provider_cfg ->
    check string "api key" "rp-test-token" (Llm_provider.Secret.header_value provider_cfg.api_key);
    check int "Authorization header count" 0
      (normalized_header_count "Authorization" provider_cfg.headers);
    check int "x-api-key header count" 0
      (normalized_header_count "x-api-key" provider_cfg.headers);
    check int "Content-Type header count" 1
      (normalized_header_count "Content-Type" provider_cfg.headers);
    check
      (option string)
      "Content-Type override"
      (Some "application/custom+json")
      (normalized_header_value "Content-Type" provider_cfg.headers);
    check
      (option string)
      "non-auth custom header"
      (Some "trace-1")
      (normalized_header_value "X-Trace-Id" provider_cfg.headers)

let provider_cfg () =
  let cfg =
    { Runtime_schema.providers = [ runpod_provider ]
    ; models = [ qwen_model ]
    ; bindings = [ runpod_binding ]
    ; default_runtime_id = Some "runpod_mtp.qwen"
    ; librarian_runtime_id = None
    ; structured_judge_runtime_id = None
    ; hitl_summary_runtime_id = None
    ; cross_verifier_runtime_id = None
    ; keeper_assignments = []
    ; media_failover = []
    ; lane_decls = []
    }
  in
  match Runtime_adapter.binding_to_provider_config cfg runpod_binding with
  | Ok provider_cfg -> provider_cfg
  | Error msg -> failf "unexpected adapter error: %s" msg

(* Audit F2: TOML keep-alive / num-ctx must reach the wire-level
   Provider_config. Before the fix the adapter dropped both binding
   fields, so keep_alive fell back to OAS_OLLAMA_KEEP_ALIVE / "-1" and
   num_ctx to the Ollama Modelfile default. *)
let ollama_keep_alive_runtime_toml =
  {|
[runtime]
default = "ollama.qwen-local"

[providers.ollama]
display-name = "Local Ollama"
protocol = "ollama-http"
endpoint = "http://localhost:11434"

[models.qwen-local]
api-name = "qwen3:32b"
max-context = 32768
tools-support = true
streaming = true

[ollama.qwen-local]
max-concurrent = 1
keep-alive = "30m"
num-ctx = 16384
|}

let test_runtime_adapter_threads_binding_keep_alive_and_num_ctx () =
  match Runtime_toml.parse_string ollama_keep_alive_runtime_toml with
  | Error errors ->
    failf
      "expected Ollama keep-alive runtime TOML to parse: %s"
      (String.concat
         "; "
         (List.map
            (fun (err : Runtime_toml.parse_error) ->
               Printf.sprintf "%s: %s" err.path err.message)
            errors))
  | Ok cfg ->
    (match cfg.bindings with
     | [ binding ] ->
       check (option string) "binding keep_alive parsed" (Some "30m")
         binding.Runtime_schema.keep_alive;
       check (option int) "binding num_ctx parsed" (Some 16384)
         binding.Runtime_schema.num_ctx;
       (match Runtime_adapter.binding_to_provider_config cfg binding with
        | Error msg -> failf "unexpected adapter error: %s" msg
        | Ok provider_cfg ->
          check bool "kind" true
            (provider_cfg.kind = Llm_provider.Provider_config.Ollama);
          check (option string) "provider config keep_alive" (Some "30m")
            provider_cfg.keep_alive;
          check (option int) "provider config num_ctx" (Some 16384)
            provider_cfg.num_ctx)
     | bindings -> failf "expected one binding, got %d" (List.length bindings))

let test_runtime_adapter_leaves_keep_alive_and_num_ctx_unset_by_default () =
  let provider_cfg = provider_cfg () in
  check (option string) "keep_alive unset without TOML value" None
    provider_cfg.keep_alive;
  check (option int) "num_ctx unset without TOML value" None
    provider_cfg.num_ctx

let runtime_or_fail ?(provider = runpod_provider) () =
  let cfg =
    { Runtime_schema.providers = [ provider ]
    ; models = [ qwen_model ]
    ; bindings = [ runpod_binding ]
    ; default_runtime_id = Some "runpod_mtp.qwen"
    ; librarian_runtime_id = None
    ; structured_judge_runtime_id = None
    ; hitl_summary_runtime_id = None
    ; cross_verifier_runtime_id = None
    ; keeper_assignments = []
    ; media_failover = []
    ; lane_decls = []
    }
  in
  match Runtime.of_binding cfg runpod_binding with
  | Some runtime -> runtime
  | None -> fail "expected runtime binding to materialize"

let with_dashboard_probe_http_get hook f =
  Server_dashboard_http_runtime_info.set_dashboard_runtime_provider_http_get_for_tests
    hook;
  Fun.protect
    ~finally:(fun () ->
      Server_dashboard_http_runtime_info.clear_dashboard_runtime_provider_http_get_for_tests ())
    f

let first_provider_probe json =
  match Yojson.Safe.Util.(member "providers" json |> to_list) with
  | provider :: _ -> provider
  | [] -> fail "expected at least one provider probe"

let dashboard_probe_missing_auth_calls = ref 0

let assert_dashboard_runtime_probe_reachable runtime =
  let reachable_json =
    with_dashboard_probe_http_get
      (fun ~url ~headers ~timeout_sec:_ ->
         check string "models probe URL"
           "https://example-runpod.proxy.runpod.net/v1/models"
           url;
         check bool "auth header present" true
           (Option.is_some (normalized_header_value "authorization" headers));
         check bool "auth header is bearer" true
           (match normalized_header_value "authorization" headers with
            | Some value -> String.starts_with ~prefix:"Bearer " value
            | None -> false);
         Ok
           ( 200
           , [ "content-type", "application/json" ]
           , {|{"data":[{"id":"qwen"}]}|} ))
      (fun () ->
         Server_dashboard_http_runtime_info.dashboard_runtime_probe_payload_json_for_tests
           ~default_id:"runpod_mtp.qwen" [ runtime ])
  in
  let reachable_provider = first_provider_probe reachable_json in
  check string "provider status" "reachable"
    Yojson.Safe.Util.(member "status" reachable_provider |> to_string);
  check int "http status" 200
    Yojson.Safe.Util.(member "http_status" reachable_provider |> to_int);
  check int "model count" 1
    Yojson.Safe.Util.(member "model_count" reachable_provider |> to_int);
  let () =
    check bool "payload redacts inline token" false
      (String_util.contains_substring
         (Yojson.Safe.to_string reachable_json)
         "rp-test-token")
  in
  ()

let assert_dashboard_runtime_probe_missing_auth runtime =
  dashboard_probe_missing_auth_calls := 0;
  Server_dashboard_http_runtime_info.set_dashboard_runtime_provider_http_get_for_tests
    (fun ~url:_ ~headers:_ ~timeout_sec:_ ->
       incr dashboard_probe_missing_auth_calls;
       Ok (200, [], {|{"data":[]}|}));
  let json =
    Fun.protect
      ~finally:(fun () ->
        Server_dashboard_http_runtime_info.clear_dashboard_runtime_provider_http_get_for_tests ())
      (fun () ->
         Server_dashboard_http_runtime_info.dashboard_runtime_probe_payload_json_for_tests
           ~default_id:"runpod_mtp.qwen" [ runtime ])
  in
  let provider = first_provider_probe json in
  check int "missing auth does not execute HTTP" 0
    !dashboard_probe_missing_auth_calls;
  check string "provider status" "missing_auth"
    (Yojson.Safe.Util.(member "status" provider |> to_string));
  check bool "provider not reachable" false
    (Yojson.Safe.Util.(member "reachable" provider |> to_bool));
  let () =
    check bool "probe not ok" false
      (Yojson.Safe.Util.(member "probe_ok" json |> to_bool))
  in
  ()

let assert_dashboard_runtime_probe_redacts_url_credentials () =
  let provider =
    { runpod_provider with
      transport =
        Runtime_schema.Http
          "https://user:secret@example-runpod.proxy.runpod.net/v1?token=secret#frag"
    }
  in
  let runtime = runtime_or_fail ~provider () in
  let json =
    with_dashboard_probe_http_get
      (fun ~url:_ ~headers:_ ~timeout_sec:_ -> Ok (200, [], {|{"data":[]}|}))
      (fun () ->
         Server_dashboard_http_runtime_info.dashboard_runtime_probe_payload_json_for_tests
           ~default_id:"runpod_mtp.qwen" [ runtime ])
  in
  let provider = first_provider_probe json in
  check bool "payload redacts URL secrets" false
    (String_util.contains_substring (Yojson.Safe.to_string provider) "secret");
  check string "redacted endpoint URL"
    "https://example-runpod.proxy.runpod.net/v1"
    (Yojson.Safe.Util.(member "endpoint_url" provider |> to_string))

let test_dashboard_runtime_probe_reachability_contracts () =
  let runtime = runtime_or_fail () in
  assert_dashboard_runtime_probe_reachable runtime;
  assert_dashboard_runtime_probe_redacts_url_credentials ();
  let env_key = "MASC_TEST_RUNTIME_PROBE_TOKEN_MISSING_6F4C1D7A" in
  Unix.putenv env_key "";
  let provider =
    { runpod_provider with credentials = Some (Runtime_schema.Env env_key) }
  in
  let runtime = runtime_or_fail ~provider () in
  assert_dashboard_runtime_probe_missing_auth runtime

let test_runtime_agent_terminal_observation_uses_runtime_identity () =
  let config =
    Runtime_agent.default_config
      ~name:"oas-runpod_mtp.qwen"
      ~provider_cfg:(provider_cfg ())
      ~system_prompt:""
      ~tools:[]
  in
  let config =
    { config with description = Some "runtime:runpod_mtp.qwen/runtime" }
  in
  let observation =
    Runtime_agent.For_testing.runtime_observation_for_completed_config
      ~total_duration_ms:42.9
      config
  in
  check string "runtime id" "runpod_mtp.qwen" observation.runtime_id;
  check (option string) "selected model" (Some "qwen")
    observation.selected_model;
  check int "attempt count" 1 (List.length observation.attempts);
  check string "attempt detail source" "runtime_agent_terminal"
    observation.attempt_details_source

let test_runtime_agent_terminal_error_observation_marks_failed_attempt () =
  let config =
    Runtime_agent.default_config
      ~name:"oas-runpod_mtp.qwen"
      ~provider_cfg:(provider_cfg ())
      ~system_prompt:""
      ~tools:[]
  in
  let config =
    { config with description = Some "runtime:runpod_mtp.qwen/runtime" }
  in
  let error = "Not found: OpenAI-compatible endpoint returned 404" in
  let observation =
    Runtime_agent.For_testing.runtime_observation_for_terminal_config
      ~total_duration_ms:31.2
      ~error
      config
  in
  check string "runtime id" "runpod_mtp.qwen" observation.runtime_id;
  check (option string) "selected model" (Some "qwen")
    observation.selected_model;
  check int "attempt count" 1 (List.length observation.attempts);
  check string "attempt detail source" "runtime_agent_terminal_error"
    observation.attempt_details_source;
  (match observation.attempts with
   | [ attempt ] ->
     check (option string) "attempt error" (Some error) attempt.error
   | _ -> fail "expected one terminal attempt");
  check string "runtime outcome" "failed"
    (Keeper_execution_receipt.runtime_outcome_to_string
       (Keeper_agent_error.runtime_outcome_of_observation
          (Some observation)))

let test_runtime_agent_max_turns_is_continuation_checkpoint () =
  let lifecycle =
    Runtime_agent.worker_lifecycle_classification_of_result
      (Error
         (Agent_sdk.Error.Agent
            (Agent_sdk.Error.MaxTurnsExceeded { turns = 24; limit = 24 })))
  in
  check string "event" "completed" lifecycle.event;
  check string "status" "continuation_checkpoint" lifecycle.status;
  check (option string) "no error" None lifecycle.error

let test_runtime_agent_recovery_defer_is_control_checkpoint () =
  let lifecycle =
    Runtime_agent.worker_lifecycle_classification_of_result
      (Error
         (Agent_sdk.Error.Agent
            (Agent_sdk.Error.ToolFailureRecoveryDeferred
               { reason = "wait for repository state"
               ; tool_names = [ "Execute" ]
               })))
  in
  check string "event" "completed" lifecycle.event;
  check string "status" "tool_failure_recovery_deferred" lifecycle.status;
  check (option string) "no provider error" None lifecycle.error

let test_runtime_agent_context_uses_configured_turn_budget () =
  let config =
    Runtime_agent.default_config
      ~name:"oas-runpod_mtp.qwen"
      ~provider_cfg:(provider_cfg ())
      ~system_prompt:""
      ~tools:[]
  in
  let config = { config with max_turns = 7 } in
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let builder =
        Runtime_agent_context.builder_without_approval
          ~net:(Eio.Stdenv.net env)
          ~config
          ()
      in
      match Agent_sdk.Builder.build_safe builder with
      | Error err -> fail (Agent_sdk.Error.to_string err)
      | Ok agent ->
        check int "builder max_turns" 7
          (Agent_sdk.Agent.state agent).config.max_turns;
        Eio.Switch.on_release sw (fun () ->
          Agent_sdk.Agent.close agent)));
  let checkpoint =
    { Agent_sdk.Checkpoint.version = Agent_sdk.Checkpoint.checkpoint_version
    ; session_id = "session"
    ; agent_name = "oas-runpod_mtp.qwen"
    ; model = "qwen"
    ; system_prompt = Some ""
    ; messages = []
    ; usage = Agent_sdk.Types.empty_usage
    ; turn_count = 24
    ; created_at = 0.0
    ; tools = []
    ; tool_choice = None
    ; disable_parallel_tool_use = false
    ; temperature = Some 0.3
    ; top_p = None
    ; top_k = None
    ; min_p = None
    ; enable_thinking = None
    ; preserve_thinking = None
    ; response_format = Agent_sdk.Types.default_config.response_format
    ; thinking_budget = None
    ; cache_system_prompt = false
    ; context = Agent_sdk.Context.create_sync ()
    ; mcp_sessions = []
    ; working_context = None
    }
  in
  let prepared = Runtime_agent_context.prepare_resume ~config ~checkpoint in
  check int "resume adds fresh per-call turn budget" 31
    prepared.agent_config.max_turns

let test_runtime_agent_context_preserves_max_tokens_intent () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let check_builder_max_tokens expected max_tokens =
        let config =
          Runtime_agent.default_config
            ~name:"oas-runpod_mtp.qwen"
            ~provider_cfg:(provider_cfg ())
            ~system_prompt:""
            ~tools:[]
        in
        let config = { config with max_tokens } in
        let builder =
          Runtime_agent_context.builder_without_approval
            ~net:(Eio.Stdenv.net env)
            ~config
            ()
        in
        match Agent_sdk.Builder.build_safe builder with
        | Error err -> fail (Agent_sdk.Error.to_string err)
        | Ok agent ->
          check (option int) "builder max_tokens intent" expected
            (Agent_sdk.Agent.state agent).config.max_tokens;
          Eio.Switch.on_release sw (fun () -> Agent_sdk.Agent.close agent)
      in
      check_builder_max_tokens None None;
      check_builder_max_tokens (Some 2048) (Some 2048)))

let test_runtime_agent_lifecycle_attrs_preserve_max_tokens_intent () =
  let config =
    Runtime_agent.default_config
      ~name:"oas-runpod_mtp.qwen"
      ~provider_cfg:(provider_cfg ())
      ~system_prompt:""
      ~tools:[]
  in
  let fields = Runtime_agent.Lifecycle_for_testing.provider_attrs config in
  check (option (of_pp Yojson.Safe.pp)) "omitted lifecycle value"
    (Some `Null)
    (List.assoc_opt "max_tokens" fields);
  check (option string) "omitted lifecycle source"
    (Some "omitted")
    (Option.bind
       (List.assoc_opt "max_tokens_source" fields)
       Yojson.Safe.Util.to_string_option);
  let explicit_fields =
    Runtime_agent.Lifecycle_for_testing.provider_attrs
      { config with max_tokens = Some 2048 }
  in
  check (option (of_pp Yojson.Safe.pp)) "explicit lifecycle value"
    (Some (`Int 2048))
    (List.assoc_opt "max_tokens" explicit_fields);
  check (option string) "explicit lifecycle source"
    (Some "explicit_override")
    (Option.bind
       (List.assoc_opt "max_tokens_source" explicit_fields)
       Yojson.Safe.Util.to_string_option)

let test_runtime_agent_context_preserves_provider_sampling_config () =
  let provider_cfg =
    { (provider_cfg ()) with
      Llm_provider.Provider_config.top_p = Some 0.91
    ; top_k = Some 42
    ; min_p = Some 0.07
    }
  in
  let config =
    Runtime_agent.default_config
      ~name:"oas-runpod_mtp.qwen"
      ~provider_cfg
      ~system_prompt:""
      ~tools:[]
  in
  check (option (float 0.0001)) "config top_p" (Some 0.91) config.top_p;
  check (option int) "config top_k" (Some 42) config.top_k;
  check (option (float 0.0001)) "config min_p" (Some 0.07) config.min_p;
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let builder =
        Runtime_agent_context.builder_without_approval
          ~net:(Eio.Stdenv.net env)
          ~config
          ()
      in
      match Agent_sdk.Builder.build_safe builder with
      | Error err -> fail (Agent_sdk.Error.to_string err)
      | Ok agent ->
        let agent_config = (Agent_sdk.Agent.state agent).config in
        check (option (float 0.0001)) "builder top_p" (Some 0.91)
          agent_config.top_p;
        check (option int) "builder top_k" (Some 42) agent_config.top_k;
        check (option (float 0.0001)) "builder min_p" (Some 0.07)
          agent_config.min_p;
        Eio.Switch.on_release sw (fun () ->
          Agent_sdk.Agent.close agent)));
  let checkpoint =
    { Agent_sdk.Checkpoint.version = Agent_sdk.Checkpoint.checkpoint_version
    ; session_id = "session"
    ; agent_name = "oas-runpod_mtp.qwen"
    ; model = "qwen"
    ; system_prompt = Some ""
    ; messages = []
    ; usage = Agent_sdk.Types.empty_usage
    ; turn_count = 3
    ; created_at = 0.0
    ; tools = []
    ; tool_choice = None
    ; disable_parallel_tool_use = false
    ; temperature = Some 0.3
    ; top_p = Some 0.12
    ; top_k = Some 7
    ; min_p = Some 0.02
    ; enable_thinking = None
    ; preserve_thinking = None
    ; response_format = Agent_sdk.Types.default_config.response_format
    ; thinking_budget = None
    ; cache_system_prompt = false
    ; context = Agent_sdk.Context.create_sync ()
    ; mcp_sessions = []
    ; working_context = None
    }
  in
  let prepared = Runtime_agent_context.prepare_resume ~config ~checkpoint in
  check (option (float 0.0001)) "resume checkpoint top_p" (Some 0.91)
    prepared.patched_checkpoint.top_p;
  check (option int) "resume checkpoint top_k" (Some 42)
    prepared.patched_checkpoint.top_k;
  check (option (float 0.0001)) "resume checkpoint min_p" (Some 0.07)
    prepared.patched_checkpoint.min_p;
  check (option (float 0.0001)) "resume agent top_p" (Some 0.91)
    prepared.agent_config.top_p;
  check (option int) "resume agent top_k" (Some 42)
    prepared.agent_config.top_k;
  check (option (float 0.0001)) "resume agent min_p" (Some 0.07)
    prepared.agent_config.min_p

let test_runtime_agent_context_preserves_unbounded_resume_budget () =
  let config =
    Runtime_agent.default_config
      ~name:"oas-runpod_mtp.qwen"
      ~provider_cfg:(provider_cfg ())
      ~system_prompt:""
      ~tools:[]
  in
  let config = { config with max_turns = 0 } in
  let checkpoint =
    { Agent_sdk.Checkpoint.version = Agent_sdk.Checkpoint.checkpoint_version
    ; session_id = "session"
    ; agent_name = "oas-runpod_mtp.qwen"
    ; model = "qwen"
    ; system_prompt = Some ""
    ; messages = []
    ; usage = Agent_sdk.Types.empty_usage
    ; turn_count = 24
    ; created_at = 0.0
    ; tools = []
    ; tool_choice = None
    ; disable_parallel_tool_use = false
    ; temperature = Some 0.3
    ; top_p = None
    ; top_k = None
    ; min_p = None
    ; enable_thinking = None
    ; preserve_thinking = None
    ; response_format = Agent_sdk.Types.default_config.response_format
    ; thinking_budget = None
    ; cache_system_prompt = false
    ; context = Agent_sdk.Context.create_sync ()
    ; mcp_sessions = []
    ; working_context = None
    }
  in
  let prepared = Runtime_agent_context.prepare_resume ~config ~checkpoint in
  check int "resume preserves unbounded turn budget" 0
    prepared.agent_config.max_turns

let test_runtime_agent_context_resume_patches_stale_response_format_to_base_contract () =
  let resume_schema : Yojson.Safe.t =
    `Assoc
      [ ("type", `String "object")
      ; ("properties", `Assoc [ ("answer", `Assoc [("type", `String "string")]) ])
      ; ("required", `List [ `String "answer" ])
      ]
  in
  let provider_cfg_with_schema =
    let base = provider_cfg () in
    { base with
      Llm_provider.Provider_config.response_format = Agent_sdk.Types.JsonSchema resume_schema
    ; output_schema = Some resume_schema
    }
  in
  let config =
    Runtime_agent.default_config
      ~name:"oas-runpod_mtp.qwen"
      ~provider_cfg:provider_cfg_with_schema
      ~system_prompt:""
      ~tools:[]
  in
  let checkpoint =
    { Agent_sdk.Checkpoint.version = Agent_sdk.Checkpoint.checkpoint_version
    ; session_id = "session"
    ; agent_name = "oas-runpod_mtp.qwen"
    ; model = "qwen"
    ; system_prompt = Some ""
    ; messages = []
    ; usage = Agent_sdk.Types.empty_usage
    ; turn_count = 3
    ; created_at = 0.0
    ; tools = []
    ; tool_choice = None
    ; disable_parallel_tool_use = false
    ; temperature = Some 0.3
    ; top_p = None
    ; top_k = None
    ; min_p = None
    ; enable_thinking = None
    ; preserve_thinking = None
    ; response_format = Agent_sdk.Types.Off
    ; thinking_budget = None
    ; cache_system_prompt = false
    ; context = Agent_sdk.Context.create_sync ()
    ; mcp_sessions = []
    ; working_context = None
    }
  in
  let prepared = Runtime_agent_context.prepare_resume ~config ~checkpoint in
  let expected_response_format =
    provider_cfg_with_schema.Llm_provider.Provider_config.response_format
  in
  check bool "resume patches checkpoint response_format to base JsonSchema" true
    (prepared.patched_checkpoint.Agent_sdk.Checkpoint.response_format
     = expected_response_format)

let test_runtime_agent_context_leaves_tool_choice_unset_with_tools () =
  let tool =
    Agent_sdk.Tool.create
      ~name:"probe_tool"
      ~description:"probe tool"
      ~parameters:[]
      (fun _input -> Ok { content = "ok"; _meta = None })
  in
  let config =
    Runtime_agent.default_config
      ~name:"oas-runpod_mtp.qwen"
      ~provider_cfg:(provider_cfg ())
      ~system_prompt:""
      ~tools:[ tool ]
  in
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let builder =
        Runtime_agent_context.builder_without_approval
          ~net:(Eio.Stdenv.net env)
          ~config
          ()
      in
      match Agent_sdk.Builder.build_safe builder with
      | Error err -> fail (Agent_sdk.Error.to_string err)
      | Ok agent ->
        let agent_config = (Agent_sdk.Agent.state agent).config in
        check
          (option string)
          "tool_choice remains unset"
          None
          (Option.map Agent_sdk.Types.show_tool_choice agent_config.tool_choice);
        Eio.Switch.on_release sw (fun () ->
          Agent_sdk.Agent.close agent)))

(* RFC-OAS-026 §4.6: a configured stream-idle deadline with no resolvable clock
   must fail loudly rather than silently disarm the only I2-legitimate
   streaming timeout. *)
let test_clock_failfast_returns_typed_error_when_idle_set_without_clock () =
  match
    Runtime_agent.For_testing.decide_clock_for_idle
      ~stream_idle_timeout_s:(Some 120.0)
      ~process_clock:(Error "process runtime not initialised")
      ~ctx_clock:None
  with
  | Error (Agent_sdk.Error.Config (Agent_sdk.Error.InvalidConfig { field; detail })) ->
    check string "field" "stream_idle_timeout_s" field;
    check
      bool
      "message identifies the configured idle deadline with no clock"
      true
      (String.starts_with
         ~prefix:"runtime_agent: stream_idle_timeout_s configured"
         detail)
  | Error err ->
    fail
      (Printf.sprintf
         "expected InvalidConfig stream_idle_timeout_s, got %s"
         (Agent_sdk.Error.to_string err))
  | Ok _ -> fail "expected typed error when idle is configured but no clock resolves"

let test_clock_failfast_opt_out_when_no_idle_no_clock () =
  (* Legitimate opt-out: no idle deadline + no clock stays None, no raise. *)
  let clock =
    Runtime_agent.For_testing.decide_clock_for_idle
      ~stream_idle_timeout_s:None
      ~process_clock:(Error "no runtime")
      ~ctx_clock:None
  in
  check bool "no idle + no clock -> None" true
    (match clock with
     | Ok None -> true
     | Ok (Some _) | Error _ -> false)

(* ── Runtime.decide_capability_gate (OAS catalog binding gate) ── *)

let mentions ~sub s =
  let ls = String.length sub and lc = String.length s in
  let rec go i = i + ls <= lc && (String.sub s i ls = sub || go (i + 1)) in
  ls = 0 || go 0

let test_capability_gate_empty () =
  match Runtime.decide_capability_gate ~config_path:"cfg" [] with
  | Ok () -> ()
  | Error msg -> failf "expected Ok for empty bindings, got: %s" msg

let test_capability_gate_all_known () =
  match Runtime.decide_capability_gate ~config_path:"cfg" [ "a", true; "b", true ] with
  | Ok () -> ()
  | Error msg -> failf "expected Ok when all models known, got: %s" msg

let test_capability_gate_partial_unknown_aborts () =
  match
    Runtime.decide_capability_gate
      ~config_path:"cfg"
      [ "known", true; "missing-model", false ]
  with
  | Ok () -> fail "expected Error when a model is missing from a populated catalog"
  | Error msg ->
    check bool "error names the missing model" true (mentions ~sub:"missing-model" msg)

let test_capability_gate_all_unknown_aborts () =
  match Runtime.decide_capability_gate ~config_path:"cfg" [ "a", false; "b", false ] with
  | Ok () -> fail "expected Error when all configured models are missing"
  | Error msg ->
    check bool "error names first missing model" true (mentions ~sub:"a" msg);
    check bool "error names second missing model" true (mentions ~sub:"b" msg)

let () =
  run "runtime_provider_auth_headers"
    [ ( "capability_gate"
      , [ test_case "empty -> ok" `Quick test_capability_gate_empty
        ; test_case "all known -> ok" `Quick test_capability_gate_all_known
        ; test_case
            "partial unknown -> abort"
            `Quick
            test_capability_gate_partial_unknown_aborts
        ; test_case
            "all unknown -> abort"
            `Quick
            test_capability_gate_all_unknown_aborts
        ] )
    ; ( "provider_config"
      , [ test_case
            "runtime adapter carries auth in api_key only"
            `Quick
            test_runtime_adapter_keeps_auth_out_of_headers
        ; test_case
            "runtime adapter filters TOML auth headers"
            `Quick
            test_runtime_adapter_filters_toml_auth_headers
        ; test_case
            "runtime TOML rejects blank env credential key"
            `Quick
            test_runtime_toml_rejects_blank_env_credential_key
        ; test_case
            "runtime TOML rejects missing env credential key"
            `Quick
            test_runtime_toml_rejects_missing_env_credential_key
        ; test_case
            "runtime TOML trims env credential key"
            `Quick
            test_runtime_toml_trims_env_credential_key
        ; test_case
            "runtime TOML threads provider connect timeout"
            `Quick
            test_runtime_toml_threads_provider_connect_timeout
        ; test_case
            "runtime TOML threads model sampling config"
            `Quick
            test_runtime_toml_threads_model_sampling_config
        ; test_case
            "runtime TOML rejects non-positive provider connect timeout"
            `Quick
            test_runtime_toml_rejects_non_positive_provider_connect_timeout
        ; test_case
            "runtime TOML rejects wrong-typed provider connect timeout"
            `Quick
            test_runtime_toml_rejects_wrong_typed_provider_connect_timeout
        ; test_case
            "runtime TOML rejects legacy protocol aliases"
            `Quick
            test_runtime_toml_rejects_legacy_protocol_aliases
        ; test_case
            "runtime TOML reads uses-messages-caching capability"
            `Quick
            test_runtime_toml_accepts_messages_caching_capability
        ; test_case
            "runtime adapter materializes Kimi messages-http provider"
            `Quick
            test_runtime_adapter_materializes_kimi_messages_http
        ; test_case
            "runtime adapter rejects unregistered messages-http provider"
            `Quick
            test_runtime_adapter_rejects_unregistered_messages_http
        ; test_case
            "runtime adapter rejects incompatible messages-http registry kind"
            `Quick
            test_runtime_adapter_rejects_incompatible_messages_http_kind
        ; test_case
            "runtime TOML accepts DeepSeek reasoning effort"
            `Quick
            test_runtime_toml_accepts_deepseek_reasoning_effort_capability
        ; test_case
            "runtime TOML accepts GLM Coding Plan capabilities"
            `Quick
            test_runtime_toml_accepts_glm_coding_capability
        ; test_case
            "runtime TOML accepts chat template token thinking"
            `Quick
            test_runtime_toml_accepts_chat_template_token_capability
        ; test_case
            "runtime adapter materializes DeepSeek OpenAI compat"
            `Quick
            test_runtime_adapter_materializes_deepseek_openai_compat
        ; test_case
            "runtime max_tokens wire omission and explicit override"
            `Quick
            test_runtime_adapter_max_tokens_wire_omission_and_explicit_override
        ; test_case
            "runtime adapter materializes GLM Coding Plan provider"
            `Quick
            test_runtime_adapter_materializes_glm_coding_provider
        ; test_case
            "runtime adapter threads binding keep-alive and num-ctx"
            `Quick
            test_runtime_adapter_threads_binding_keep_alive_and_num_ctx
        ; test_case
            "runtime adapter leaves keep-alive and num-ctx unset by default"
            `Quick
            test_runtime_adapter_leaves_keep_alive_and_num_ctx_unset_by_default
        ; test_case
            "runtime agent terminal observation carries model identity"
            `Quick
            test_runtime_agent_terminal_observation_uses_runtime_identity
        ; test_case
            "runtime agent terminal error observation marks failed attempt"
            `Quick
            test_runtime_agent_terminal_error_observation_marks_failed_attempt
        ; test_case
            "max turns is continuation checkpoint"
            `Quick
            test_runtime_agent_max_turns_is_continuation_checkpoint
        ; test_case
            "typed recovery defer is a control checkpoint"
            `Quick
            test_runtime_agent_recovery_defer_is_control_checkpoint
        ; test_case
            "runtime agent context uses configured turn budget"
            `Quick
            test_runtime_agent_context_uses_configured_turn_budget
        ; test_case
            "runtime agent context preserves max_tokens intent"
            `Quick
            test_runtime_agent_context_preserves_max_tokens_intent
        ; test_case
            "runtime lifecycle attrs preserve max_tokens intent"
            `Quick
            test_runtime_agent_lifecycle_attrs_preserve_max_tokens_intent
        ; test_case
            "runtime agent context preserves provider sampling config"
            `Quick
            test_runtime_agent_context_preserves_provider_sampling_config
        ; test_case
            "runtime agent context preserves unbounded resume budget"
            `Quick
            test_runtime_agent_context_preserves_unbounded_resume_budget
        ; test_case
            "runtime agent context resume patches stale response_format to base contract"
            `Quick
            test_runtime_agent_context_resume_patches_stale_response_format_to_base_contract
        ; test_case
            "runtime agent context leaves tool_choice unset with tools"
            `Quick
            test_runtime_agent_context_leaves_tool_choice_unset_with_tools
        ; test_case
            "dashboard runtime provider reachability contracts"
            `Quick
            test_dashboard_runtime_probe_reachability_contracts
        ; test_case
            "clock fail-fast raises when idle set without clock (RFC-OAS-026)"
            `Quick
            test_clock_failfast_returns_typed_error_when_idle_set_without_clock
        ; test_case
            "clock fail-fast opt-out when no idle no clock"
            `Quick
            test_clock_failfast_opt_out_when_no_idle_no_clock
        ] )
    ]
