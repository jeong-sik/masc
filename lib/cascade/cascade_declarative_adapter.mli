(** Declarative cascade config → runtime adapter (RFC-0058 Phase 2).

    Converts a parsed {!Cascade_declarative_types.cascade_config} (the 5-layer
    TOML schema from Phase 1) into an {!adapted_catalog} that mirrors the
    shape consumed by the cascade runtime ({!Cascade_catalog_runtime}).

    @stability Internal *)

(** {1 Errors} *)

type adapter_error =
  | Provider_not_found of string
  (** TOML provider id does not map to any known cascade_prefix. *)
  | Model_not_found of string
  (** Model id referenced by a binding has no matching [models.*] entry. *)
  | Binding_resolution_failed of string
  (** Binding "provider.model" could not produce a {!Provider_config.t}.
      Root cause is either [Provider_not_found] or [Model_not_found]. *)
  | Alias_resolution_failed of string
  (** Alias "provider.model.alias" parent binding does not exist. *)
  | Strategy_mismatch of string
  (** Tier declares strategy-specific fields for the wrong strategy kind. *)
  | Tier_group_empty of string
  (** Tier-group references no tiers. *)
  | Duplicate_route of string
  (** Two routes with the same name. *)
  | Internal of string
  (** Unexpected adapter error (should not happen in production). *)
[@@deriving show]

(** {1 Adapted types} *)

type adapted_profile = {
  name : string;
  (** Profile name derived from tier or tier-group (e.g. "tier.primary",
      "tier-group.primary"). *)
  provider_configs : Llm_provider.Provider_config.t list;
  (** Resolved provider configs, in declaration order. *)
  strategy : Cascade_strategy.t;
  (** Mapped strategy with parameters. *)
  ollama_max_concurrent : int option;
  (** Per-tier [max_concurrent] cap for Ollama providers, if set. *)
  cli_max_concurrent : int option;
  (** Per-tier [max_concurrent] cap for CLI providers, if set. *)
}

type adapted_catalog = {
  profiles : adapted_profile list;
  routes : (string * string) list;
  (** [(route_name, profile_name)] pairs. *)
  system_targets : (string * string) list;
  (** [(target_name, "provider.model")] pairs. *)
  default_profile : string option;
  (** The profile whose binding has [is-default = true], if any. *)
  errors : adapter_error list;
  (** Accumulated errors. Empty when adaptation succeeds fully. *)
}

(** {1 Entry point} *)

val adapt_config : Cascade_declarative_types.cascade_config -> adapted_catalog
(** [adapt_config cfg] converts a validated declarative config into an
    adapted catalog. Resolution errors are accumulated in
    [adapted_catalog.errors] rather than raised — the caller inspects
    the error list to decide whether to proceed.

    Precondition: [cfg] should pass {!Cascade_declarative_validator.validate}
    (zero errors) before calling [adapt_config]. The adapter performs a
    second pass focused on runtime resolution: declared providers are
    converted to [Provider_config.t] from their typed TOML metadata, with
    legacy model-string parsing retained only for providers not yet declared
    in TOML. *)
