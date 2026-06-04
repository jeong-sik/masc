(** Model-label string → [Provider_config.t] resolution (RFC-0206).
    Re-homed from deleted [Runtime_config_parser.parse_model_string]; resolves
    a ["provider:model"] / ["custom:model@url"] label via Provider_registry
    (SSOT). No runtime routing/weighted-entry machinery. *)

val split_provider_model : string -> (string * string) option
(** Split ["provider:model_id"] at the first colon; [None] if missing/leading/
    trailing colon or empty model id. *)

val parse_model_string
  :  ?temperature:float
  -> ?max_tokens:int
  -> ?system_prompt:string
  -> ?api_key_env_overrides:(string * string) list
  -> ?supports_tool_choice_override:bool
  -> ?keep_alive:string
  -> ?num_ctx:int
  -> string
  -> Llm_provider.Provider_config.t option
(** Resolve a model label to a hot-path provider config. [None] when the
    provider is unregistered, unavailable, or the spec is malformed. Unknown
    specs are never flattened to a default kind (Provider_kind_resolver SSOT). *)
