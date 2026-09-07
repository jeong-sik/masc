(** Provider identity helpers shared across {!Runtime_config} submodules.

    All functions are pure with respect to the runtime binding registry and
    {!Llm_provider} SSOTs. No I/O. Intentionally kept stdlib-light: the
    callers in {!Runtime_config_parser}, {!Runtime_config_selection},
    {!Runtime_config_resolve}, and {!Runtime_config_strategy_resolve} pick up
    these helpers as their lowest layer.

    @stability Internal *)

module Runtime_binding = Agent_core.Provider_runtime_binding

val normalize_provider_id : string -> string
(** Trim, lowercase, and replace [-] with [_] in a provider identifier so
    label/binding lookups are case- and separator-insensitive. *)

val provider_endpoint_label_of_config : Llm_provider.Provider_config.t -> string
(** Which provider, model and endpoint a call resolved to. For
    OpenAI-compatible configs the model and base URL are appended, so two
    bindings sharing a provider are still distinguishable. Reported after a
    turn succeeds; nothing keys failure state off it. *)

val local_runtime_label : string -> string

val label_matches_runtime_id : label:string -> runtime_id:string -> bool

val provider_name_matches_default_local_openai_runtime : string -> bool

val provider_name_matches_kind_default :
  string -> Llm_provider.Provider_config.provider_kind -> bool

val default_headers_for_kind :
  Llm_provider.Provider_config.provider_kind -> (string * string) list

val normalize_openai_compat_request_path :
  base_url:string -> request_path:string -> string
