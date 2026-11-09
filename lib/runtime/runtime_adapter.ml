(** Single-binding → [Provider_config.t] materialization (RFC-0206 §5).

    Covers only the binding materialization path:

    - TOML provider.id -> declared provider metadata (via {!Runtime_schema})
    - provider metadata + model spec -> {!Llm_provider.Provider_config.t}

    Routing (aliases / routes / system_targets / capability profiles /
    strategy mapping) and the typed [adapter_error] aggregate are dropped: a
    Runtime is one pre-selected binding. Errors are surfaced as
    [(_, string) result] so the caller fails fast (no silent fallback).

    Provider header defaults are owned by {!Runtime_provider_binding}; this
    adapter owns only binding materialization and custom-header filtering.

    @stability Internal *)

module Declarations = Llm_provider.Catalog_snapshot
module Provider_binding = Runtime_provider_binding

type construction = Declarations.t Lazy.Mutexed.t

let create_construction () =
  (* Snapshot selection only reads the atomic publication or admits the
     embedded source; it performs no I/O or fiber suspension. Mutexed lazy
     selects once across domains and also works outside Eio. Credential I/O
     happens after forcing, without holding this initialization lock. *)
  Lazy.Mutexed.from_fun Declarations.current
;;

type provider_materialization =
  { provider_config : Llm_provider.Provider_config.t
  ; credential_admission : Runtime_credential_selection.admission
  }

type execution_materialization =
  { execution : Runtime_execution.t
  ; credential_admission : Runtime_credential_selection.admission option
  }

(* --- Header and request-path helpers --- *)

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

let materialize_credentials_from_declaration ~provider_id ~declaration ~credential =
  let requires_api_key = Option.map
    (fun (entry : Declarations.entry) -> Declarations.requires_api_key entry.authentication)
    declaration in
  Runtime_credential_selection.materialize ~provider_id ~requires_api_key ~credential
;;

let materialize_credentials ~provider_id ~credential =
  let declarations = Declarations.current () in
  materialize_credentials_from_declaration ~provider_id
    ~declaration:(Declarations.find declarations provider_id) ~credential
;;

let declared_provider_kind = function
  | Some entry -> Some entry.Declarations.kind
  | None -> None
;;

(* The catalog answers for a provider it has a row for; a deployment's [kind]
   answers only for an endpoint it does not. Preferring the registry keeps the
   catalog the single authority, so a restated kind is dead weight rather than
   a rival — and the loader refuses it outright. *)
let effective_provider_kind ?declaration (provider : Runtime_schema.provider) =
  match declared_provider_kind declaration with
  | Some _ as kind -> kind
  | None -> provider.Runtime_schema.wire_kind
;;

let messages_api_compatible_provider_kind = function
  | Llm_provider.Provider_config.Anthropic | Llm_provider.Provider_config.Kimi -> true
  | Llm_provider.Provider_config.OpenAI_compat
  | Llm_provider.Provider_config.Ollama
  | Llm_provider.Provider_config.Gemini
  | Llm_provider.Provider_config.Glm -> false
;;

(* A declared [kind] that nobody reads is worse than one that is missing: the
   operator believes they set the dialect and the deployment quietly uses
   another. So every position where the value cannot be read refuses it instead
   of ignoring it — the catalog already answering, the protocol already fixing
   the dialect, or the provider not being an HTTP one at all. *)
let refuse_unread_declaration ~key ~value ~reason (provider : Runtime_schema.provider) =
  match value with
  | None -> Ok ()
  | Some value ->
    Error
      (Printf.sprintf
         "provider %S declares %s %S, but %s"
         provider.id
         key
         value
         reason)
;;

let refuse_unread_wire_kind ~reason (provider : Runtime_schema.provider) =
  refuse_unread_declaration
    provider
    ~key:"kind"
    ~value:
      (Option.map
         Llm_provider.Provider_config.string_of_provider_kind
         provider.Runtime_schema.wire_kind)
    ~reason
;;

let provider_kind_for_http_provider ?declaration (provider : Runtime_schema.provider)
    : (Llm_provider.Provider_config.provider_kind, string) result =
  let open Result.Syntax in
  let* () =
    match provider.api_format, declared_provider_kind declaration with
    | ( Codex_app_server_runtime
      | Claude_code_runtime
      | Antigravity_cli_runtime
      | Muse_serve_runtime
      | Vibe_cli_runtime ), _ ->
      refuse_unread_wire_kind
        provider
        ~reason:"an official client speaks no HTTP dialect"
    | (Gemini_api | Vertex_gemini_api | Ollama_api), _ ->
      refuse_unread_wire_kind
        provider
        ~reason:
          (Printf.sprintf "protocol %s already fixes the dialect" provider.protocol)
    | (Chat_completions_api | Messages_api), Some _ ->
      refuse_unread_wire_kind
        provider
        ~reason:"the AGENT_CORE catalog has a row for it and owns that fact"
    | (Chat_completions_api | Messages_api), None -> Ok ()
  in
  match provider.api_format with
  | Codex_app_server_runtime | Claude_code_runtime | Antigravity_cli_runtime
  | Muse_serve_runtime | Vibe_cli_runtime ->
    Error
      (Printf.sprintf
         "provider %S uses official CLI protocol %s and cannot be materialized as an \
          HTTP provider"
         provider.id
         provider.protocol)
  | Gemini_api | Vertex_gemini_api -> Ok Llm_provider.Provider_config.Gemini
  | Ollama_api -> Ok Llm_provider.Provider_config.Ollama
  | Chat_completions_api ->
    (* Chat-completions keeps the historical OpenAI-compatible fallback when
       registry metadata is absent. Messages API deliberately fails closed
       below because there is no safe Anthropic-style default. *)
    Ok
      (match effective_provider_kind ?declaration provider with
       | Some Llm_provider.Provider_config.Ollama ->
         Llm_provider.Provider_config.OpenAI_compat
       | Some
           (( Llm_provider.Provider_kind.Anthropic
            | Llm_provider.Provider_kind.Kimi
            | Llm_provider.Provider_kind.OpenAI_compat
            | Llm_provider.Provider_kind.Gemini
            | Llm_provider.Provider_kind.Glm ) as kind) -> kind
       | None -> Llm_provider.Provider_config.OpenAI_compat)
  | Messages_api ->
    (match effective_provider_kind ?declaration provider with
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
            "provider %S uses protocol %s, but neither an AGENT_CORE provider \
             registry entry nor a declared kind exists; messages-http has no \
             safe default dialect, so an endpoint the catalog does not know \
             must declare kind = \"anthropic\" or kind = \"kimi\""
            provider.id
            provider.protocol))
;;

(* [provider_kind] has no equality in agent core and every variant is
   constant, so this is a total match rather than [=]: adding a variant makes
   the compiler ask about it here instead of silently answering false. *)
let same_provider_kind left right =
  let open Llm_provider.Provider_config in
  match (left : provider_kind), (right : provider_kind) with
  | Anthropic, Anthropic
  | Kimi, Kimi
  | OpenAI_compat, OpenAI_compat
  | Ollama, Ollama
  | Gemini, Gemini
  | Glm, Glm -> true
  | (Anthropic | Kimi | OpenAI_compat | Ollama | Gemini | Glm), _ -> false
;;

let normalize_http_request_path ~kind ~base_url ~request_path =
  match kind with
  | Llm_provider.Provider_config.OpenAI_compat ->
    normalize_openai_compat_request_path ~base_url ~request_path
  | Llm_provider.Provider_kind.Anthropic
  | Llm_provider.Provider_kind.Kimi
  | Llm_provider.Provider_kind.Ollama
  | Llm_provider.Provider_kind.Gemini
  | Llm_provider.Provider_kind.Glm -> request_path

let default_http_request_path ~kind ~base_url =
  let request_path = match kind with
    | Llm_provider.Provider_config.OpenAI_compat -> Masc_network_defaults.chat_completions_path
    | Llm_provider.Provider_kind.Anthropic
    | Llm_provider.Provider_kind.Kimi
    | Llm_provider.Provider_kind.Ollama
    | Llm_provider.Provider_kind.Gemini
    | Llm_provider.Provider_kind.Glm ->
      Llm_provider.Provider_kind.request_path_default kind in
  normalize_http_request_path ~kind ~base_url ~request_path

let request_path_for_http_provider ~(provider : Runtime_schema.provider) ~declaration ~kind
    ~base_url =
  (* The admitted declaration carries its request_path. A provider whose row names a
     different surface (deepseek-responses -> "/responses") must not have the
     protocol default stamped over it, so a declared path wins over
     the Chat-completions default.

     It wins only for the kind that path belongs to. A catalog row can serve
     more than one surface — ollama_cloud declares
     [identity_kinds = ["ollama"; "openai_compat"]] — while carrying a single
     [request_path], and that path names its own kind's surface ("/api/chat",
     the native Ollama one). A workspace that reaches the same provider over
     the OpenAI-compatible surface selects [OpenAI_compat] here, and stamping
     the native path on it built https://ollama.com/v1/api/chat: 794 requests
     404'd across five keepers on 2026-09-06, two of them 30 cycles deep
     (#33652). Comparing kinds keeps deepseek-responses working — its catalog
     row is OpenAI_compat and so is the runtime that names it — without
     matching on the path text.

     Providers absent from the catalog keep the protocol default exactly as
     before: no catalog row means no separate surface to name. *)
  let request_path = match provider.request_path with
    | Some path -> path
    | None -> match declaration with
    | Some entry
      when same_provider_kind
             entry.Declarations.kind
             kind
           && not
                (String.equal
                   entry.Declarations.request_path
                   "") ->
      entry.Declarations.request_path
    | _ ->
      (match provider.api_format, kind with
       | Runtime_schema.Chat_completions_api, Llm_provider.Provider_config.OpenAI_compat ->
         Masc_network_defaults.chat_completions_path
       | Runtime_schema.Chat_completions_api,
         ( Llm_provider.Provider_kind.Anthropic
         | Llm_provider.Provider_kind.Kimi
         | Llm_provider.Provider_kind.Ollama
         | Llm_provider.Provider_kind.Gemini
         | Llm_provider.Provider_kind.Glm )
       | ( ( Runtime_schema.Messages_api
           | Runtime_schema.Ollama_api
           | Runtime_schema.Gemini_api
           | Runtime_schema.Vertex_gemini_api
           | Runtime_schema.Codex_app_server_runtime
           | Runtime_schema.Antigravity_cli_runtime
           | Runtime_schema.Claude_code_runtime
           | Runtime_schema.Muse_serve_runtime
           | Runtime_schema.Vibe_cli_runtime ),
           ( Llm_provider.Provider_kind.Anthropic
           | Llm_provider.Provider_kind.Kimi
           | Llm_provider.Provider_kind.OpenAI_compat
           | Llm_provider.Provider_kind.Ollama
           | Llm_provider.Provider_kind.Gemini
           | Llm_provider.Provider_kind.Glm ) ) ->
         (match declaration with
          | Some entry -> entry.Declarations.request_path
          | None -> Llm_provider.Provider_kind.request_path_default kind))
  in
  normalize_http_request_path ~kind ~base_url ~request_path
;;

(* --- Model capability projection --- *)

let http_protocol_metadata provider =
  match provider.Runtime_schema.transport with
  | Cli _ -> Error "An HTTP connection is required"
  | Http base_url ->
    let declarations = Declarations.current () in
    let declaration = Declarations.find declarations provider.id in
    Result.map (fun kind -> kind,
      request_path_for_http_provider ~provider ~declaration ~kind ~base_url)
      (provider_kind_for_http_provider ?declaration provider)
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
  | Runtime_schema.Reasoning_effort_default_on ->
    Llm_provider.Capabilities.Reasoning_effort_default_on
  | Runtime_schema.Reasoning_enabled -> Llm_provider.Capabilities.Reasoning_enabled
;;

(* Every value a runtime capability block states, laid over [base]. [None]
   means the block stated nothing, so [base] decides — what a
   [false]-defaulted bool could not deliver (#37435). [tools-support] and
   [streaming] are plain bools, not options: the parser fills an unwritten
   one with [false] and [true], so they always carry a value and override
   [base] whether the model table writes them or not. *)
let stated_capabilities_over
      ~(base : Llm_provider.Capabilities.capabilities)
      (spec : Runtime_schema.model_spec)
      (caps : Runtime_schema.model_capabilities)
  : Llm_provider.Capabilities.capabilities
  =
  let stated field ~default = Option.value field ~default in
  (* Media input stays fail-closed: MASC's model spec is the SSOT for
     it ([Runtime_agent.apply_runtime_model_input_capabilities]), so an
     unwritten media flag is [false], never the base's value. Absence
     is the answer here, not a stand-in for a value that went missing:
     the operator did not grant the modality. *)
  (* DET-OK: the default is the contract. *)
  let media field = Option.value field ~default:false in
  { base with
    supports_tools = spec.tools_support
  ; supports_tool_choice = stated caps.supports_tool_choice ~default:base.supports_tool_choice
  ; supports_required_tool_choice = stated caps.supports_required_tool_choice ~default:base.supports_required_tool_choice
  ; supports_named_tool_choice = stated caps.supports_named_tool_choice ~default:base.supports_named_tool_choice
  ; supports_parallel_tool_calls = stated caps.supports_parallel_tool_calls ~default:base.supports_parallel_tool_calls
  (* DET-OK: absent policy retains the existing provider default capability
     for this uncataloged model; it does not synthesize enable_thinking. *)
  ; supports_reasoning = Option.value spec.thinking_support ~default:base.supports_reasoning
  ; accepted_reasoning_efforts =
      (match caps.accepted_reasoning_efforts with
       | Some _ as declared -> declared
       | None -> base.accepted_reasoning_efforts)
  ; reasoning_streaming_format =
      Option.value
        caps.reasoning_streaming_format
        ~default:base.reasoning_streaming_format
  ; supports_response_format_json = stated caps.supports_response_format_json ~default:base.supports_response_format_json
  ; supports_structured_output = stated caps.supports_structured_output ~default:base.supports_structured_output
  ; supports_multimodal_inputs = media caps.supports_multimodal_inputs
  ; supports_image_input = media caps.supports_image_input
  ; supports_audio_input = media caps.supports_audio_input
  ; supports_video_input = media caps.supports_video_input
  ; supports_native_streaming = spec.streaming
  ; supports_system_prompt = stated caps.supports_system_prompt ~default:base.supports_system_prompt
  ; supports_assistant_prefill = stated caps.supports_assistant_prefill ~default:base.supports_assistant_prefill
  ; supports_prompt_caching = stated caps.supports_prompt_caching ~default:base.supports_prompt_caching
  ; supports_top_k = stated caps.supports_top_k ~default:base.supports_top_k
  ; supports_min_p = stated caps.supports_min_p ~default:base.supports_min_p
  ; supports_seed = stated caps.supports_seed ~default:base.supports_seed
  ; emits_usage_tokens = stated caps.emits_usage_tokens ~default:base.emits_usage_tokens
  }
;;

(** A runtime [api-name] is an opaque deployment string, not automatically an
    AGENT_CORE catalog model. When no model row answers for the provider/model
    pair, project the complete typed runtime declaration into the
    Provider_config override that AGENT_CORE exposes for concrete endpoint
    contracts. Catalogued models preserve the row except for explicit output
    ceilings and thinking transport declarations. An absent runtime capability
    block remains absent: a provider preset then answers alone, and with no
    catalog answer at all the normal startup gate rejects the binding. *)
let declared_capabilities_override_of_model_spec
      ~(wire : Llm_provider.Provider_kind.t)
      ~(catalog_answer : Llm_provider.Capabilities.catalog_answer)
      (spec : Runtime_schema.model_spec)
  =
  match catalog_answer with
  | Llm_provider.Capabilities.Model_row catalog_caps ->
    (match spec.capabilities with
     | None -> None
     | Some runtime_caps ->
       (match
          runtime_caps.declared_thinking_control_format,
          runtime_caps.reasoning_streaming_format,
          runtime_caps.max_output_tokens,
          runtime_caps.accepted_reasoning_efforts
        with
        | None, None, None, None -> None
        | thinking_control_format, reasoning_streaming_format, max_output_tokens,
          accepted_reasoning_efforts ->
          Some
            { catalog_caps with
              max_output_tokens =
                (match max_output_tokens with
                 | Some _ -> max_output_tokens
                 | None -> catalog_caps.max_output_tokens)
            ; thinking_control_format =
                (match thinking_control_format with
                 | Some format -> agent_core_thinking_control_format format
                 | None -> catalog_caps.thinking_control_format)
            ; accepted_reasoning_efforts =
                (match accepted_reasoning_efforts with
                 | Some _ -> accepted_reasoning_efforts
                 | None -> catalog_caps.accepted_reasoning_efforts)
            ; reasoning_streaming_format =
                Option.value
                  reasoning_streaming_format
                  ~default:catalog_caps.reasoning_streaming_format
            }))
  | Llm_provider.Capabilities.Provider_preset preset ->
    (* The preset speaks for every model of its provider and knows nothing of
       this one, so it is only the base: the block's window, output ceiling
       and thinking control override it as well, and an unstated value keeps
       the preset's. [tools-support] and [streaming] are never unstated: the
       parser fills them with [false] and [true], so they override the preset
       even when the model table does not write them. *)
    Option.map
      (fun (caps : Runtime_schema.model_capabilities) ->
         { (stated_capabilities_over ~base:preset spec caps) with
           max_context_tokens =
             (match spec.max_context with
              | Some _ as declared -> declared
              | None -> preset.max_context_tokens)
         ; max_output_tokens =
             (match caps.max_output_tokens with
              | Some _ as declared -> declared
              | None -> preset.max_output_tokens)
         ; thinking_control_format =
             (match caps.declared_thinking_control_format with
              | Some format -> agent_core_thinking_control_format format
              | None -> preset.thinking_control_format)
         })
      spec.capabilities
  | Llm_provider.Capabilities.No_catalog_answer ->
    Option.map
      (fun (caps : Runtime_schema.model_capabilities) ->
         (* The wire's own preset, not the bare defaults: an uncatalogued model
            still runs on a known dialect, and that dialect decides the fields
            no runtime block states (tool content shape, output budget field,
            reasoning replay). Fields the block does state override it. *)
         let base = Llm_provider.Capabilities.capabilities_of_kind wire in
         { (stated_capabilities_over ~base spec caps) with
           max_context_tokens = spec.max_context
         ; max_output_tokens = caps.max_output_tokens
         ; thinking_control_format =
             agent_core_thinking_control_format caps.thinking_control_format
         })
      spec.capabilities
;;

(* A signed Anthropic thinking block stays valid only while the system prompt,
   the tools and every message before it are unchanged on later requests; a
   replayed block that no longer matches fails the whole request with a 400
   that a retry cannot clear. The history a Keeper sends is not append-only: it
   is windowed to a carried range, aged tool results are demoted to markers, and
   a per-turn context is injected. Only the latest user turn's tool loop, whose
   history is fixed for the attempt, may carry reasoning back. A capability row
   that states its own replay stays authoritative. *)
let with_client_history_replay
      ~(wire : Llm_provider.Provider_kind.t)
      ~(catalog_capabilities : Llm_provider.Capabilities.capabilities option)
      (declared : Llm_provider.Capabilities.capabilities option)
  =
  match wire with
  | Llm_provider.Provider_kind.Anthropic ->
    let capabilities =
      match declared with
      | Some _ as found -> found
      | None -> catalog_capabilities
    in
    (match capabilities with
     | Some
         ({ Llm_provider.Capabilities.reasoning_replay_override =
              (Llm_provider.Capabilities.Default_reasoning_replay
               | Llm_provider.Capabilities.Force_preserve_responses_text)
          ; _
          } as caps) ->
       Some
         { caps with
           Llm_provider.Capabilities.reasoning_replay_override =
             Llm_provider.Capabilities.Force_latest_user_turn_tool_calls
         }
     | Some
         { Llm_provider.Capabilities.reasoning_replay_override =
             ( Llm_provider.Capabilities.Force_no_replay
             | Llm_provider.Capabilities.Force_drop_without_tool_preserve_with_tool
             | Llm_provider.Capabilities.Force_latest_user_turn_tool_calls
             | Llm_provider.Capabilities.Force_initial_system_latest_user_turn_tool_calls
             | Llm_provider.Capabilities.Force_preserve_always
             | Llm_provider.Capabilities.Force_turn_scoped_system_context_preserve_always
             | Llm_provider.Capabilities.Force_preserve_with_request_tools )
         ; _
         }
     | None -> declared)
  | Llm_provider.Provider_kind.Kimi
  | Llm_provider.Provider_kind.OpenAI_compat
  | Llm_provider.Provider_kind.Ollama
  | Llm_provider.Provider_kind.Gemini
  | Llm_provider.Provider_kind.Glm -> declared
;;

let model_capabilities_override_of_model_spec
      ~(wire : Llm_provider.Provider_kind.t)
      ~request_policy
      (spec : Runtime_schema.model_spec)
  =
  declared_capabilities_override_of_model_spec
    ~wire
    ~catalog_answer:(Llm_provider.Capabilities.request_policy_catalog_answer request_policy)
    spec
  |> with_client_history_replay
       ~wire
       ~catalog_capabilities:(Llm_provider.Capabilities.request_policy_capabilities request_policy)
;;

(* A deployment-declared Anthropic thinking-control policy is read only where
   the catalog answers no policy: an operator-own endpoint with no readable
   row, or a row that carries no policy. Anywhere else the declaration is
   either unread (a non-Anthropic wire never consults it) or a rival
   restatement of a catalog row, and the loader refuses it instead of ignoring
   it ([refuse_unread_declaration] above works the same way for [kind]). The
   catalog check uses the same immutable policy as the resulting request;
   credential I/O cannot change which authority answered the declaration. *)
let anthropic_thinking_control_override_of_model_spec
      ~(wire : Llm_provider.Provider_kind.t)
      ~(provider_id : string)
      ~request_policy
      (spec : Runtime_schema.model_spec)
  : (Llm_provider.Capabilities.anthropic_thinking_control option, string) result
  =
  let declared =
    Option.bind spec.Runtime_schema.capabilities (fun caps ->
      caps.Runtime_schema.anthropic_thinking_control)
  in
  match declared with
  | None -> Ok None
  | Some _ as policy ->
    (match wire with
     | Llm_provider.Provider_kind.Anthropic ->
       (match
          Llm_provider.Capabilities.request_policy_anthropic_thinking_control request_policy
        with
        | Some _ ->
          Error
            (Printf.sprintf
               "binding %s.%s declares anthropic-thinking-control, but the AGENT_CORE \
                catalog already declares a policy for model %S on provider %S; remove \
                the deployment restatement"
               provider_id
               spec.Runtime_schema.id
               spec.Runtime_schema.api_name
               provider_id)
        | None -> Ok policy)
     | Llm_provider.Provider_kind.Kimi
     | Llm_provider.Provider_kind.OpenAI_compat
     | Llm_provider.Provider_kind.Ollama
     | Llm_provider.Provider_kind.Gemini
     | Llm_provider.Provider_kind.Glm ->
       Error
         (Printf.sprintf
            "binding %s.%s declares anthropic-thinking-control, but only the Anthropic \
             wire reads it (this binding resolves to %s)"
            provider_id
            spec.Runtime_schema.id
            (Llm_provider.Provider_kind.to_string wire)))
;;

(* The window handed to AGENT_CORE is MASC's effective window, not the raw
   runtime.toml override (#36540). Keeper turns are budgeted with the override
   clamped by the capability catalog cap
   ([Runtime_instance.resolve_max_context_of_runtime]), and AGENT_CORE's
   [Provider_config.context_window] — exact-fit admission and response
   telemetry — reads [config.max_context] verbatim when set. Passing the raw
   override sized those paths against a window the keeper budget never
   admitted. The capability cap is resolved exactly as
   [Provider_config.capabilities_for_config_model] will resolve it for the
   built config: the computed override when present, otherwise the catalog
   row for the same wire/provider/model triple. *)
let effective_max_context_of_model_spec
      ~(catalog_capabilities : Llm_provider.Capabilities.capabilities option)
      ~(model_capabilities_override : Llm_provider.Capabilities.capabilities option)
      (spec : Runtime_schema.model_spec)
  =
  match spec.max_context with
  | None -> None
  | Some declared ->
    let capability_cap =
      let capabilities =
        match model_capabilities_override with
        | Some _ as found -> found
        | None -> catalog_capabilities
      in
      match capabilities with
      | Some caps ->
        (match caps.max_context_tokens with
         | Some cap when cap > 0 -> Some cap
         | Some _ | None -> None)
      | None -> None
    in
    (match capability_cap with
     | Some cap when declared > cap -> Some cap
     | Some _ | None -> Some declared)
;;

(* --- provider × model spec → Provider_config.t --- *)
let validate_parallel_tool_policy (provider : Runtime_schema.provider)
    ~(model_id : string) ~supports_parallel_tool_suppression ~disable_parallel_tool_use =
  match provider.api_format, disable_parallel_tool_use with
  | (Runtime_schema.Codex_app_server_runtime | Antigravity_cli_runtime
    | Claude_code_runtime | Muse_serve_runtime | Vibe_cli_runtime | Ollama_api
    | Gemini_api | Vertex_gemini_api), true ->
    Error
      (Printf.sprintf
         "binding %s.%s declares disable-parallel-tool-use = true, but \
          protocol %s cannot carry that request policy"
         provider.id model_id provider.protocol)
  | (Messages_api | Chat_completions_api), true ->
    (match supports_parallel_tool_suppression with
     | true -> Ok ()
     | false ->
       Error
         (Printf.sprintf
            "binding %s.%s declares disable-parallel-tool-use = true, but provider %S has no catalog-declared parallel tool suppression contract"
            provider.id model_id provider.id))
  | (Messages_api | Chat_completions_api), false
  | (Codex_app_server_runtime | Antigravity_cli_runtime | Claude_code_runtime
    | Muse_serve_runtime | Vibe_cli_runtime | Ollama_api | Gemini_api
    | Vertex_gemini_api), false -> Ok ()
;;

let provider_config_from_declared_provider ?binding_max_context ?keep_alive ?num_ctx ?repeat_penalty
    ?max_tokens
    ?repeat_last_n ?return_progress
    ?max_concurrent_requests
    ~declarations
    ~disable_parallel_tool_use
    (provider : Runtime_schema.provider) (spec : Runtime_schema.model_spec)
  : (provider_materialization, string) result =
  (* Resolve deployment scope before synthesizing custom-model capabilities:
     their max_context is this declaration, not a second independent hard cap.
     Known catalog rows remain unchanged and still clamp the selected value. *)
  let max_context = match binding_max_context, provider.max_context with
    | Some tokens, _ | None, Some tokens -> Some tokens
    | None, None -> spec.max_context in
  let spec = { spec with max_context } in
  (* The provider's run limit orders the queue for its permits. A binding
     without [max-concurrent] runs outside that queue, so it carries no run
     limit; runtime_toml refuses a run limit that no binding can use. *)
  let admission_priority_run_limit =
    match max_concurrent_requests with
    | Some _ -> provider.admission_priority_run_limit
    | None -> None
  in
  let open Result.Syntax in
  let* () = validate_parallel_tool_policy provider ~model_id:spec.id
      ~supports_parallel_tool_suppression:(Declarations.supports_parallel_tool_suppression
        declarations ~provider_id:provider.id)
      ~disable_parallel_tool_use in
  let declaration = Declarations.find declarations provider.id in
  match provider.transport with
  | Http base_url ->
    let base_url = Masc_network_defaults.normalize_loopback_base_url base_url in
    let open Result.Syntax in
    let* auth_scheme, credential_source =
      match provider.api_format with
      | Vertex_gemini_api ->
        let* _ = Llm_provider.Vertex_endpoint.parse_base_url base_url in
        (match provider.credentials with
         | Some _ -> Error "vertex-gemini uses Google Application Default Credentials, not a saved API key"
         | None -> Ok (Llm_provider.Provider_config.Bearer_token, Runtime_google_adc.credential_source ()))
      | Messages_api | Chat_completions_api | Ollama_api | Gemini_api
      | Codex_app_server_runtime | Claude_code_runtime | Antigravity_cli_runtime
      | Muse_serve_runtime | Vibe_cli_runtime ->
        Ok (Llm_provider.Provider_config.Provider_default, Llm_provider.Provider_config.Static_credential)
    in
    (match provider_kind_for_http_provider ?declaration provider with
     | Ok kind ->
       let request_policy = Llm_provider.Capabilities.resolve_snapshot_request_policy ~snapshot:declarations ~wire:kind
           ~provider_id:provider.id ~model_id:spec.api_name in
       let catalog_capabilities =
         Llm_provider.Capabilities.request_policy_capabilities request_policy in
       let model_capabilities_override =
         model_capabilities_override_of_model_spec
           ~wire:kind
           ~request_policy
           spec
       in
       let* model_anthropic_thinking_control_override =
         anthropic_thinking_control_override_of_model_spec
           ~wire:kind
           ~provider_id:provider.id
           ~request_policy
           spec
       in
       let max_context =
         effective_max_context_of_model_spec
           ~catalog_capabilities
           ~model_capabilities_override
           spec
       in
       let request_path =
         request_path_for_http_provider ~provider ~declaration ~kind ~base_url
       in
       let* credential = materialize_credentials_from_declaration ~provider_id:provider.id
           ~declaration ~credential:provider.credentials in
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
       let provider_config =
         Llm_provider.Provider_config.make
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
            ~api_key:(credential.api_key :> string)
            ~auth_scheme
            ~credential_source
            ~headers
            ~request_path
            ~disable_parallel_tool_use
            ?max_context
            ?model_capabilities_override
            ?model_anthropic_thinking_control_override
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
            (* Paired with the effort above: on a wire that turns reasoning on when the
               request carries no control, one of the two has to be said. This is the
               row saying it rides the provider default on purpose. *)
            ~reasoning_uncontrolled:spec.reasoning_uncontrolled
            ?keep_alive
            ?num_ctx
            ?repeat_penalty
            ?repeat_last_n
            ?return_progress
            ?connect_timeout_s:provider.connect_timeout_s
            ?max_concurrent_requests
            ?admission_priority_run_limit
            ?max_tokens
            ()
       |> Llm_provider.Provider_config.with_request_policy request_policy
       in
       Ok {provider_config;credential_admission=credential.admission}
     | Error reason -> Error reason)
  | Cli _ ->
    Error (Printf.sprintf
      "provider %S uses protocol %s over a CLI transport; an HTTP binding is required"
      provider.id provider.protocol)
;;

(* Materialize the exact HTTP binding and its credential authority together. *)
let materialize_provider_binding ~construction (cfg : Runtime_schema.config) (binding : Runtime_schema.binding)
    : (provider_materialization, string) result =
  match Runtime_schema.model_of_id cfg binding.model_id with
  | None -> Error (Printf.sprintf "model not found: %s" binding.model_id)
  | Some spec ->
    (match Runtime_schema.provider_of_id cfg binding.provider_id with
     | None -> Error (Printf.sprintf "provider not found: %s" binding.provider_id)
     | Some provider ->
       let declarations = Lazy.Mutexed.force construction in
       (* [provider_config_from_declared_provider] already returns the concrete
          reason (e.g. "provider ... uses protocol messages-http, which the
          runtime adapter cannot build a provider_config for ..."); propagate it
          verbatim instead of collapsing to a generic "resolution failed" that
          hid which provider/protocol was unmapped. *)
       provider_config_from_declared_provider
         ~declarations
         ?binding_max_context:binding.max_context
         ?keep_alive:binding.keep_alive
         ?num_ctx:binding.num_ctx
         ?repeat_penalty:binding.repeat_penalty
         ?repeat_last_n:binding.repeat_last_n
         ?return_progress:binding.return_progress
         ?max_concurrent_requests:binding.max_concurrent
         ~disable_parallel_tool_use:binding.disable_parallel_tool_use
         ?max_tokens:binding.max_tokens
         provider
         spec)
;;

(* The official-client executions spawn the path
   {!Runtime_official_cli_install.locate} finds for the configured command:
   on PATH as the shell finds it, else in the vendor installer's directory
   when the command is the client's own name. Found here, at materialization,
   for the seed's [command = "claude"] and the wizard's stored path alike; a
   client nowhere at that time is spawned as configured and the spawn names
   it. Before this the runtime spawned the configured name through PATH
   alone, so a shell without ~/.local/bin on PATH -- the one the installer was
   run from -- could pick the client in the wizard and then fail to start it
   (masc #37747). *)
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
       let open Result.Syntax in
       let* captured = Runtime_official_account.capture ~client:Codex ~declaration:provider.account_home in
       Ok
         (Runtime_execution.Codex_app_server
            { cli_path = Runtime_official_cli_install.spawn_path Codex ~command
            ; account_home = Runtime_account_access.seal captured
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
            { cli_path = Runtime_official_cli_install.spawn_path Antigravity ~command
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
       let open Result.Syntax in
       let* captured = Runtime_official_account.capture ~client:Claude_code ~declaration:provider.account_home in
       Ok
         (Runtime_execution.Claude_code
            { cli_path = Runtime_official_cli_install.spawn_path Claude ~command
            ; account_home = Runtime_account_access.seal captured
            ; model = Some spec.api_name
            ; timeout_s = Runtime_claude_code.default_timeout_s
            }))
;;

let muse_serve_execution (provider : Runtime_schema.provider)
    (spec : Runtime_schema.model_spec) : (Runtime_execution.t, string) result =
  match provider.transport with
  | Http _ ->
    Error
      (Printf.sprintf
         "provider %S uses protocol muse-serve but declares an HTTP endpoint; \
          the official Muse Code CLI command is required"
         provider.id)
  | Cli command when String.trim command = "" ->
    Error
      (Printf.sprintf
         "provider %S declares an empty Muse Code CLI command"
         provider.id)
  | Cli command ->
    (match provider.credentials with
     | Some _ ->
       Error
         (Printf.sprintf
            "provider %S uses muse-serve and must not declare credentials; \
             Muse Code owns its subscription login"
            provider.id)
     | None when not provider.is_non_interactive ->
       Error
         (Printf.sprintf
            "provider %S uses muse-serve and must declare \
             is-non-interactive = true"
            provider.id)
     | None ->
       let open Result.Syntax in
       let* account_home = match provider.account_home with
         | None -> Error (Printf.sprintf
             "provider %S uses muse-serve and requires an explicit account-home" provider.id)
         | Some home -> Runtime_account_access.declare_muse_home home in
       Ok
         (Runtime_execution.Muse_serve
            { cli_path = Runtime_official_cli_install.spawn_path Muse ~command
            ; account_home
            ; model = spec.api_name
            ; timeout_s = Runtime_muse_serve.default_timeout_s
            }))
;;

(* A Vibe call has no MASC time limit (owner decision), so a declared
   [turn-timeout-s] would be a deadline nothing enforces and is refused.
   Vibe reads the user's own config; the runtime's [command] is the only
   path MASC holds. *)
let vibe_cli_execution (provider : Runtime_schema.provider)
    (spec : Runtime_schema.model_spec) : (Runtime_execution.t, string) result =
  match provider.transport with
  | Http _ ->
    Error
      (Printf.sprintf
         "provider %S uses protocol vibe-cli but declares an HTTP endpoint; \
          the official Mistral Vibe CLI command is required"
         provider.id)
  | Cli command when String.trim command = "" ->
    Error
      (Printf.sprintf
         "provider %S declares an empty Mistral Vibe CLI command"
         provider.id)
  | Cli command ->
    (match provider.credentials, spec.reasoning_effort, spec.turn_timeout_s with
     | Some _, _, _ ->
       Error
         (Printf.sprintf
            "provider %S uses vibe-cli and must not declare credentials; \
             Mistral Vibe owns its login"
            provider.id)
     | None, _, _ when not provider.is_non_interactive ->
       Error
         (Printf.sprintf
            "provider %S uses vibe-cli and must declare \
             is-non-interactive = true"
            provider.id)
     | None, Some _, _ ->
       Error
         (Printf.sprintf
            "binding %s.%s declares reasoning-effort, but a Mistral Vibe call \
             has no reasoning control"
            provider.id
            spec.id)
     | None, None, Some _ ->
       Error
         (Printf.sprintf
            "binding %s.%s declares turn-timeout-s, but a Mistral Vibe call has \
             no MASC time limit"
            provider.id
            spec.id)
     | None, None, None ->
       Ok (Runtime_execution.Vibe_cli { cli_path = command; model = spec.api_name }))
;;

let refuse_anthropic_thinking_control_on_official_client
      (provider : Runtime_schema.provider)
      (spec : Runtime_schema.model_spec)
  =
  match provider.Runtime_schema.api_format with
  | Runtime_schema.Codex_app_server_runtime
  | Runtime_schema.Antigravity_cli_runtime
  | Runtime_schema.Claude_code_runtime
  | Runtime_schema.Muse_serve_runtime
  | Runtime_schema.Vibe_cli_runtime ->
    (match
       Option.bind spec.Runtime_schema.capabilities (fun caps ->
         caps.Runtime_schema.anthropic_thinking_control)
     with
     | None -> Ok ()
     | Some _ ->
       Error
         (Printf.sprintf
            "binding %s.%s declares anthropic-thinking-control, but only the Anthropic \
             wire reads it (this binding is an official-client runtime)"
            provider.Runtime_schema.id
            spec.Runtime_schema.id))
  | Runtime_schema.Messages_api
  | Runtime_schema.Chat_completions_api
  | Runtime_schema.Ollama_api
  | Runtime_schema.Gemini_api
  | Runtime_schema.Vertex_gemini_api -> Ok ()
;;

let materialize_execution ~construction (cfg : Runtime_schema.config) (binding : Runtime_schema.binding)
    : (execution_materialization, string) result =
  match Runtime_schema.model_of_id cfg binding.model_id with
  | None -> Error (Printf.sprintf "model not found: %s" binding.model_id)
  | Some spec ->
    (match Runtime_schema.provider_of_id cfg binding.provider_id with
     | None -> Error (Printf.sprintf "provider not found: %s" binding.provider_id)
     | Some provider ->
       let open Result.Syntax in
       let* () = match provider.api_format with
         | Messages_api | Chat_completions_api | Ollama_api | Gemini_api | Vertex_gemini_api -> Ok ()
         | Codex_app_server_runtime | Antigravity_cli_runtime | Claude_code_runtime | Muse_serve_runtime
         | Vibe_cli_runtime ->
           validate_parallel_tool_policy provider ~model_id:binding.model_id
             ~supports_parallel_tool_suppression:false
             ~disable_parallel_tool_use:binding.disable_parallel_tool_use in
       let* () = refuse_anthropic_thinking_control_on_official_client provider spec in
       let official result = Result.map
         (fun execution -> {execution;credential_admission=None}) result in
       (match provider.api_format with
        | Runtime_schema.Codex_app_server_runtime ->
          official (codex_app_server_execution provider spec)
        | Runtime_schema.Antigravity_cli_runtime ->
          official (antigravity_cli_execution provider spec)
        | Runtime_schema.Claude_code_runtime ->
          official (claude_code_execution provider spec)
        | Runtime_schema.Muse_serve_runtime ->
          official (muse_serve_execution provider spec)
        | Runtime_schema.Vibe_cli_runtime ->
          official (vibe_cli_execution provider spec)
        | Messages_api | Chat_completions_api | Ollama_api | Gemini_api | Vertex_gemini_api ->
          Result.map
            (fun (selected : provider_materialization) ->
              {execution=Runtime_execution.Agent_core selected.provider_config;
               credential_admission=Some selected.credential_admission})
            (materialize_provider_binding ~construction cfg binding)))
;;
