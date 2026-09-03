(** Single-binding → [Provider_config.t] materialization (RFC-0206 §5).

    Re-homed from the deleted [Runtime_declarative_adapter]. Keeps only the
    binding materialization path:

    - TOML provider.id -> declared provider metadata (via {!Runtime_schema})
    - provider metadata + model spec -> {!Llm_provider.Provider_config.t}

    Routing (aliases / routes / system_targets / capability profiles /
    strategy mapping) and the typed [adapter_error] aggregate are dropped: a
    Runtime is one pre-selected binding. Errors are surfaced as
    [(_, string) result] so the caller fails fast (no silent fallback).

    Provider header defaults are owned by {!Runtime_provider_binding}; this
    adapter owns only binding materialization and custom-header filtering.

    @stability Internal *)

module Runtime_binding = Agent_core.Provider_runtime_binding
module Provider_binding = Runtime_provider_binding

(* --- Inlined from the deleted [Runtime_config_provider_binding] --- *)

let normalize_header_key key = String.lowercase_ascii (String.trim key)

(* SSOT for "this header carries a credential". [runtime_adapter] strips these
   from [Provider_config.headers] so the secret is not duplicated alongside
   [api_key], and the dashboard hides them from the provider header list. The
   two used to keep separate lists: this one knew authorization / x-api-key,
   the dashboard's also knew api-key and x-auth-token. The narrower list was
   the one doing the stripping, so a provider declaring
   [headers."api-key"] passed the filter and the secret reached
   [Provider_config.headers] — while the dashboard hid the very header that
   was being forwarded.

   This stays a deny list over free-form TOML keys, which is why the real fix
   is to reject credential-looking keys at parse time or give headers a typed
   non-secret map (issue linked in the PR). Until then one list is strictly
   better than two that disagree. *)
let auth_header_keys = [ "authorization"; "x-api-key"; "api-key"; "x-auth-token" ]

let is_auth_header_key key =
  let normalized = normalize_header_key key in
  List.exists (String.equal normalized) auth_header_keys
;;

let trim_trailing_slash path =
  if String.length path > 1 && String.ends_with ~suffix:"/" path
  then String.sub path 0 (String.length path - 1)
  else path
;;

let is_digit c = c >= '0' && c <= '9'

let is_version_segment s =
  let len = String.length s in
  len >= 2
  && s.[0] = 'v'
  &&
  let rec all_digits i = i >= len || (is_digit s.[i] && all_digits (i + 1)) in
  all_digits 1
;;

let last_path_segment path =
  match String.rindex_opt path '/' with
  | Some idx -> String.sub path (idx + 1) (String.length path - idx - 1)
  | None -> path
;;

let strip_leading_version request_path =
  let len = String.length request_path in
  if len >= 4 && request_path.[0] = '/' && request_path.[1] = 'v' && is_digit request_path.[2]
  then (
    let rec find_slash i =
      if i >= len then len
      else if request_path.[i] = '/' then i
      else find_slash (i + 1)
    in
    let slash_pos = find_slash 2 in
    String.sub request_path slash_pos (len - slash_pos))
  else request_path
;;

let normalize_openai_compat_request_path ~base_url ~request_path =
  let request_path =
    match String.trim request_path with
    | "" -> Masc_network_defaults.openai_chat_completions_path
    | path -> path
  in
  let base_path = Uri.path (Uri.of_string base_url) |> trim_trailing_slash in
  if base_path = "" || base_path = "/"
  then request_path
  else (
    let duplicated_prefix = base_path ^ "/" in
    if String.starts_with ~prefix:duplicated_prefix request_path
    then (
      let suffix_start = String.length base_path + 1 in
      "/"
      ^ String.sub request_path suffix_start (String.length request_path - suffix_start))
    else if is_version_segment (last_path_segment base_path)
            && String.length request_path >= 4
            && request_path.[0] = '/'
            && request_path.[1] = 'v'
            && is_digit request_path.[2]
    then strip_leading_version request_path
    else request_path)
;;

(* --- Provider resolution --- *)

let runtime_binding_id label =
  match Runtime_binding.find label with
  | Some binding -> Some binding.Runtime_binding.id
  | None -> None
;;

let resolve_provider_prefix (provider_id : string) : string option =
  match runtime_binding_id provider_id with
  | Some _ as found -> found
  | None ->
    let normalized = Provider_binding.normalize_provider_id provider_id in
    runtime_binding_id normalized
;;

let find_registry_entry (provider_id : string)
    : Llm_provider.Provider_registry.entry option =
  let registry = Llm_provider.Provider_registry.default () in
  match Llm_provider.Provider_registry.find registry provider_id with
  | Some _ as found -> found
  | None ->
    (match resolve_provider_prefix provider_id with
     | Some prefix -> Llm_provider.Provider_registry.find registry prefix
     | None -> None)
;;

(* --- Credential materialization --- *)

let credential_env_candidates = function
  | "OLLAMA_CLOUD_API_KEY" -> [ "OLLAMA_CLOUD_API_KEY"; "OLLAMA_API_KEY" ]
  | key -> [ key ]
;;

let selected_credential_env key =
  credential_env_candidates key
  |> List.find_opt (fun env ->
    match Sys.getenv_opt env with
    | Some value -> String.trim value <> ""
    | None -> false)
;;

let effective_credential_reference
    ~(provider_id : string)
    (credential : Runtime_schema.credential option) =
  let select_env key =
    match selected_credential_env key with
    | Some selected -> Runtime_schema.Env selected
    | None -> Runtime_schema.Env key
  in
  match credential with
  | Some (Runtime_schema.Env key) -> Some (select_env key)
  | Some (Runtime_schema.File _ | Runtime_schema.Inline _) as explicit -> explicit
  | None ->
    (match find_registry_entry provider_id with
     | Some entry ->
       let env = entry.Llm_provider.Provider_registry.defaults.api_key_env in
       if String.trim env = "" then None else Some (select_env env)
     | None -> None)
;;

let api_key_from_env key =
  (match selected_credential_env key with
   | Some env -> Sys.getenv_opt env
   | None -> None)
  |> Option.value ~default:""
;;

let api_key_of_credential ?registry_entry (credential : Runtime_schema.credential option) =
  match credential with
  | Some (Env key) -> api_key_from_env key
  | Some (Inline value) -> value
  | Some (File _) -> ""
  | None ->
    (match registry_entry with
     | Some entry ->
       let env = entry.Llm_provider.Provider_registry.defaults.api_key_env in
       if env = ""
       then ""
       else
         (* NDT-OK: credential materialization is the provider boundary;
            catalog parsing stays deterministic. *)
         api_key_from_env env
     | None -> "")
;;

(* --- Provider kind resolution --- *)

(* CLI subprocess provider kinds were removed in the agent_core pin bump
   (agent_core service-name migration). No provider kind is a subprocess CLI, so a
   CLI-transport provider can never resolve to a provider kind. The reason is
   surfaced as [Error] (not [None]) so a binding dropped for this cause explains
   itself at load instead of vanishing silently (Unknown->silent-drop
   anti-pattern). *)
let provider_kind_of_cli_provider (provider : Runtime_schema.provider)
    : (Llm_provider.Provider_config.provider_kind, string) result =
  Error
    (Printf.sprintf
       "provider %S uses protocol %s over a CLI transport, which the runtime \
        adapter no longer materializes (CLI subprocess provider kinds were \
        removed in the agent_core pin bump)"
       provider.id
       provider.protocol)
;;

let registry_provider_kind = function
  | Some entry -> Some entry.Llm_provider.Provider_registry.defaults.kind
  | None -> None
;;

let messages_api_compatible_provider_kind = function
  | Llm_provider.Provider_config.Anthropic | Llm_provider.Provider_config.Kimi -> true
  | Llm_provider.Provider_config.OpenAI_compat
  | Llm_provider.Provider_config.Ollama
  | Llm_provider.Provider_config.Gemini
  | Llm_provider.Provider_config.Glm -> false
;;

let provider_kind_for_http_provider ?registry_entry (provider : Runtime_schema.provider)
    : (Llm_provider.Provider_config.provider_kind, string) result =
  match provider.api_format with
  | Codex_app_server_runtime | Claude_code_runtime | Antigravity_cli_runtime ->
    Error
      (Printf.sprintf
         "provider %S uses official CLI protocol %s and cannot be materialized as an \
          HTTP provider"
         provider.id
         provider.protocol)
  | Ollama_api -> Ok Llm_provider.Provider_config.Ollama
  | Chat_completions_api ->
    (* Chat-completions keeps the historical OpenAI-compatible fallback when
       registry metadata is absent. Messages API deliberately fails closed
       below because there is no safe Anthropic-style default. *)
    Ok
      (match registry_provider_kind registry_entry with
       | Some Llm_provider.Provider_config.Ollama ->
         Llm_provider.Provider_config.OpenAI_compat
       | Some kind -> kind
       | None -> Llm_provider.Provider_config.OpenAI_compat)
  | Messages_api ->
    (match registry_provider_kind registry_entry with
     | Some kind when messages_api_compatible_provider_kind kind -> Ok kind
     | Some kind ->
       Error
         (Printf.sprintf
            "provider %S uses protocol %s, but registry kind %s is not \
             messages-compatible"
            provider.id
            provider.protocol
            (Llm_provider.Provider_config.string_of_provider_kind kind))
     | None ->
       Error
         (Printf.sprintf
            "provider %S uses protocol %s, but no AGENT_CORE provider registry entry exists; \
             messages-http requires registry kind SSOT"
            provider.id
            provider.protocol))
;;

let request_path_for_http_provider ~(provider : Runtime_schema.provider) ~registry_entry ~kind
    ~base_url =
  let request_path =
    match provider.api_format, kind with
    | Runtime_schema.Chat_completions_api, Llm_provider.Provider_config.OpenAI_compat ->
      Masc_network_defaults.chat_completions_path
    | _ ->
      (match registry_entry with
       | Some entry -> entry.Llm_provider.Provider_registry.defaults.request_path
       | None -> Llm_provider.Provider_config.request_path_default_for_kind kind)
  in
  match kind with
  | Llm_provider.Provider_config.OpenAI_compat ->
    normalize_openai_compat_request_path ~base_url ~request_path
  | _ -> request_path
;;

(* --- Model capability projection --- *)

let supports_tool_choice_override_of_model_spec (spec : Runtime_schema.model_spec) =
  match spec.capabilities with
  | Some capabilities -> Some capabilities.supports_tool_choice
  | None -> None
;;

let agent_core_thinking_control_format = function
  | Runtime_schema.No_thinking_control ->
    Llm_provider.Capabilities.No_thinking_control
  | Runtime_schema.Thinking_object -> Llm_provider.Capabilities.Thinking_object
  | Runtime_schema.Thinking_object_adaptive ->
    Llm_provider.Capabilities.Thinking_object_adaptive
  | Runtime_schema.Thinking_object_only ->
    Llm_provider.Capabilities.Thinking_object_only
  | Runtime_schema.Chat_template_kwargs ->
    Llm_provider.Capabilities.Chat_template_kwargs
  | Runtime_schema.Chat_template_token token ->
    Llm_provider.Capabilities.Chat_template_token token
  | Runtime_schema.Ollama_think -> Llm_provider.Capabilities.Ollama_think
  | Runtime_schema.Reasoning_effort -> Llm_provider.Capabilities.Reasoning_effort
  | Runtime_schema.Enable_thinking -> Llm_provider.Capabilities.Enable_thinking
;;

(** A runtime [api-name] is an opaque deployment string, not automatically an
    AGENT_CORE catalog model. When AGENT_CORE has no exact provider/model row, project the
    complete typed runtime declaration into the Provider_config override that
    AGENT_CORE exposes for concrete endpoint contracts. Catalogued models keep the AGENT_CORE
    row unchanged; an absent runtime capability block remains absent and is
    rejected later by the normal startup gate. *)
let model_capabilities_override_of_model_spec
      ~(wire : Llm_provider.Provider_kind.t)
      ~(provider_id : string)
      (spec : Runtime_schema.model_spec)
  =
  match
    Llm_provider.Capabilities.for_provider_model_id
      ~wire:(Some wire)
      ~allow_bare_fallback:false
      ~provider_label:provider_id
      ~model_id:spec.api_name
  with
  | Some catalog_caps ->
    (match spec.capabilities with
     | None -> None
     | Some runtime_caps ->
       (match
          runtime_caps.declared_thinking_control_format,
          runtime_caps.declared_supports_reasoning_budget,
          runtime_caps.reasoning_streaming_format
        with
        | None, None, None -> None
        | thinking_control_format, supports_reasoning_budget, reasoning_streaming_format ->
          let effective_reasoning_budget =
            match thinking_control_format with
            (* A concrete transport-control declaration owns the associated
               budget bit as one contract. In particular, explicit [none]
               must not retain a catalog budget that this wire cannot encode. *)
            | Some _ -> runtime_caps.supports_reasoning_budget
            | None ->
              Option.value
                supports_reasoning_budget
                ~default:catalog_caps.supports_reasoning_budget
          in
          Some
            { catalog_caps with
              thinking_control_format =
                (match thinking_control_format with
                 | Some format -> agent_core_thinking_control_format format
                 | None -> catalog_caps.thinking_control_format)
            ; supports_reasoning_budget = effective_reasoning_budget
            ; reasoning_streaming_format =
                Option.value
                  reasoning_streaming_format
                  ~default:catalog_caps.reasoning_streaming_format
            }))
  | None ->
    Option.map
      (fun (caps : Runtime_schema.model_capabilities) ->
         let base = Llm_provider.Capabilities.default_capabilities in
         { base with
           max_context_tokens = spec.max_context
         ; max_output_tokens = caps.max_output_tokens
         ; supports_tools = spec.tools_support
         ; supports_tool_choice = caps.supports_tool_choice
         ; supports_required_tool_choice = caps.supports_required_tool_choice
         ; supports_named_tool_choice = caps.supports_named_tool_choice
         ; supports_parallel_tool_calls = caps.supports_parallel_tool_calls
         ; supports_reasoning = spec.thinking_support
         ; supports_extended_thinking = caps.supports_extended_thinking
         ; supports_reasoning_budget = caps.supports_reasoning_budget
         ; thinking_control_format =
             agent_core_thinking_control_format caps.thinking_control_format
         ; reasoning_streaming_format =
             Option.value
               caps.reasoning_streaming_format
               ~default:base.reasoning_streaming_format
         ; supports_response_format_json = caps.supports_response_format_json
         ; supports_structured_output = caps.supports_structured_output
         ; supports_multimodal_inputs = caps.supports_multimodal_inputs
         ; supports_image_input = caps.supports_image_input
         ; supports_audio_input = caps.supports_audio_input
         ; supports_video_input = caps.supports_video_input
         ; supports_native_streaming = spec.streaming
         ; supports_system_prompt = caps.supports_system_prompt
         ; supports_caching = caps.supports_caching
         ; supports_prompt_caching = caps.supports_prompt_caching
         ; prompt_cache_alignment = caps.prompt_cache_alignment
         ; supports_top_k = caps.supports_top_k
         ; supports_min_p = caps.supports_min_p
         ; supports_seed = caps.supports_seed
         ; supports_seed_with_images = caps.supports_seed_with_images
         ; emits_usage_tokens = caps.emits_usage_tokens
         ; supports_computer_use = caps.supports_computer_use
         ; supports_code_execution = caps.supports_code_execution
         })
      spec.capabilities
;;

(* --- provider × model spec → Provider_config.t --- *)
let provider_config_from_declared_provider ?keep_alive ?num_ctx ?repeat_penalty
    ?max_tokens
    ?repeat_last_n ?return_progress
    ?max_concurrent_requests
    ?max_request_body_bytes
    (provider : Runtime_schema.provider) (spec : Runtime_schema.model_spec)
  : (Llm_provider.Provider_config.t, string) result =
  let registry_entry = find_registry_entry provider.id in
  let supports_tool_choice_override = supports_tool_choice_override_of_model_spec spec in
  match provider.transport with
  | Http base_url ->
    let base_url = Masc_network_defaults.normalize_loopback_base_url base_url in
    (match provider_kind_for_http_provider ?registry_entry provider with
     | Ok kind ->
       let model_capabilities_override =
         model_capabilities_override_of_model_spec
           ~wire:kind
           ~provider_id:provider.id
           spec
       in
       let request_path =
         request_path_for_http_provider ~provider ~registry_entry ~kind ~base_url
       in
       let api_key = api_key_of_credential ?registry_entry provider.credentials in
       let default_headers = Provider_binding.default_headers_for_kind kind in
       let custom_headers =
         match provider.headers with
         | None -> []
         | Some headers ->
           List.filter (fun (key, _) -> not (is_auth_header_key key)) headers
       in
       (* TOML-declared custom headers override generated non-auth headers by
          key. Auth is carried only by [api_key] and is merged by AGENT_CORE at HTTP
          request time, so [Provider_config.headers] does not duplicate secrets. *)
       let custom_keys = List.map (fun (key, _) -> normalize_header_key key) custom_headers in
       let headers =
         custom_headers
         @ List.filter
             (fun (key, _) -> not (List.mem (normalize_header_key key) custom_keys))
             default_headers
       in
       Ok
         (Llm_provider.Provider_config.make
            ~kind
            (* [provider_id] is the runtime.toml [providers.<id>] table name. It is
               the capability-catalog qualification key: [capability_provider_label]
               prefers it over the wire [kind], so provider-qualified catalog rows
               ([provider_name = "<id>"]) resolve per declared provider instead of
               collapsing every OpenAI-compatible endpoint into the "openai_compat"
               label (which no catalog row carries — the 2026-07-15 boot-gate
               wipeout). AGENT_CORE's own binding layer passes it the same way
               (provider_runtime_binding.ml [runtime_binding_provider_config]). *)
            ~provider_id:provider.id
            ~model_id:spec.api_name
            ~base_url
            ~api_key
            ~headers
            ~request_path
            ?max_context:spec.max_context
            ?supports_tool_choice_override
            ?model_capabilities_override
            ?temperature:spec.temperature
            ?top_p:spec.top_p
            ?top_k:spec.top_k
            ?min_p:spec.min_p
            (* The declared effort is the only control this dialect has: under
               [Reasoning_effort] the wire field comes from here, not from
               [enable_thinking] (reasoning_dialect.ml: Chat_completions,
               Reasoning_effort -> normalized_effort_field). Without this the
               model row could name an effort that no HTTP request ever read,
               which is how a model whose endpoint does honour the control was
               left reasoning on every turn. Official-client runtimes read the
               same field through Runtime_inference.resolve_reasoning_effort. *)
            ?reasoning_effort:spec.reasoning_effort
            ?keep_alive
            ?num_ctx
            ?repeat_penalty
            ?repeat_last_n
            ?return_progress
            ?connect_timeout_s:provider.connect_timeout_s
            ?max_concurrent_requests
            ?max_request_body_bytes
            ?max_tokens
            ())
     | Error reason -> Error reason)
  | Cli _ ->
    (match provider_kind_of_cli_provider provider with
     | Ok kind ->
       let model_capabilities_override =
         model_capabilities_override_of_model_spec
           ~wire:kind
           ~provider_id:provider.id
           spec
       in
       Ok
         (Llm_provider.Provider_config.make
            ~kind
            (* Same capability-qualification key as the Http branch above. *)
            ~provider_id:provider.id
            ~model_id:spec.api_name
            ~base_url:""
            ~api_key:(api_key_of_credential ?registry_entry provider.credentials)
            ~headers:(Option.value ~default:[] provider.headers)
            ?max_context:spec.max_context
            ?supports_tool_choice_override
            ?model_capabilities_override
            ?temperature:spec.temperature
            ?top_p:spec.top_p
            ?top_k:spec.top_k
            ?min_p:spec.min_p
            (* The declared effort is the only control this dialect has: under
               [Reasoning_effort] the wire field comes from here, not from
               [enable_thinking] (reasoning_dialect.ml: Chat_completions,
               Reasoning_effort -> normalized_effort_field). Without this the
               model row could name an effort that no HTTP request ever read,
               which is how a model whose endpoint does honour the control was
               left reasoning on every turn. Official-client runtimes read the
               same field through Runtime_inference.resolve_reasoning_effort. *)
            ?reasoning_effort:spec.reasoning_effort
            ?keep_alive
            ?num_ctx
            ?repeat_penalty
            ?repeat_last_n
            ?return_progress
            ?connect_timeout_s:provider.connect_timeout_s
            ?max_concurrent_requests
            ?max_request_body_bytes
            ?max_tokens
            ())
     | Error reason -> Error reason)
;;

(* --- binding → Provider_config.t ---

   Replaces the deleted [resolve_binding_config]/[binding_to_provider_config]
   pair. The typed [adapter_error] list is collapsed into [(_, string) result]
   strings; the override carrier is dropped (see above). *)
let binding_to_provider_config (cfg : Runtime_schema.config) (binding : Runtime_schema.binding)
    : (Llm_provider.Provider_config.t, string) result =
  match Runtime_schema.model_of_id cfg binding.model_id with
  | None -> Error (Printf.sprintf "model not found: %s" binding.model_id)
  | Some spec ->
    (match Runtime_schema.provider_of_id cfg binding.provider_id with
     | None -> Error (Printf.sprintf "provider not found: %s" binding.provider_id)
     | Some provider ->
       (* [provider_config_from_declared_provider] already returns the concrete
          reason (e.g. "provider ... uses protocol messages-http, which the
          runtime adapter cannot build a provider_config for ..."); propagate it
          verbatim instead of collapsing to a generic "resolution failed" that
          hid which provider/protocol was unmapped. *)
       provider_config_from_declared_provider
         ?keep_alive:binding.keep_alive
         ?num_ctx:binding.num_ctx
         ?repeat_penalty:binding.repeat_penalty
         ?repeat_last_n:binding.repeat_last_n
         ?return_progress:binding.return_progress
         ?max_concurrent_requests:binding.max_concurrent
         ?max_request_body_bytes:binding.max_request_body_bytes
         ?max_tokens:binding.max_tokens
         provider
         spec)
;;

let codex_app_server_execution (provider : Runtime_schema.provider)
    (spec : Runtime_schema.model_spec) : (Runtime_execution.t, string) result =
  match provider.transport with
  | Http _ ->
    Error
      (Printf.sprintf
         "provider %S uses protocol codex-app-server but declares an HTTP endpoint; \
          an official Codex CLI command is required"
         provider.id)
  | Cli command when String.trim command = "" ->
    Error (Printf.sprintf "provider %S declares an empty Codex CLI command" provider.id)
  | Cli command ->
    (match provider.credentials with
     | Some _ ->
       Error
         (Printf.sprintf
            "provider %S uses codex-app-server and must not declare credentials; \
             the official Codex client owns subscription login"
            provider.id)
     | None when not provider.is_non_interactive ->
       Error
         (Printf.sprintf
            "provider %S uses codex-app-server and must declare \
             is-non-interactive = true"
            provider.id)
     | None ->
       Ok
         (Runtime_execution.Codex_app_server
            { cli_path = command
            ; model = Some spec.api_name
            ; timeout_s = Runtime_codex_app_server.default_timeout_s
            }))
;;

let runtime_antigravity_effort = function
  | Runtime_schema.Antigravity_low -> Runtime_antigravity.Low
  | Runtime_schema.Antigravity_medium -> Runtime_antigravity.Medium
  | Runtime_schema.Antigravity_high -> Runtime_antigravity.High
;;

let antigravity_cli_execution (provider : Runtime_schema.provider)
    (spec : Runtime_schema.model_spec) : (Runtime_execution.t, string) result =
  match provider.transport with
  | Http _ ->
    Error
      (Printf.sprintf
         "provider %S uses protocol antigravity-cli but declares an HTTP endpoint; \
          an official Antigravity CLI command is required"
         provider.id)
  | Cli command when String.trim command = "" ->
    Error
      (Printf.sprintf
         "provider %S declares an empty Antigravity CLI command"
         provider.id)
  | Cli command ->
    (match provider.credentials, provider.antigravity_cli with
     | None, _ ->
       Error
         (Printf.sprintf
            "provider %S uses antigravity-cli and requires a file credential \
             naming the operator-owned OAuth source"
            provider.id)
     | Some (Env _ | Inline _), _ ->
       Error
         (Printf.sprintf
            "provider %S uses antigravity-cli and accepts only a file credential; \
             OAuth token material must stay outside runtime.toml"
            provider.id)
     | Some (File oauth_source), _ when Filename.is_relative oauth_source ->
       Error
         (Printf.sprintf
            "provider %S uses antigravity-cli with a relative OAuth source %S; \
             the file credential path must be absolute"
            provider.id
            oauth_source)
     | Some (File _), _ when not provider.is_non_interactive ->
       Error
         (Printf.sprintf
            "provider %S uses antigravity-cli and must declare \
             is-non-interactive = true"
            provider.id)
     | Some (File _), None ->
       Error
         (Printf.sprintf
            "provider %S uses antigravity-cli without typed Antigravity options"
            provider.id)
     | Some (File oauth_source), Some options ->
       Ok
         (Runtime_execution.Antigravity_cli
            { cli_path = command
            ; model = spec.api_name
            ; agent = options.agent
            ; effort = Option.map runtime_antigravity_effort options.effort
            ; oauth_source
            ; timeout_s = options.timeout_s
            ; add_dirs = options.add_dirs
            }))
;;

let claude_code_execution (provider : Runtime_schema.provider)
    (spec : Runtime_schema.model_spec) : (Runtime_execution.t, string) result =
  match provider.transport with
  | Http _ ->
    Error
      (Printf.sprintf
         "provider %S uses protocol claude-code but declares an HTTP endpoint; \
          an official Claude Code CLI command is required"
         provider.id)
  | Cli command when String.trim command = "" ->
    Error
      (Printf.sprintf
         "provider %S declares an empty Claude Code CLI command"
         provider.id)
  | Cli command ->
    (match provider.credentials with
     | Some _ ->
       Error
         (Printf.sprintf
            "provider %S uses claude-code and must not declare credentials; \
             the official Claude Code client owns subscription login"
            provider.id)
     | None when not provider.is_non_interactive ->
       Error
         (Printf.sprintf
            "provider %S uses claude-code and must declare \
             is-non-interactive = true"
            provider.id)
     | None ->
       Ok
         (Runtime_execution.Claude_code
            { cli_path = command
            ; model = Some spec.api_name
            ; timeout_s = Runtime_claude_code.default_timeout_s
            }))
;;

let binding_to_execution (cfg : Runtime_schema.config) (binding : Runtime_schema.binding)
    : (Runtime_execution.t, string) result =
  match Runtime_schema.model_of_id cfg binding.model_id with
  | None -> Error (Printf.sprintf "model not found: %s" binding.model_id)
  | Some spec ->
    (match Runtime_schema.provider_of_id cfg binding.provider_id with
     | None -> Error (Printf.sprintf "provider not found: %s" binding.provider_id)
     | Some provider ->
       (match provider.api_format with
        | Runtime_schema.Codex_app_server_runtime ->
          codex_app_server_execution provider spec
        | Runtime_schema.Antigravity_cli_runtime ->
          antigravity_cli_execution provider spec
        | Runtime_schema.Claude_code_runtime ->
          claude_code_execution provider spec
        | Messages_api | Chat_completions_api | Ollama_api ->
          Result.map
            (fun provider_config -> Runtime_execution.Agent_core provider_config)
            (binding_to_provider_config cfg binding)))
;;
