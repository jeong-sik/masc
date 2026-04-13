(** Canonical keeper cascade profile names and legacy alias normalization.

    Keepers historically used stringly-typed cascade names in TOML, runtime
    metadata, telemetry labels, and cascade.json lookups. This module is the
    SSOT for the active keeper cascade profile and the legacy aliases that must
    continue to resolve to it. *)

(** Canonical cascade profile for keeper turns. *)
val default_name : string

(** Map known legacy keeper aliases to the canonical cascade profile name.
    Unknown names are preserved after trimming. Blank names fall back to
    {!default_name}. *)
val canonicalize : string -> string

(** JSON config key for the cascade's configured model list. *)
val models_key : string -> string

(** JSON config key for the cascade's configured temperature. *)
val temperature_key : string -> string

(** JSON config key for the cascade's configured max_tokens. *)
val max_tokens_key : string -> string
