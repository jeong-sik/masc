(** [env_var_for_kind kind] returns the conventional environment variable name
    that holds the API key for [kind], delegating to OAS's
    {!Llm_provider.Provider_kind.default_api_key_env}.

    This module is the masc-core hook for the kind → env-var lookup. It takes an
    already-resolved {!Llm_provider.Provider_config.provider_kind} and never
    parses a runtime id, so an auth caller depending on it learns only "which env
    var holds the key for this kind" — not how a runtime id splits into
    provider/model. Per RFC-0211 the masc core (auth included) must not read
    provider/model out of an id; keeping this lookup out of
    {!Provider_kind_resolver} (which also exposes the id-cracking [resolve])
    prevents auth from depending on an id-parsing module. *)
val env_var_for_kind :
  Llm_provider.Provider_config.provider_kind -> string option
