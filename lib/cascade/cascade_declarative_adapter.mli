(** Declarative cascade config → runtime adapter (RFC-0058 Phase 2).

    Converts a parsed {!Cascade_declarative_types.cascade_config} (the 5-layer
    TOML schema from Phase 1) into an {!adapted_catalog} that mirrors the
    shape consumed by the cascade runtime ({!Cascade_catalog_runtime}).

    @stability Internal *)

(** {1 Errors} *)

type adapter_error =
  | Provider_not_found of string
  (** Binding references a TOML provider id that is not declared. *)
  | Model_not_found of string
  (** Model id referenced by a binding has no matching [models.*] entry. *)
  | Binding_resolution_failed of string
  (** Binding "provider.model" could not produce a {!Provider_config.t}.
      Root cause is either [Provider_not_found] or [Model_not_found]. *)
  | Alias_resolution_failed of string
  (** Alias "provider.model.alias" parent binding does not exist. *)
  | Duplicate_route of string
  (** Two routes with the same name. *)
  | Internal of string
  (** Unexpected adapter error (should not happen in production). *)
[@@deriving show]

(** {1 Adapted types} *)

type provider_config_with_override =
  Llm_provider.Provider_config.t * Provider_tool_support.runtime_capabilities_override option
(** Provider config paired with an optional per-provider capability override.
    [None] inherits from the OAS runtime binding; [Some o] replaces the
    runtime-derived value for that provider. *)

type adapted_profile = {
  name : string;
  (** Profile name — a plain provider:model string. *)
  provider_configs : provider_config_with_override list;
  (** Resolved provider configs with optional per-provider capability
      overrides, in declaration order. *)
  strategy : Cascade_strategy.t;
  (** Mapped strategy with parameters. *)
  ollama_max_concurrent : int option;
  (** Per-profile [max_concurrent] cap for Ollama providers, if set. *)
  cli_max_concurrent : int option;
  (** Per-profile [max_concurrent] cap for CLI providers, if set. *)
  required_capability_profile : string option;
  (** Capability profile name required by this profile, if any. *)
}

type adapted_catalog = {
  profiles : adapted_profile list;
  routes : (string * string) list;
  (** [(route_name, profile_name)] pairs. *)
  system_targets : (string * string) list;
  (** [(target_name, "provider.model")] pairs. *)
  default_profile : string option;
  (** The profile whose binding has [is-default = true], if any. *)
  capability_profiles : Cascade_declarative_types.cascade_profile list;
  (** Capability profiles declared in [[profiles.*]] section. *)
  errors : adapter_error list;
  (** Accumulated errors. Empty when adaptation succeeds fully. *)
}

(** {1 Entry point} *)

val binding_to_provider_config :
  Cascade_declarative_types.cascade_config ->
  Cascade_declarative_types.cascade_binding ->
  (Llm_provider.Provider_config.t, string) result
(** cascade→Runtime 전환: 단일 binding 을 routing 없이 [Provider_config.t] 로
    materialize. provider/model resolve 실패 시 [Error] (silent fallback 없음).
    capabilities override 와 alias 레이어는 버린다 (v1). *)

val adapt_config : Cascade_declarative_types.cascade_config -> adapted_catalog
(** [adapt_config cfg] converts a validated declarative config into an
    adapted catalog. Resolution errors are accumulated in
    [adapted_catalog.errors] rather than raised — the caller inspects
    the error list to decide whether to proceed.

    Precondition: [cfg] should pass {!Cascade_declarative_validator.validate}
    (zero errors) before calling [adapt_config]. The adapter performs a
    second pass focused on runtime resolution: declared providers are
    converted to [Provider_config.t] from their typed TOML metadata. *)
