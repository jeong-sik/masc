(** Model-label string → [Provider_config.t] resolution (RFC-0206).

    Re-homed from the deleted [Runtime_config_parser.parse_model_string] path.
    Resolves a ["provider:model"] (or ["custom:model@url"]) label to a hot-path
    {!Llm_provider.Provider_config.t} using {!Llm_provider.Provider_registry} as
    the single source of truth — NO runtime routing/weighted-entry machinery is
    ported (the weighted-entry / selection / strategy parsing stayed deleted).

    Provider identity helpers live in {!Runtime_provider_binding}; auto-model
    resolution in {!Runtime_model_resolve}; kind classification in
    {!Provider_kind_resolver} (all surviving). *)

module Binding = Runtime_provider_binding

let default_registry = Llm_provider.Provider_registry.default ()

(** Split a ["provider:model_id"] string at the first colon. Delegates to the
    canonical leaf {!Runtime_model_id_split}. *)
let split_provider_model = Runtime_model_id_split.split_provider_model

(** Build a config for ["custom:model@url"] specs. *)
let make_custom_config
  ~temperature
  ~max_tokens
  ?system_prompt
  ?supports_tool_choice_override
  ?keep_alive
  ?num_ctx
  model_id
  =
  let actual_model, base_url = Runtime_model_resolve.parse_custom_model model_id in
  if actual_model = ""
  then None
  else
    Some
      (Llm_provider.Provider_config.make
         ~kind:OpenAI_compat
         ~model_id:actual_model
         ~base_url
         ~request_path:
           (Binding.normalize_openai_compat_request_path
              ~base_url
              ~request_path:Masc_network_defaults.openai_chat_completions_path)
         ~temperature
         ~max_tokens
         ?system_prompt
         ?supports_tool_choice_override
         ?keep_alive
         ?num_ctx
         ())
;;

(** Resolve the effective API-key env var: per-provider override, then
    wildcard ["*"], then registry default. Empty entries fall through. *)
let resolve_effective_api_key_env
  ~(api_key_env_overrides : (string * string) list)
  ~(provider_name : string)
  ~(registry_default : string)
  =
  let find_non_empty key =
    match List.assoc_opt key api_key_env_overrides with
    | Some v when v <> "" -> Some v
    | _ -> None
  in
  match find_non_empty provider_name with
  | Some env -> env
  | None ->
    (match find_non_empty "*" with
     | Some env -> env
     | None -> registry_default)
;;

(** Build a {!Llm_provider.Provider_config.t} from a resolved registry entry. *)
let make_registry_config
  ~temperature
  ~max_tokens
  ?system_prompt
  ?(api_key_env_overrides = [])
  ?supports_tool_choice_override
  ?keep_alive
  ?num_ctx
  ~provider_name
  ~model_id
  (entry : Llm_provider.Provider_registry.entry)
  =
  let defaults = entry.defaults in
  let effective_api_key_env =
    resolve_effective_api_key_env
      ~api_key_env_overrides
      ~provider_name
      ~registry_default:defaults.api_key_env
  in
  let api_key =
    if effective_api_key_env = ""
    then ""
    else Env_config_core.raw_value_opt effective_api_key_env |> Option.value ~default:""
  in
  let headers = Binding.default_headers_for_kind defaults.kind in
  let discover =
    if Binding.provider_name_matches_kind_default provider_name Ollama
    then
      Some
        (fun () ->
          Llm_provider.Discovery.first_discovered_model_id_for_url defaults.base_url)
    else if Binding.provider_name_matches_default_local_openai_runtime provider_name
    then Some Llm_provider.Discovery.first_discovered_model_id
    else None
  in
  let model_resolution =
    Runtime_model_resolve.resolve_auto_model
      ?discover
      provider_name
      (Runtime_model_resolve.model_selector_of_string model_id)
  in
  let resolved_model_id = model_resolution.resolved_model_id in
  let base_url =
    if Binding.provider_name_matches_default_local_openai_runtime provider_name
    then (
      match Llm_provider.Discovery.endpoint_for_model resolved_model_id with
      | Some url -> url
      | None -> Llm_provider.Provider_registry.next_llama_endpoint ())
    else defaults.base_url
  in
  let request_path =
    match defaults.kind with
    | OpenAI_compat ->
      Binding.normalize_openai_compat_request_path
        ~base_url
        ~request_path:defaults.request_path
    | _ -> defaults.request_path
  in
  let max_context =
    let caps =
      Option.value
        ~default:entry.capabilities
        (Llm_provider.Capabilities.for_model_id resolved_model_id)
    in
    match caps.max_context_tokens with
    | Some n -> n
    | None -> entry.max_context
  in
  Llm_provider.Provider_config.make
    ~kind:defaults.kind
    ~model_id:resolved_model_id
    ~base_url
    ~api_key
    ~headers
    ~request_path
    ~temperature
    ~max_tokens
    ~max_context
    ?system_prompt
    ?supports_tool_choice_override
    ?keep_alive
    ?num_ctx
    ()
;;

(** Resolve a ["provider:model"] / ["custom:model@url"] label to a hot-path
    provider config, or [None] when the provider is unregistered, unavailable,
    or the spec is malformed. Kind classification goes through the sum-typed
    {!Provider_kind_resolver} (Provider_registry as SSOT) — unknown specs are
    never flattened to [OpenAI_compat]. *)
let parse_model_string
  ?(temperature = Runtime_provider_defaults.agent_default_temperature)
  ?(max_tokens = Runtime_provider_defaults.agent_default_max_tokens)
  ?system_prompt
  ?(api_key_env_overrides = [])
  ?supports_tool_choice_override
  ?keep_alive
  ?num_ctx
  (s : string)
  : Llm_provider.Provider_config.t option
  =
  let trimmed = String.trim s in
  match split_provider_model trimmed with
  | Some ("custom", model_id) ->
    make_custom_config
      ~temperature
      ~max_tokens
      ?system_prompt
      ?supports_tool_choice_override
      ?keep_alive
      ?num_ctx
      model_id
  | _ ->
    (match Provider_kind_resolver.resolve s with
     | Unknown _ -> None
     | Custom_url _ -> None
     | Registered { provider_name; model_id; kind = resolved_kind } ->
       (match Llm_provider.Provider_registry.find default_registry provider_name with
        | None -> None
        | Some entry when not (entry.is_available ()) -> None
        | Some entry ->
          if entry.defaults.kind <> resolved_kind
          then None
          else
            Some
              (make_registry_config
                 ~temperature
                 ~max_tokens
                 ?system_prompt
                 ~api_key_env_overrides
                 ?supports_tool_choice_override
                 ?keep_alive
                 ?num_ctx
                 ~provider_name
                 ~model_id
                 entry)))
;;
