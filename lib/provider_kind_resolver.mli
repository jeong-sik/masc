(** Sum-typed provider-kind resolver for cascade model specs.

    Resolves a ["provider:model"] spec to a {!Provider_config.provider_kind}
    via the {!Provider_registry} plus a tiny set of repo-local
    compatibility shims for providers not yet present in the pinned OAS
    registry.

    This module exists to prevent a recurring anti-pattern where
    callers classify provider kind by substring match (e.g. [String.contains
    s "gemini"]) and silently flatten unknown specs to [OpenAI_compat].
    Unknown or malformed specs return {!Unknown} instead of a permissive
    default so downstream code can fail closed (fail-open to registry
    lookup is the caller's decision, not this resolver's).

    Issue: #8159 (gemini:gemini-2.5-flash flattened to OpenAI_compat).
    Related: #7600 (master inventory of stringly-typed provider sites). *)

type resolution =
  | Registered of {
      provider_name : string;
      model_id : string;
      kind : Llm_provider.Provider_config.provider_kind;
    }
      (** The provider prefix is known either in {!Provider_registry} or
          via a repo-local compatibility provider, and the returned
          [kind] is the authoritative classification. *)
  | Custom_url of { model_id : string; base_url : string }
      (** The spec uses the ["custom:model\@url"] form; kind is
          {i by contract} [OpenAI_compat] because that is the protocol
          the custom runtime must speak. Callers do not substitute a
          different kind. *)
  | Unknown of string
      (** The spec is malformed (missing colon, empty half) or the
          provider name is not registered. The string carries a short
          reason for logging. Callers must not default this to any
          concrete kind. *)

(** [resolve spec] parses a ["provider:model"] (or ["custom:model\@url"])
    spec and returns the registry-authoritative kind.

    Resolution order:
    1. Parse [provider_name:model_id] split (reject empty halves).
    2. If [provider_name = "custom"], delegate to custom-URL parser.
    3. Otherwise consult built-in compatibility providers, then
       {!Provider_registry.find}. The registered [kind] wins. No
       substring heuristic ever overrides this.
    4. If the provider name is not known there, return [Unknown]
       with a diagnostic. Never silently default to [OpenAI_compat]. *)
val resolve : string -> resolution

(** Extract just the {!Provider_config.provider_kind} for a spec, if
    known. Returns [None] for [Unknown]. Useful for call sites that
    only need the kind and not the split model id. *)
val kind_of_spec :
  string -> Llm_provider.Provider_config.provider_kind option

val uses_anthropic_caching_for_kind :
  Llm_provider.Provider_config.provider_kind -> bool

val uses_anthropic_caching_for_spec : string -> bool option

(** [env_var_for_kind kind] returns the conventional environment variable
    name that holds the API key for [kind], delegating to OAS's
    {!Llm_provider.Provider_kind.default_api_key_env}. Centralizing this
    lookup here keeps direct {!Llm_provider.Provider_kind} usage out of
    keeper / auth call sites and gives masc-mcp a single hook for future
    overrides (e.g. provider aliases, env-var customization). *)
val env_var_for_kind :
  Llm_provider.Provider_config.provider_kind -> string option
