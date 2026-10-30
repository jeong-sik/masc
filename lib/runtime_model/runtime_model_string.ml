(** Explicit model labels resolved through one AGENT_CORE runtime binding. *)
module Binding = Runtime_provider_binding
module Runtime_binding = Agent_core.Provider_runtime_binding

(** Build a config for ["custom:model@url"] specs. *)
let make_custom_config
  ?temperature
  ?max_tokens
  ?system_prompt
  ?keep_alive
  ?num_ctx
  ~base_url
  model_id
  =
  Llm_provider.Provider_config.make
    ~kind:OpenAI_compat
    ~model_id
    ~base_url
    ~request_path:
      (Binding.normalize_openai_compat_request_path
         ~base_url
         ~request_path:Masc_network_defaults.openai_chat_completions_path)
    ?temperature
    ?max_tokens
    ?system_prompt
    ?keep_alive
    ?num_ctx
    ()
;;

(** Resolve the effective API-key env var: per-provider override, then
    wildcard ["*"]. The registry no longer carries a default name. Empty
    entries fall through to no credential. *)
let resolve_effective_api_key_env
  ~(api_key_env_overrides : (string * string) list)
  ~(provider_name : string)
  ()
  =
  let find_non_empty key =
    match List.assoc_opt key api_key_env_overrides with
    | Some v when v <> "" -> Some v
    | _ -> None
  in
  match find_non_empty provider_name with
  | Some env -> env
  | None -> (
    match find_non_empty "*" with
    | Some env -> env
    | None -> "")
;;

(** Complete a selected immutable runtime binding with per-call options and
    explicitly supplied credentials. AGENT_CORE owns declared defaults; a
    defaultless Ollama auto selection may use discovery at that exact endpoint. *)
let make_binding_config
  ?temperature ?max_tokens ?system_prompt ?(api_key_env_overrides = [])
  ?keep_alive ?num_ctx
  ?(discover = fun ~headers ~timeout_s url ->
    Discovery_cache.first_ollama_model_id_for_url ~timeout_s ~headers url)
  ~model_id (binding : Runtime_binding.t)
  =
  let effective_api_key_env =
    resolve_effective_api_key_env ~api_key_env_overrides ~provider_name:binding.id () in
  let api_key = if effective_api_key_env = "" then ""
    else Sys.getenv_opt effective_api_key_env |> Option.value ~default:"" in
  if not binding.available || (binding.requires_api_key && api_key = "") then None
  else
    let model = match Runtime_model_resolve.model_selector_of_string model_id with
      | Concrete model -> Some model
      | Auto ->
        (match Option.bind binding.default_model String_util.trim_nonempty with
         | Some _ -> None
         | None ->
           (match binding.kind with
            | Ollama ->
              (match binding.discovery_timeout_s with
               | Some timeout_s ->
                 discover
                   ~headers:(Llm_provider.Provider_config.auth_headers_for_kind_and_key
                     ~kind:binding.kind ~api_key)
                   ~timeout_s binding.base_url
               | None -> None)
            | Anthropic | Kimi | OpenAI_compat | Gemini | Glm -> None)) in
    match Runtime_binding.to_provider_config ?model binding with
    | Error _ -> None
    | Ok selected ->
      let provider_context = selected.max_context in
      let request_path = match selected.kind with
        | OpenAI_compat -> Binding.normalize_openai_compat_request_path
            ~base_url:selected.base_url ~request_path:selected.request_path
        | Anthropic | Kimi | Ollama | Gemini | Glm -> selected.request_path in
      let config = {selected with
        api_key=Llm_provider.Secret.of_string api_key;
        headers=Binding.default_headers_for_kind selected.kind;
        request_path;temperature;max_tokens;system_prompt;keep_alive;num_ctx;max_context=None} in
      let max_context = match Llm_provider.Provider_config.context_window config with
        | Some _ as declared -> declared | None -> provider_context in
      Some {config with max_context}
;;

(** Resolve a ["provider:model"] / ["custom:model@url"] label to a hot-path
    provider config, or [None] when the provider is unregistered, unavailable,
    the spec is malformed, or a keyed entry has no supplied credential.
    The sum-typed classifier carries the selected runtime binding; unknown
    providers never become an anonymous OpenAI-compatible config. *)
let parse_model_string
  ?temperature
  ?max_tokens
  ?system_prompt
  ?(api_key_env_overrides = [])
  ?keep_alive
  ?num_ctx
  ?discover
  (s : string)
  : Llm_provider.Provider_config.t option
  =
  match Provider_kind_resolver.resolve s with
  | Unknown _ -> None
  | Custom_url { model_id; base_url } ->
    Some (make_custom_config
      ?temperature ?max_tokens ?system_prompt ?keep_alive ?num_ctx
      ~base_url model_id)
  | Registered { binding; model_id } ->
    make_binding_config ?temperature ?max_tokens ?system_prompt ~api_key_env_overrides
      ?keep_alive ?num_ctx ?discover ~model_id binding
;;
