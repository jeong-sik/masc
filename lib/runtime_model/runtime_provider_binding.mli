(** Provider identity helpers shared across {!Runtime_config} submodules.

    All functions are pure with respect to the runtime binding registry and
    {!Llm_provider} SSOTs. No I/O. Intentionally kept stdlib-light: the
    callers in {!Runtime_config_parser}, {!Runtime_config_selection},
    {!Runtime_config_resolve}, and {!Runtime_config_strategy_resolve} pick up
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

val runtime_prefix_of_provider_kind :
  Llm_provider.Provider_config.provider_kind -> string

val provider_label_of_config : Llm_provider.Provider_config.t -> string

val provider_health_key_of_config : Llm_provider.Provider_config.t -> string
(** Key used by {!Runtime_health_tracker}. For OpenAI-compatible configs
    the model and base URL are appended so each endpoint is tracked
    independently. *)

val binding_auth_is_no_auth : Runtime_binding.t -> bool

val binding_base_url_is_loopback : Runtime_binding.t -> bool

val runtime_kind_of_binding : Runtime_binding.t -> string
(** ["local"] | ["direct_api"]. *)

val default_local_openai_runtime_provider_id : unit -> string option

val local_runtime_label : string -> string

val default_local_runtime_label : unit -> string

val runtime_health_keys_of_labels : string list -> string list

val runtime_id_of_label_or_raw : string -> string

val normalize_runtime_name_for_bucket : string -> string

val label_matches_runtime_id : label:string -> runtime_id:string -> bool

type context_window_hint =
  { context_window : int
  ; is_local_model : bool
  }

val context_window_hint_of_labels : string list -> context_window_hint

val provider_name_matches_default_local_openai_runtime : string -> bool

val provider_name_matches_kind_default :
  string -> Llm_provider.Provider_config.provider_kind -> bool

val display_provider_name : string -> string

val default_headers_for_kind :
  Llm_provider.Provider_config.provider_kind -> (string * string) list

val headers_with_auth :
  kind:Llm_provider.Provider_config.provider_kind ->
  api_key:string ->
  (string * string) list

val normalize_openai_compat_request_path :
  base_url:string -> request_path:string -> string
