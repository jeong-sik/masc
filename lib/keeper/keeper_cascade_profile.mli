(** Canonical keeper cascade profile names and legacy alias normalization.

    Keepers historically used stringly-typed cascade names in TOML, runtime
    metadata, telemetry labels, and cascade.json lookups. This module is the
    SSOT for the active keeper cascade profile and the legacy aliases that must
    continue to resolve to it. *)

(** Canonical cascade profile for keeper turns. *)
val default_name : string

(** SSOT list of cascade profile names valid in the repo [config/cascade.json].
    Consumers (dashboards, validators, tests) should reference this list
    rather than hardcoding their own. Personal/playground-only cascades
    are NOT included here — those belong under
    [$MASC_BASE_PATH/.masc/playground/.../cascade.json].
    @since 0.9.5 *)
val known_cascades : string list

(** Map keeper aliases and historical drift names to the canonical
    cascade profile name. Unknown names fall back to {!default_name}
    (previously they passed through unchanged, which let typos and dead
    profile names silently create ghost metric labels). *)
val canonicalize : string -> string

(** JSON config key for the cascade's configured model list. *)
val models_key : string -> string

(** JSON config key for the cascade's configured temperature. *)
val temperature_key : string -> string

(** JSON config key for the cascade's configured max_tokens. *)
val max_tokens_key : string -> string
