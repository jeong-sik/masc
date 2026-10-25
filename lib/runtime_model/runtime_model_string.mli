(** Model-label string → [Provider_config.t] resolution (RFC-0206).
    Re-homed from deleted [Runtime_config_parser.parse_model_string]; resolves
    a ["provider:model"] / ["custom:model@url"] label via Provider_registry
    (SSOT). No runtime routing/weighted-entry machinery. *)

val parse_model_string
  :  ?temperature:float
  -> ?max_tokens:int
  -> ?system_prompt:string
  -> ?api_key_env_overrides:(string * string) list
  -> ?keep_alive:string
  -> ?num_ctx:int
  -> string
  -> Llm_provider.Provider_config.t option
(** Resolve a model label to a hot-path provider config. [None] when the
    provider is unregistered, unavailable, or the spec is malformed, or when
    a keyed entry has no supplied credential. Unknown specs are never
    flattened to a default kind (Provider_kind_resolver SSOT).

    A registered label carries the canonical registry provider id into the
    returned config. Its context window uses that config's provider/model
    capability lookup, so an unrelated bare model row cannot substitute for
    the selected provider. Request preparation still owns policy freezing. *)
