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

(* Built on first use rather than at link time. Building it reads the embedded
   model catalog, and that read reports through the provider layer's
   diagnostics -- at link time, which is before any program has said where its
   diagnostics should go. Every binary that links this paid for that: the line
   landed on the TUI's own terminal, between two frames, and the frame
   presenter's picture of the screen was no longer the screen.

   Memoised through an atomic rather than [lazy], which two domains cannot
   safely force, and published with compare-and-set so a race leaves one
   registry rather than two that can be registered into separately. *)
let default_registry_cell :
    Llm_provider.Provider_registry.t option Atomic.t =
  Atomic.make None

let default_registry () =
  match Atomic.get default_registry_cell with
  | Some registry -> registry
  | None ->
      let built = Llm_provider.Provider_registry.default () in
      if Atomic.compare_and_set default_registry_cell None (Some built)
      then built
      else (
        match Atomic.get default_registry_cell with
        | Some registry -> registry
        | None -> built)

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

(** Build a {!Llm_provider.Provider_config.t} from a resolved registry entry.
    [None] when the entry needs an API key and no override supplies one: a
    keyed label with an empty key is a refusal, not a silent empty key. *)
let make_registry_config
  ?temperature
  ?max_tokens
  ?system_prompt
  ?(api_key_env_overrides = [])
  ?keep_alive
  ?num_ctx
  ~provider_name
  ~model_id
  (entry : Llm_provider.Provider_registry.entry)
  =
  let defaults = entry.defaults in
  let effective_api_key_env =
    resolve_effective_api_key_env ~api_key_env_overrides ~provider_name ()
  in
  let api_key =
    if effective_api_key_env = ""
    then ""
    else Sys.getenv_opt effective_api_key_env |> Option.value ~default:""
  in
  if defaults.requires_api_key && api_key = ""
  then None
  else
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
    let base_url = defaults.base_url in
    let request_path =
      match defaults.kind with
      | OpenAI_compat ->
        Binding.normalize_openai_compat_request_path
          ~base_url
          ~request_path:defaults.request_path
      | Llm_provider.Provider_kind.Anthropic | Llm_provider.Provider_kind.Kimi
      | Llm_provider.Provider_kind.Ollama | Llm_provider.Provider_kind.Gemini
      | Llm_provider.Provider_kind.Glm -> defaults.request_path
    in
    let config =
      Llm_provider.Provider_config.make
        ~kind:defaults.kind
        ~provider_id:entry.name
        ~model_id:resolved_model_id
        ~base_url
        ~api_key
        ~headers
        ~request_path
        ?temperature
        ?max_tokens
        ?system_prompt
        ?keep_alive
        ?num_ctx
        ()
    in
    let max_context =
      match Llm_provider.Provider_config.context_window config with
      | Some _ as declared -> declared
      | None -> entry.max_context
    in
    Some { config with max_context }
;;

(** Resolve a ["provider:model"] / ["custom:model@url"] label to a hot-path
    provider config, or [None] when the provider is unregistered, unavailable,
    the spec is malformed, or a keyed entry has no supplied credential.
    Kind classification goes through the sum-typed {!Provider_kind_resolver}
    (Provider_registry as SSOT) — unknown specs are never flattened to
    [OpenAI_compat]. *)
let parse_model_string
  ?temperature
  ?max_tokens
  ?system_prompt
  ?(api_key_env_overrides = [])
  ?keep_alive
  ?num_ctx
  (s : string)
  : Llm_provider.Provider_config.t option
  =
  match Provider_kind_resolver.resolve s with
  | Unknown _ -> None
  | Custom_url { model_id; base_url } ->
    Some (make_custom_config
      ?temperature ?max_tokens ?system_prompt ?keep_alive ?num_ctx
      ~base_url model_id)
  | Registered { provider_name; model_id; kind = resolved_kind } ->
    (match Llm_provider.Provider_registry.find (default_registry ()) provider_name with
     | None -> None
     | Some entry when not (entry.is_available ()) -> None
     | Some entry ->
       if entry.defaults.kind <> resolved_kind then None
       else make_registry_config
         ?temperature ?max_tokens ?system_prompt ~api_key_env_overrides
         ?keep_alive ?num_ctx ~provider_name ~model_id entry)
;;
