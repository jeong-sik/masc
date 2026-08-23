(** Sum-typed provider-kind resolver for runtime model specs.

    Resolves a ["provider:model"] spec to a {!Provider_config.provider_kind}
    via the {!Provider_registry}. This module lives inside the runtime/AGENT_CORE
    boundary; masc-core callers should route by opaque runtime id instead of
    parsing provider/model strings.

    This module exists to prevent a recurring anti-pattern where
    callers classify provider kind by substring match over the spec
    string and silently flatten unknown specs to [OpenAI_compat].
    Unknown or malformed specs return {!Unknown} instead of a permissive
    default so downstream code can fail closed (fail-open to registry
    lookup is the caller's decision, not this resolver's). *)

type resolution =
  | Registered of {
      provider_name : string;
      model_id : string;
      kind : Llm_provider.Provider_config.provider_kind;
    }
      (** The provider prefix is known in {!Provider_registry}, and the
          returned [kind] is the authoritative classification. *)
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
    3. Otherwise consult {!Provider_registry.find}. The registered [kind] wins. No
       substring heuristic ever overrides this.
    4. If the provider name is not known there, return [Unknown]
       with a diagnostic. Never silently default to [OpenAI_compat]. *)
val resolve : string -> resolution

