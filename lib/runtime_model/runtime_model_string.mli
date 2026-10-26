(** Model-label string → [Provider_config.t] resolution (RFC-0206).
    Re-homed from deleted [Runtime_config_parser.parse_model_string]; resolves
    a ["provider:model"] / ["custom:model@url"] label via a resolved AGENT_CORE runtime binding. No runtime routing/weighted-entry machinery. *)

val parse_model_string
  :  ?temperature:float
  -> ?max_tokens:int
  -> ?system_prompt:string
  -> ?api_key_env_overrides:(string * string) list
  -> ?keep_alive:string
  -> ?num_ctx:int
  -> ?discover:(headers:(string * string) list -> timeout_s:float -> string -> string option)
  -> string
  -> Llm_provider.Provider_config.t option
(** Resolve a model label to a hot-path provider config. [None] when the
    provider is unknown/unavailable, the spec is malformed, a keyed binding
    has no supplied credential, or [auto] has neither a catalog-declared
    default nor an endpoint-scoped Ollama discovery result.
    Classification carries the selected binding into config construction.

    [discover] is consulted only for an Ollama [auto] selection without a
    declared default and with a declared [discovery_timeout_s]. It receives
    the selected binding's authentication headers, exact base URL and total
    HTTP deadline, never another provider's endpoint or an implicit deadline.
    A declared default or a missing discovery deadline never triggers discovery.
    The default reuses only fresh observations from the same URL, native protocol
    and exact header fingerprint scope. Plaintext credentials are not cached.

    A registered label carries the canonical binding provider id into the
    returned config. Its context window uses that config's provider/model
    capability lookup, so an unrelated bare model row cannot substitute for
    the selected provider. Request preparation still owns policy freezing.
    Custom labels require an explicit absolute HTTP(S) URL; omission or an
    invalid endpoint returns [None] without environment/discovery fallback. *)
