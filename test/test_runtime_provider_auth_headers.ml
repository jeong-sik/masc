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
  ; enabled = true
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
  ; antigravity_cli = None
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
  ; reasoning_effort = None
  ; turn_timeout_s = None
  ; wall_clock_ceiling_s = None
  ; max_prompt_bytes = None
  ; capabilities = None
  }

let runpod_binding =
  { Runtime_schema.provider_id = "runpod_mtp"
  ; model_id = "qwen"
  ; enabled = true
  ; is_default = true
  ; wizard_default = false
  ; max_concurrent = None
  ; max_request_body_bytes = None
  ; max_tokens = None
  ; price_input = None
  ; price_output = None
  ; keep_alive = None
  ; num_ctx = None
  ; repeat_penalty = None
  ; repeat_last_n = None
  ; return_progress = None
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

(* A declared credential header must not survive into Provider_config.headers:
   auth travels as [api_key] and AGENT_CORE merges it at request time, so a copy here
   duplicates the secret. The strip used to know only authorization and
   x-api-key, while the dashboard's separate list also knew api-key and
   x-auth-token — so the dashboard hid exactly the header the adapter kept
   forwarding. *)
let test_declared_credential_headers_never_reach_provider_config () =
  let content =
    runtime_toml_with_credentials
      ~provider_extra:
        {|[providers.runpod_mtp.headers]
"api-key" = "sk-declared-secret"
"x-auth-token" = "tok-declared-secret"
"x-trace-hint" = "keep-me"
|}
      inline_credentials
  in
  match Runtime_toml.parse_string content with
  | Error errors ->
    failf
      "expected runtime TOML provider headers to parse: %s"
      (String.concat "; "
         (List.map
            (fun (err : Runtime_toml.parse_error) ->
               Printf.sprintf "%s: %s" err.path err.message)
            errors))
  | Ok cfg ->
    (match cfg.bindings with
     | [ binding ] ->
       (match Runtime_adapter.binding_to_provider_config cfg binding with
        | Error msg -> failf "unexpected adapter error: %s" msg
        | Ok provider_cfg ->
          let keys =
            List.map
              (fun (key, _) -> String.lowercase_ascii (String.trim key))
              provider_cfg.headers
          in
          List.iter
            (fun secret_key ->
               check bool
                 (Printf.sprintf "%s is stripped from provider config" secret_key)
                 false
                 (List.exists (String.equal secret_key) keys))
            [ "api-key"; "x-auth-token" ];
          check bool "a non-credential header survives" true
            (List.exists (String.equal "x-trace-hint") keys))
     | bindings -> failf "expected one binding, got %d" (List.length bindings))

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

let test_runtime_toml_rejects_unknown_protocol () =
  let content =
    {|
[runtime]
default = "invalid_protocol.test_model"

[providers.invalid_protocol]
display-name = "Invalid protocol"
protocol = "future-wire"
endpoint = "https://invalid.example/v1"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[invalid_protocol.test_model]
max-concurrent = 1
|}
  in
  match Runtime_toml.parse_string content with
  | Ok _ -> fail "expected runtime TOML to reject an unknown protocol"
  | Error errors ->
    check bool "rejects unknown protocol"
      true
      (List.exists
         (fun (err : Runtime_toml.parse_error) ->
            String.equal err.path "providers.invalid_protocol.protocol"
            && String.equal err.message
                 "unknown protocol \"future-wire\": expected one of \
                  messages-cli, messages-http, openai-compatible-cli, \
                  openai-compatible-http, ollama-http, codex-app-server, \
                  claude-code, antigravity-cli")
         errors)

let test_runtime_toml_editor_protocol_inventory_is_backend_owned () =
  let render (protocol : Runtime_toml.editor_protocol) =
    let transport =
      match protocol.transport with
      | Runtime_toml.Endpoint -> "endpoint"
      | Runtime_toml.Command -> "command"
    in
    let semantics =
      match protocol.semantics with
      | Runtime_toml.Http_provider -> "http_provider"
      | Runtime_toml.Official_client -> "official_client"
    in
    let credential_policy =
      match protocol.credential_policy with
      | Runtime_toml.Credentials_optional -> "optional"
      | Runtime_toml.Credentials_forbidden -> "forbidden"
      | Runtime_toml.Credentials_file_required -> "file_required"
    in
    Printf.sprintf
      "%s:%s:%s:%s:%b:%s:%s"
      protocol.protocol
      transport
      semantics
      credential_policy
      protocol.requires_non_interactive
      (String.concat "," protocol.provider_fields)
      (String.concat "," protocol.required_provider_fields)
  in
  check
    (list string)
    "only production-materializable protocols are offered"
    [ "messages-http:endpoint:http_provider:optional:false::"
    ; "openai-compatible-http:endpoint:http_provider:optional:false::"
    ; "ollama-http:endpoint:http_provider:optional:false::"
    ; "codex-app-server:command:official_client:forbidden:true::"
    ; "claude-code:command:official_client:forbidden:true::"
    ; "antigravity-cli:command:official_client:file_required:true:agent,effort,timeout-s:timeout-s"
    ]
    (List.map render Runtime_toml.editor_protocols)
;;

let test_runtime_toml_rejects_reserved_provider_and_model_ids () =
  let cases =
    [ ( "provider"
      , "providers.runtime"
      , {|
[providers.runtime]
display-name = "Reserved"
protocol = "openai-compatible-http"
endpoint = "https://example.invalid/v1"
|} )
    ; ( "model"
      , "models.routes"
      , {|
[models.routes]
api-name = "reserved"
max-context = 1024
|} )
    ]
  in
  List.iter
    (fun (kind, path, content) ->
       match Runtime_toml.parse_string content with
       | Ok _ -> failf "expected reserved %s id to fail" kind
       | Error errors -> check_parse_error_contains errors path "reserved top-level")
    cases
;;

let test_runtime_toml_rejects_obsolete_top_level_namespaces () =
  List.iter
    (fun namespace ->
       let content = Printf.sprintf "[%s]\nlegacy = true\n" namespace in
       match Runtime_toml.parse_string content with
       | Ok _ -> failf "expected obsolete namespace %s to fail" namespace
       | Error errors ->
         check_parse_error
           errors
           namespace
           (Printf.sprintf
              "obsolete top-level namespace %S is not supported"
              namespace))
    [ "system"; "routes"; "profiles" ]
;;

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

let test_runtime_adapter_uses_canonical_anthropic_headers () =
  let content =
    {|
[runtime]
default = "claude.claude-opus-4"

[providers.claude]
display-name = "Anthropic"
protocol = "messages-http"
endpoint = "https://api.anthropic.com"

[models.claude-opus-4]
api-name = "claude-opus-4"
max-context = 200000
tools-support = true
streaming = true

[claude.claude-opus-4]
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
    let expected =
      [ "anthropic-version", "2023-06-01"
      ; "Content-Type", "application/json"
      ]
    in
    check
      (list (pair string string))
      "canonical Anthropic defaults"
      expected
      (Runtime_provider_binding.default_headers_for_kind
         Llm_provider.Provider_config.Anthropic);
    (match config.bindings with
     | [ binding ] ->
       (match Runtime_adapter.binding_to_provider_config config binding with
        | Error message -> fail message
        | Ok provider_config ->
          check
            (list (pair string string))
            "adapter uses canonical non-auth header defaults"
            expected
            provider_config.headers)
     | bindings -> failf "expected one binding, got %d" (List.length bindings))

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
    ; keeper_assignments = []
    ; media_failover = []
    ; lane_decls = []
    ; exact_output_lane_decls = []
    ; exec_ssh_endpoints = []
    ; egress_allowlists = []
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
    ; keeper_assignments = []
    ; media_failover = []
    ; lane_decls = []
    ; exact_output_lane_decls = []
    ; exec_ssh_endpoints = []
    ; egress_allowlists = []
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
    ; keeper_assignments = []
    ; media_failover = []
    ; lane_decls = []
    ; exact_output_lane_decls = []
    ; exec_ssh_endpoints = []
    ; egress_allowlists = []
    }
  in
  match Runtime_adapter.binding_to_provider_config cfg runpod_binding with
  | Ok provider_cfg -> provider_cfg
  | Error msg -> failf "unexpected adapter error: %s" msg

(* --- provider_id capability qualification ---

   The adapter must stamp the runtime.toml [providers.<id>] table name into
   [Provider_config.provider_id]: it is the capability-catalog qualification
   key ([capability_provider_label] prefers it over the wire kind), and the
   AGENT_CORE contract (provider_config.mli, capabilities_for_config_model) only
   accepts an exact provider-scoped row once a provider is declared. Without
   it every OpenAI-compatible endpoint collapsed into the "openai_compat"
   label, which no catalog row carries — the 2026-07-15 boot-gate wipeout
   where all routed runtimes were reported catalog-missing. *)

let with_model_catalog toml f =
  match Llm_provider.Model_catalog.of_toml_string ~source:"inline-test-catalog" toml with
  | Error msg -> failf "test catalog parse failed: %s" msg
  | Ok catalog ->
    Llm_provider.Model_catalog.set_global catalog;
    Fun.protect ~finally:Llm_provider.Model_catalog.clear_global f

let test_adapter_stamps_declared_provider_id () =
  check
    (option string)
    "provider_id"
    (Some "runpod_mtp")
    (provider_cfg ()).provider_id

let test_provider_scoped_catalog_row_resolves_for_declared_provider () =
  with_model_catalog
    {|
[[models]]
id_prefix = "qwen"
provider_name = "runpod_mtp"
max_context_tokens = 160000
|}
    (fun () ->
       match
         Llm_provider.Provider_config.capabilities_for_config_model (provider_cfg ())
       with
       | Some caps ->
         check
           (option int)
           "max_context_tokens from provider-scoped row"
           (Some 160000)
           caps.Llm_provider.Capabilities.max_context_tokens
       | None -> fail "provider-scoped catalog row did not resolve")

let test_bare_catalog_row_stays_fail_closed_for_declared_provider () =
  with_model_catalog
    {|
[[models]]
id_prefix = "qwen"
max_context_tokens = 160000
|}
    (fun () ->
       match
         Llm_provider.Provider_config.capabilities_for_config_model (provider_cfg ())
       with
       | Some _ ->
         fail
           "bare catalog row must not satisfy a declared provider (exact \
            provider-scoped row required)"
       | None -> ())

let test_declared_thinking_capabilities_override_catalog () =
  with_model_catalog
    {|
[[models]]
id_prefix = "qwen"
provider_name = "runpod_mtp"
supports_system_prompt = true
supports_reasoning = true
supports_reasoning_budget = true
thinking_control_format = "ollama_think"
|}
    (fun () ->
       let runtime_caps =
         { Runtime_schema.model_capabilities_default with
           supports_reasoning_budget = false
         ; thinking_control_format = Runtime_schema.No_thinking_control
         ; declared_thinking_control_format = Some Runtime_schema.No_thinking_control
         ; reasoning_streaming_format =
             Some (Runtime_schema.Delta_reasoning_field "reasoning_content")
         }
       in
       let model = { qwen_model with capabilities = Some runtime_caps } in
       let cfg =
         { Runtime_schema.providers = [ runpod_provider ]
         ; models = [ model ]
         ; bindings = [ runpod_binding ]
         ; default_runtime_id = Some "runpod_mtp.qwen"
         ; keeper_assignments = []
         ; media_failover = []
         ; lane_decls = []
         ; exact_output_lane_decls = []
         ; exec_ssh_endpoints = []
         ; egress_allowlists = []
         }
       in
       let provider_cfg =
         match Runtime_adapter.binding_to_provider_config cfg runpod_binding with
         | Ok provider_cfg -> provider_cfg
         | Error msg -> failf "unexpected adapter error: %s" msg
       in
       match Llm_provider.Provider_config.capabilities_for_config_model provider_cfg with
       | None -> fail "declared thinking capability override should resolve"
       | Some caps ->
         check bool "declared thinking control wins" true
           (caps.thinking_control_format
            = Llm_provider.Capabilities.No_thinking_control);
         check bool "declared reasoning budget wins" false caps.supports_reasoning_budget;
         check bool "sparse system prompt preserves catalog" true caps.supports_system_prompt;
         check bool "declared transport stream parser wins" true
           (caps.reasoning_streaming_format
            = Llm_provider.Capabilities.Delta_reasoning_field "reasoning_content"))

(* Audit F2: TOML keep-alive / num-ctx must reach the wire-level
   Provider_config. Before the fix the adapter dropped both binding
   fields, so keep_alive fell back to AGENT_CORE_OLLAMA_KEEP_ALIVE / "-1" and
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
    ; keeper_assignments = []
    ; media_failover = []
    ; lane_decls = []
    ; exact_output_lane_decls = []
    ; exec_ssh_endpoints = []
    ; egress_allowlists = []
    }
  in
  match Runtime.of_binding cfg runpod_binding with
  | Ok runtime -> runtime
  | Error reason ->
    failf
      "expected runtime binding to materialize: %s"
      (Runtime.string_of_drop_reason reason)

let agent_core_provider_config_or_fail runtime =
  match runtime.Runtime.execution with
  | Runtime_execution.Agent_core provider_config -> provider_config
  | Runtime_execution.Codex_app_server _
  | Runtime_execution.Claude_code _
  | Runtime_execution.Antigravity_cli _ ->
    fail "expected Agent Core runtime"

let test_dispatch_rejects_missing_declared_env_credential () =
  let env_key = "MASC_TEST_DISPATCH_CREDENTIAL_MISSING_5D72C48E" in
  with_env env_key "" (fun () ->
    let provider =
      { runpod_provider with credentials = Some (Runtime_schema.Env env_key) }
    in
    let runtime = runtime_or_fail ~provider () in
    let provider_config = agent_core_provider_config_or_fail runtime in
    match Runtime.validate_dispatch_credential ~provider_config runtime with
    | Error
        ((Runtime.Required_env_credential_missing
            { provider_id; env_key = actual_env_key }) as error) ->
      check string "provider id" "runpod_mtp" provider_id;
      check string "env key" env_key actual_env_key;
      (match Runtime.dispatch_credential_error_to_core_error error with
       | Agent_core.Error.Config (Agent_core.Error.MissingEnvVar { var_name }) ->
         check string "typed missing credential env" env_key var_name
       | core_error ->
         failf
           "expected MissingEnvVar, got: %s"
           (Agent_core.Error.to_string core_error))
    | Error error ->
      failf
        "expected missing env credential, got: %s"
        (Runtime.dispatch_credential_error_to_string error)
    | Ok () -> fail "expected dispatch credential validation to fail");
  let check_unavailable credential expected_carrier =
    let provider = { runpod_provider with credentials = Some credential } in
    let runtime = runtime_or_fail ~provider () in
    let provider_config = agent_core_provider_config_or_fail runtime in
    match Runtime.validate_dispatch_credential ~provider_config runtime with
    | Error (Runtime.Declared_credential_unavailable _ as error) ->
      (match Runtime.dispatch_credential_error_to_core_error error with
       | Agent_core.Error.Config
           (Agent_core.Error.CredentialUnavailable
              { provider_id; carrier }) ->
         check string "unavailable provider id" "runpod_mtp" provider_id;
         check bool "typed unavailable carrier" true (carrier = expected_carrier)
       | core_error ->
         failf
           "expected CredentialUnavailable, got: %s"
           (Agent_core.Error.to_string core_error))
    | Error error ->
      failf
        "expected unavailable credential, got: %s"
        (Runtime.dispatch_credential_error_to_string error)
    | Ok () -> fail "expected unavailable credential validation to fail"
  in
  check_unavailable
    (Runtime_schema.Inline "")
    Agent_core.Error.InlineCredential;
  check_unavailable
    (Runtime_schema.File "/operator/credential")
    Agent_core.Error.FileCredential

let test_dispatch_accepts_transformed_or_credential_free_provider () =
  let env_key = "MASC_TEST_DISPATCH_CREDENTIAL_TRANSFORM_0187ABCE" in
  with_env env_key "" (fun () ->
    let provider =
      { runpod_provider with credentials = Some (Runtime_schema.Env env_key) }
    in
    let runtime = runtime_or_fail ~provider () in
    let provider_config = agent_core_provider_config_or_fail runtime in
    let transformed_provider_config =
      { provider_config with
        Llm_provider.Provider_config.api_key =
          Llm_provider.Secret.of_string "injected-at-dispatch"
      }
    in
    check (result unit reject) "transformed credential" (Ok ())
      (Runtime.validate_dispatch_credential
         ~provider_config:transformed_provider_config
         runtime));
  let provider = { runpod_provider with credentials = None } in
  let runtime = runtime_or_fail ~provider () in
  let provider_config = agent_core_provider_config_or_fail runtime in
  check (result unit reject) "credential-free provider" (Ok ())
    (Runtime.validate_dispatch_credential ~provider_config runtime)

let test_runtime_of_binding_preserves_failure_reason () =
  let cfg =
    { Runtime_schema.providers = [ runpod_provider ]
    ; models = [ qwen_model ]
    ; bindings = [ runpod_binding ]
    ; default_runtime_id = Some "runpod_mtp.qwen"
    ; keeper_assignments = []
    ; media_failover = []
    ; lane_decls = []
    ; exact_output_lane_decls = []
    ; exec_ssh_endpoints = []
    ; egress_allowlists = []
    }
  in
  match Runtime.of_binding cfg { runpod_binding with enabled = false } with
  | Ok _ -> fail "expected disabled binding materialization to fail"
  | Error Runtime.Binding_disabled ->
    check string "disabled binding reason"
      "binding is disabled by runtime.toml"
      (Runtime.string_of_drop_reason Runtime.Binding_disabled)
  | Error other ->
    failf
      "expected Binding_disabled, got %s"
      (Runtime.string_of_drop_reason other)

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
         Server_dashboard_http_runtime_info.dashboard_runtime_probe_payload_json_of_runtimes
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
         Server_dashboard_http_runtime_info.dashboard_runtime_probe_payload_json_of_runtimes
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
         Server_dashboard_http_runtime_info.dashboard_runtime_probe_payload_json_of_runtimes
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

let test_dashboard_runtime_probe_groups_models_by_provider () =
  let second_model =
    { qwen_model with Runtime_schema.id = "qwen-2"; api_name = "qwen-2" }
  in
  let second_binding =
    { runpod_binding with
      Runtime_schema.model_id = second_model.id
    ; is_default = false
    }
  in
  let config =
    { Runtime_schema.providers = [ runpod_provider ]
    ; models = [ qwen_model; second_model ]
    ; bindings = [ runpod_binding; second_binding ]
    ; default_runtime_id = Some "runpod_mtp.qwen"
    ; keeper_assignments = []
    ; media_failover = []
    ; lane_decls = []
    ; exact_output_lane_decls = []
    ; exec_ssh_endpoints = []
    ; egress_allowlists = []
    }
  in
  let runtime binding =
    match Runtime.of_binding config binding with
    | Ok runtime -> runtime
    | Error reason ->
      failf "expected grouped runtime to materialize: %s" (Runtime.string_of_drop_reason reason)
  in
  let calls = ref 0 in
  let json =
    with_dashboard_probe_http_get
      (fun ~url:_ ~headers:_ ~timeout_sec:_ ->
         incr calls;
         Ok (200, [ "content-type", "application/json" ], {|{"data":[]}|}))
      (fun () ->
         Server_dashboard_http_runtime_info.dashboard_runtime_probe_payload_json_of_runtimes
           ~default_id:"runpod_mtp.qwen"
           [ runtime runpod_binding; runtime second_binding ])
  in
  check int "one provider metadata request" 1 !calls;
  let providers = Yojson.Safe.Util.(member "providers" json |> to_list) in
  check (list string) "runtime rows preserved"
    [ "runpod_mtp.qwen"; "runpod_mtp.qwen-2" ]
    (List.map Yojson.Safe.Util.(fun row -> member "runtime_id" row |> to_string) providers);
  check int "reachable runtime projections" 2
    Yojson.Safe.Util.(member "summary" json |> member "reachable" |> to_int)

let test_runtime_agent_terminal_observation_uses_runtime_identity () =
  let config =
    Runtime_agent.default_config
      ~name:"agent_core-runpod_mtp.qwen"
      ~provider_cfg:(provider_cfg ())
      ~system_prompt:""
      ~tools:[]
  in
  let config =
    { config with runtime_id = Some "runpod_mtp.qwen" }
  in
  let observation =
    Runtime_agent.For_testing.runtime_observation_for_completed_config
      ~total_duration_ms:42.9
      ~usage_scope:Runtime_usage_scope.Usage_scope_unavailable
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
      ~name:"agent_core-runpod_mtp.qwen"
      ~provider_cfg:(provider_cfg ())
      ~system_prompt:""
      ~tools:[]
  in
  let config =
    { config with runtime_id = Some "runpod_mtp.qwen" }
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
          ~lane_failover_applied:false
          (Some observation)));
  (* The failed-attempt observation is unchanged, but a lane walk that
     landed this attempt on a later candidate (lane_failover_applied)
     always reports the turn as passed-to-next-model — that signal comes
     from the lane walk, not from anything on the observation. *)
  check string "runtime outcome reflects lane failover truth, not observation shape"
    "passed_to_next_model"
    (Keeper_execution_receipt.runtime_outcome_to_string
       (Keeper_agent_error.runtime_outcome_of_observation
          ~lane_failover_applied:true
          (Some observation)))

let test_runtime_agent_context_preserves_max_tokens_intent () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let check_builder_max_tokens expected max_tokens =
        let config =
          Runtime_agent.default_config
            ~name:"agent_core-runpod_mtp.qwen"
            ~provider_cfg:(provider_cfg ())
            ~system_prompt:""
            ~tools:[]
        in
        let config = { config with max_tokens } in
        let builder =
          Runtime_agent_context.builder
            ~net:(Eio.Stdenv.net env)
            ~config
            ()
        in
        match Agent_core.Builder.build_safe builder with
        | Error err -> fail (Agent_core.Error.to_string err)
        | Ok agent ->
          check (option int) "builder max_tokens intent" expected
            (Agent_core.Agent.state agent).config.max_tokens;
          Eio.Switch.on_release sw (fun () -> Agent_core.Agent.close agent)
      in
      check_builder_max_tokens None None;
      check_builder_max_tokens (Some 2048) (Some 2048)))

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
      ~name:"agent_core-runpod_mtp.qwen"
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
        Runtime_agent_context.builder
          ~net:(Eio.Stdenv.net env)
          ~config
          ()
      in
      match Agent_core.Builder.build_safe builder with
      | Error err -> fail (Agent_core.Error.to_string err)
      | Ok agent ->
        let agent_config = (Agent_core.Agent.state agent).config in
        check (option (float 0.0001)) "builder top_p" (Some 0.91)
          agent_config.top_p;
        check (option int) "builder top_k" (Some 42) agent_config.top_k;
        check (option (float 0.0001)) "builder min_p" (Some 0.07)
          agent_config.min_p;
        Eio.Switch.on_release sw (fun () ->
          Agent_core.Agent.close agent)));
  let checkpoint =
    { Agent_core.Checkpoint.version = Agent_core.Checkpoint.checkpoint_version
    ; session_id = "session"
    ; agent_name = "agent_core-runpod_mtp.qwen"
    ; model = "qwen"
    ; system_prompt = Some ""
    ; messages = []
    ; usage = Agent_core.Types.empty_usage
    ; turn_count = 3
    ; created_at = 0.0
    ; tools = []
    ; tool_choice = None
    ; disable_parallel_tool_use = false
    ; temperature = Some 0.3
    ; top_p = Some 0.12
    ; top_k = Some 7
    ; min_p = Some 0.02
    ; reasoning_effort = None
    ; enable_thinking = None
    ; preserve_thinking = None
    ; response_format = (Agent_core.Types.default_config ~model:"qwen").response_format
    ; thinking_budget = None
    ; cache_system_prompt = false
    ; context = Agent_core.Context.create_sync ()
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

let test_runtime_agent_context_resume_patches_stale_response_format_to_base_contract () =
  let provider_cfg_with_response_format =
    let base = provider_cfg () in
    { base with
      Llm_provider.Provider_config.response_format = Agent_core.Types.JsonMode
    }
  in
  let config =
    Runtime_agent.default_config
      ~name:"agent_core-runpod_mtp.qwen"
      ~provider_cfg:provider_cfg_with_response_format
      ~system_prompt:""
      ~tools:[]
  in
  let checkpoint =
    { Agent_core.Checkpoint.version = Agent_core.Checkpoint.checkpoint_version
    ; session_id = "session"
    ; agent_name = "agent_core-runpod_mtp.qwen"
    ; model = "qwen"
    ; system_prompt = Some ""
    ; messages = []
    ; usage = Agent_core.Types.empty_usage
    ; turn_count = 3
    ; created_at = 0.0
    ; tools = []
    ; tool_choice = None
    ; disable_parallel_tool_use = false
    ; temperature = Some 0.3
    ; top_p = None
    ; top_k = None
    ; min_p = None
    ; reasoning_effort = None
    ; enable_thinking = None
    ; preserve_thinking = None
    ; response_format = Agent_core.Types.Off
    ; thinking_budget = None
    ; cache_system_prompt = false
    ; context = Agent_core.Context.create_sync ()
    ; mcp_sessions = []
    ; working_context = None
    }
  in
  let prepared = Runtime_agent_context.prepare_resume ~config ~checkpoint in
  let expected_response_format =
    provider_cfg_with_response_format.Llm_provider.Provider_config.response_format
  in
  check bool "resume patches checkpoint response_format to base contract" true
    (prepared.patched_checkpoint.Agent_core.Checkpoint.response_format
     = expected_response_format)

let test_runtime_agent_context_leaves_tool_choice_unset_with_tools () =
  let tool =
    Agent_core.Tool.create
      ~name:"probe_tool"
      ~description:"probe tool"
      ~parameters:[]
      (fun _input -> Ok { content = "ok"; _meta = None })
  in
  let config =
    Runtime_agent.default_config
      ~name:"agent_core-runpod_mtp.qwen"
      ~provider_cfg:(provider_cfg ())
      ~system_prompt:""
      ~tools:[ tool ]
  in
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let builder =
        Runtime_agent_context.builder
          ~net:(Eio.Stdenv.net env)
          ~config
          ()
      in
      match Agent_core.Builder.build_safe builder with
      | Error err -> fail (Agent_core.Error.to_string err)
      | Ok agent ->
        let agent_config = (Agent_core.Agent.state agent).config in
        check
          (option string)
          "tool_choice remains unset"
          None
          (Option.map Agent_core.Types.show_tool_choice agent_config.tool_choice);
        Eio.Switch.on_release sw (fun () ->
          Agent_core.Agent.close agent)))

let fresh_loopback_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt socket Unix.SO_REUSEADDR true;
  Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  let port =
    match Unix.getsockname socket with
    | Unix.ADDR_INET (_, port) -> port
    | _ -> fail "loopback socket did not expose a TCP port"
  in
  Unix.close socket;
  port

let with_native_count_server f =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let port = fresh_loopback_port () in
  let paths = ref [] in
  let handler _conn request body =
    let _body = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    let path = Cohttp.Request.uri request |> Uri.path in
    paths := path :: !paths;
    if String.equal path "/v1/messages/count_tokens"
    then Cohttp_eio.Server.respond_string ~status:`OK ~body:{|{"input_tokens":500}|} ()
    else
      Cohttp_eio.Server.respond_string
        ~status:`Internal_server_error
        ~body:{|{"error":"completion must not be dispatched"}|}
        ()
  in
  let socket =
    Eio.Net.listen
      net
      ~sw
      ~backlog:4
      ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
  let base_url = Printf.sprintf "http://127.0.0.1:%d" port in
  let result = f ~sw ~net ~base_url in
  result, List.rev !paths

let with_native_projection_server f =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let port = fresh_loopback_port () in
  let requests = ref [] in
  let handler _conn request body =
    let body = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    let path = Cohttp.Request.uri request |> Uri.path in
    requests := (path, body) :: !requests;
    if String.equal path "/v1/messages/count_tokens"
    then Cohttp_eio.Server.respond_string ~status:`OK ~body:{|{"input_tokens":64}|} ()
    else if String.equal path "/v1/messages"
    then
      Cohttp_eio.Server.respond_string
        ~status:`OK
        ~body:
          {|{"id":"msg-projection","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"model":"context-fit-fixture","stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":64,"output_tokens":1}}|}
        ()
    else
      Cohttp_eio.Server.respond_string
        ~status:`Not_found
        ~body:{|{"error":"unexpected path"}|}
        ()
  in
  let socket =
    Eio.Net.listen
      net
      ~sw
      ~backlog:4
      ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
  let base_url = Printf.sprintf "http://127.0.0.1:%d" port in
  let result = f ~sw ~net ~base_url in
  result, List.rev !requests

let context_fit_provider_config base_url =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Anthropic
    ~model_id:"context-fit-fixture"
    ~base_url
    ~api_key:"test-key"
    ~headers:[ "Content-Type", "application/json"; "anthropic-version", "2023-06-01" ]
    ~request_path:"/v1/messages"
    ~max_tokens:64
    ~max_context:512
    ~temperature:0.2
    ()

let context_fit_runtime_config base_url =
  Runtime_agent.default_config
    ~name:"context-fit-fixture"
    ~provider_cfg:(context_fit_provider_config base_url)
    ~system_prompt:"Count the exact provider request before dispatch."
    ~tools:[]

let context_fit_checkpoint () =
  { Agent_core.Checkpoint.version = Agent_core.Checkpoint.checkpoint_version
  ; session_id = "context-fit-session"
  ; agent_name = "context-fit-fixture"
  ; model = "context-fit-fixture"
  ; system_prompt = Some "stale"
  ; messages = []
  ; usage = Agent_core.Types.empty_usage
  ; turn_count = 3
  ; created_at = 0.0
  ; tools = []
  ; tool_choice = None
  ; disable_parallel_tool_use = false
  ; temperature = None
  ; top_p = None
  ; top_k = None
  ; min_p = None
  ; reasoning_effort = None
  ; enable_thinking = None
  ; preserve_thinking = None
  ; response_format = Agent_core.Types.Off
  ; thinking_budget = None
  ; cache_system_prompt = false
  ; context = Agent_core.Context.create_sync ()
  ; mcp_sessions = []
  ; working_context = None
  }

let check_context_fit_overflow = function
  | Error (Agent_core.Error.Api (Agent_core.Retry.ContextOverflow { limit = Some 512; _ })) ->
    ()
  | Error error -> fail (Agent_core.Error.to_string error)
  | Ok _ -> fail "overflowed request must not reach completion dispatch"

let test_runtime_agent_fresh_build_enforces_native_context_fit () =
  let (), paths =
    with_native_count_server
    @@ fun ~sw ~net ~base_url ->
    let config = context_fit_runtime_config base_url in
    let agent =
      match Runtime_agent.build ~sw ~net ~config with
      | Ok agent -> agent
      | Error error -> fail (Agent_core.Error.to_string error)
    in
    Fun.protect
      ~finally:(fun () -> Agent_core.Agent.close agent)
      (fun () -> Agent_core.Agent.run ~sw agent "overflow" |> check_context_fit_overflow)
  in
  check (list string) "fresh request paths" [ "/v1/messages/count_tokens" ] paths

let test_runtime_agent_resume_enforces_native_context_fit () =
  let (), paths =
    with_native_count_server
    @@ fun ~sw ~net ~base_url ->
    let config = context_fit_runtime_config base_url in
    let agent =
      match
        Runtime_agent.resume_from_checkpoint
          ~sw
          ~net
          ~config
          ~checkpoint:(context_fit_checkpoint ())
      with
      | Ok agent -> agent
      | Error error -> fail (Agent_core.Error.to_string error)
    in
    Fun.protect
      ~finally:(fun () -> Agent_core.Agent.close agent)
      (fun () -> Agent_core.Agent.run ~sw agent "overflow" |> check_context_fit_overflow)
  in
  check (list string) "resumed request paths" [ "/v1/messages/count_tokens" ] paths

let projection_messages marker messages =
  let project_block = function
    | Agent_core.Types.Text _ -> Agent_core.Types.Text marker
    | block -> block
  in
  List.map
    (fun (message : Agent_core.Types.message) ->
      { message with content = List.map project_block message.content })
    messages

let run_projection_case ~resume =
  let canonical_marker = "canonical-unprojected-message" in
  let projected_marker = "projected-provider-message" in
  let projection_calls = ref 0 in
  let (), requests =
    with_native_projection_server
    @@ fun ~sw ~net ~base_url ->
    let config =
      { (context_fit_runtime_config base_url) with
        model_input_projection =
          Some
            (fun messages ->
               incr projection_calls;
               Ok (projection_messages projected_marker messages))
      }
    in
    let agent =
      if resume
      then
        Runtime_agent.resume_from_checkpoint
          ~sw
          ~net
          ~config
          ~checkpoint:(context_fit_checkpoint ())
      else Runtime_agent.build ~sw ~net ~config
    in
    let agent =
      match agent with
      | Ok agent -> agent
      | Error error -> fail (Agent_core.Error.to_string error)
    in
    Fun.protect
      ~finally:(fun () -> Agent_core.Agent.close agent)
      (fun () ->
         match Agent_core.Agent.run ~sw agent canonical_marker with
         | Ok _ -> ()
         | Error error -> fail (Agent_core.Error.to_string error))
  in
  check int "projection executes once" 1 !projection_calls;
  check
    (list string)
    "measurement and completion both execute"
    [ "/v1/messages/count_tokens"; "/v1/messages" ]
    (List.map fst requests);
  List.iter
    (fun (path, body) ->
       check bool (path ^ " sees projected input") true
         (String_util.contains_substring body projected_marker);
       check bool (path ^ " excludes canonical input") false
         (String_util.contains_substring body canonical_marker))
    requests

let test_runtime_agent_fresh_projection_precedes_measurement () =
  run_projection_case ~resume:false

let test_runtime_agent_resume_projection_precedes_measurement () =
  run_projection_case ~resume:true

let run_pre_dispatch_serialization_observer_case ~resume =
  let observed_body_bytes = ref [] in
  let (), requests =
    with_native_projection_server
    @@ fun ~sw ~net ~base_url ->
    let config =
      { (context_fit_runtime_config base_url) with
        pre_dispatch_serialization_observer =
          Some
            (fun observation ->
               observed_body_bytes :=
                 observation.Llm_provider.Request_wire_observer.body_bytes
                 :: !observed_body_bytes;
               Ok ())
      }
    in
    let agent =
      if resume
      then
        Runtime_agent.resume_from_checkpoint
          ~sw
          ~net
          ~config
          ~checkpoint:(context_fit_checkpoint ())
      else Runtime_agent.build ~sw ~net ~config
    in
    let agent =
      match agent with
      | Ok agent -> agent
      | Error error -> fail (Agent_core.Error.to_string error)
    in
    Fun.protect
      ~finally:(fun () -> Agent_core.Agent.close agent)
      (fun () ->
         match Agent_core.Agent.run ~sw agent "observe exact request bytes" with
         | Ok _ -> ()
         | Error error -> fail (Agent_core.Error.to_string error))
  in
  let completion_body = List.assoc "/v1/messages" requests in
  check
    (list int)
    "observer receives the exact dispatched body size once"
    [ String.length completion_body ]
    (List.rev !observed_body_bytes)

let test_runtime_agent_fresh_observes_pre_dispatch_serialization () =
  run_pre_dispatch_serialization_observer_case ~resume:false

let test_runtime_agent_resume_observes_pre_dispatch_serialization () =
  run_pre_dispatch_serialization_observer_case ~resume:true

(* Agent Core contract §4.6: a configured stream-idle deadline with no resolvable clock
   must fail loudly rather than silently disarm the only I2-legitimate
   streaming timeout. *)
let test_clock_failfast_returns_typed_error_when_idle_set_without_clock () =
  match
    Runtime_agent.For_testing.decide_clock_for_idle
      ~stream_idle_timeout_s:(Some 120.0)
      ~first_event_timeout_s:None
      ~process_clock:(Error "process runtime not initialised")
      ~ctx_clock:None
  with
  | Error (Agent_core.Error.Config (Agent_core.Error.InvalidConfig { field; detail })) ->
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
         (Agent_core.Error.to_string err))
  | Ok _ -> fail "expected typed error when idle is configured but no clock resolves"

let test_clock_failfast_opt_out_when_no_idle_no_clock () =
  (* Legitimate opt-out: no streaming deadline + no clock stays None, no raise. *)
  let clock =
    Runtime_agent.For_testing.decide_clock_for_idle
      ~stream_idle_timeout_s:None
      ~first_event_timeout_s:None
      ~process_clock:(Error "no runtime")
      ~ctx_clock:None
  in
  check bool "no idle + no clock -> None" true
    (match clock with
     | Ok None -> true
     | Ok (Some _) | Error _ -> false)

(* RFC-AC-037: the first-event (TTFT/prefill) bound has the same clock
   dependency as the idle bound — configured without a resolvable clock it
   must fail loudly, naming its own knob. *)
let test_clock_failfast_returns_typed_error_when_first_event_set_without_clock () =
  match
    Runtime_agent.For_testing.decide_clock_for_idle
      ~stream_idle_timeout_s:None
      ~first_event_timeout_s:(Some 600.0)
      ~process_clock:(Error "process runtime not initialised")
      ~ctx_clock:None
  with
  | Error (Agent_core.Error.Config (Agent_core.Error.InvalidConfig { field; detail })) ->
    check string "field" "first_event_timeout_s" field;
    check
      bool
      "message identifies the configured first-event deadline with no clock"
      true
      (String.starts_with
         ~prefix:"runtime_agent: first_event_timeout_s configured"
         detail)
  | Error err ->
    fail
      (Printf.sprintf
         "expected InvalidConfig first_event_timeout_s, got %s"
         (Agent_core.Error.to_string err))
  | Ok _ ->
    fail "expected typed error when first-event is configured but no clock resolves"

let test_clock_failfast_names_idle_when_both_deadlines_set () =
  (* Both knobs configured: the error names the idle knob (its arm is
     checked first); the point pinned here is that SOME typed error fires,
     not a silent disarm. *)
  match
    Runtime_agent.For_testing.decide_clock_for_idle
      ~stream_idle_timeout_s:(Some 120.0)
      ~first_event_timeout_s:(Some 600.0)
      ~process_clock:(Error "no runtime")
      ~ctx_clock:None
  with
  | Error (Agent_core.Error.Config (Agent_core.Error.InvalidConfig { field; _ })) ->
    check string "field" "stream_idle_timeout_s" field
  | Error err ->
    fail (Printf.sprintf "expected InvalidConfig, got %s" (Agent_core.Error.to_string err))
  | Ok _ -> fail "expected typed error when both deadlines set without clock"

(* ── Runtime.decide_capability_gate (AGENT_CORE catalog binding gate) ── *)

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
            "runtime binding materialization preserves failure reason"
            `Quick
            test_runtime_of_binding_preserves_failure_reason
        ; test_case
            "dispatch rejects missing declared env credential"
            `Quick
            test_dispatch_rejects_missing_declared_env_credential
        ; test_case
            "dispatch accepts transformed or credential-free provider"
            `Quick
            test_dispatch_accepts_transformed_or_credential_free_provider
        ; test_case
            "adapter stamps declared provider id"
            `Quick
            test_adapter_stamps_declared_provider_id
        ; test_case
            "provider-scoped catalog row resolves for declared provider"
            `Quick
            test_provider_scoped_catalog_row_resolves_for_declared_provider
        ; test_case
            "bare catalog row stays fail-closed for declared provider"
            `Quick
            test_bare_catalog_row_stays_fail_closed_for_declared_provider
        ; test_case
            "declared thinking capabilities override catalog"
            `Quick
            test_declared_thinking_capabilities_override_catalog
        ; test_case
            "runtime adapter carries auth in api_key only"
            `Quick
            test_runtime_adapter_keeps_auth_out_of_headers
        ; test_case
            "runtime adapter filters TOML auth headers"
            `Quick
            test_runtime_adapter_filters_toml_auth_headers
        ; test_case
            "runtime adapter uses canonical Anthropic headers"
            `Quick
            test_runtime_adapter_uses_canonical_anthropic_headers
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
            "declared credential headers never reach provider config"
            `Quick
            test_declared_credential_headers_never_reach_provider_config
        ; test_case
            "runtime TOML rejects non-positive provider connect timeout"
            `Quick
            test_runtime_toml_rejects_non_positive_provider_connect_timeout
        ; test_case
            "runtime TOML rejects wrong-typed provider connect timeout"
            `Quick
            test_runtime_toml_rejects_wrong_typed_provider_connect_timeout
        ; test_case
            "runtime TOML rejects unknown protocol"
            `Quick
            test_runtime_toml_rejects_unknown_protocol
        ; test_case
            "runtime TOML editor protocol inventory is backend-owned"
            `Quick
            test_runtime_toml_editor_protocol_inventory_is_backend_owned
        ; test_case
            "runtime TOML rejects reserved provider and model ids"
            `Quick
            test_runtime_toml_rejects_reserved_provider_and_model_ids
        ; test_case
            "runtime TOML rejects obsolete top-level namespaces"
            `Quick
            test_runtime_toml_rejects_obsolete_top_level_namespaces
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
            "runtime agent context preserves max_tokens intent"
            `Quick
            test_runtime_agent_context_preserves_max_tokens_intent
        ; test_case
            "runtime agent context preserves provider sampling config"
            `Quick
            test_runtime_agent_context_preserves_provider_sampling_config
        ; test_case
            "runtime agent context resume patches stale response_format to base contract"
            `Quick
            test_runtime_agent_context_resume_patches_stale_response_format_to_base_contract
        ; test_case
            "runtime agent context leaves tool_choice unset with tools"
            `Quick
            test_runtime_agent_context_leaves_tool_choice_unset_with_tools
        ; test_case
            "runtime fresh build enforces native context fit"
            `Quick
            test_runtime_agent_fresh_build_enforces_native_context_fit
        ; test_case
            "runtime resume enforces native context fit"
            `Quick
            test_runtime_agent_resume_enforces_native_context_fit
        ; test_case
            "fresh projection precedes measurement and dispatch"
            `Quick
            test_runtime_agent_fresh_projection_precedes_measurement
        ; test_case
            "resumed projection precedes measurement and dispatch"
            `Quick
            test_runtime_agent_resume_projection_precedes_measurement
        ; test_case
            "fresh agent observes exact pre-dispatch serialization"
            `Quick
            test_runtime_agent_fresh_observes_pre_dispatch_serialization
        ; test_case
            "resumed agent observes exact pre-dispatch serialization"
            `Quick
            test_runtime_agent_resume_observes_pre_dispatch_serialization
        ; test_case
            "dashboard runtime provider reachability contracts"
            `Quick
            test_dashboard_runtime_probe_reachability_contracts
        ; test_case
            "dashboard runtime probe groups models by provider"
            `Quick
            test_dashboard_runtime_probe_groups_models_by_provider
        ; test_case
            "clock fail-fast raises when idle set without clock (Agent Core contract)"
            `Quick
            test_clock_failfast_returns_typed_error_when_idle_set_without_clock
        ; test_case
            "clock fail-fast opt-out when no idle no clock"
            `Quick
            test_clock_failfast_opt_out_when_no_idle_no_clock
        ; test_case
            "clock fail-fast raises when first-event set without clock (RFC-AC-037)"
            `Quick
            test_clock_failfast_returns_typed_error_when_first_event_set_without_clock
        ; test_case
            "clock fail-fast names idle when both deadlines set"
            `Quick
            test_clock_failfast_names_idle_when_both_deadlines_set
        ] )
    ]
