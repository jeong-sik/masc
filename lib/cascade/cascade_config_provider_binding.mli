(** Provider identity helpers shared across {!Cascade_config} submodules.

    All functions are pure with respect to the runtime binding registry and
    {!Llm_provider} SSOTs. No I/O. Intentionally kept stdlib-light: the
    callers in {!Cascade_config_parser}, {!Cascade_config_selection},
    {!Cascade_config_resolve}, and {!Cascade_config_strategy_resolve} pick up
    these helpers as their lowest layer.

    @stability Internal *)

module Runtime_binding = Agent_sdk.Provider_runtime_binding

val normalize_provider_id : string -> string
(** Trim, lowercase, and replace [-] with [_] in a provider identifier so
    label/binding lookups are case- and separator-insensitive. *)

val runtime_binding_of_label : string -> Runtime_binding.t option
(** Look up a runtime binding by raw label, falling back to
    {!normalize_provider_id}-normalized form. *)

val provider_name_of_kind :
  Llm_provider.Provider_config.provider_kind -> string

val cascade_prefix_of_provider_kind :
  Llm_provider.Provider_config.provider_kind -> string

val provider_label_of_config : Llm_provider.Provider_config.t -> string

val provider_health_key_of_config : Llm_provider.Provider_config.t -> string
(** Key used by {!Cascade_health_tracker}. For local OpenAI-compat configs
    the base URL is appended so each endpoint is tracked independently. *)

val runtime_kind_of_binding : Runtime_binding.t -> string
(** ["cli_agent"] | ["local"] | ["direct_api"]. *)

val default_local_openai_runtime_provider_id : unit -> string option

val provider_name_matches_default_local_openai_runtime : string -> bool

val provider_name_matches_kind_default :
  string -> Llm_provider.Provider_config.provider_kind -> bool

val display_provider_name : string -> string

val headers_with_auth :
  kind:Llm_provider.Provider_config.provider_kind ->
  api_key:string ->
  (string * string) list

val normalize_openai_compat_request_path :
  base_url:string -> request_path:string -> string
