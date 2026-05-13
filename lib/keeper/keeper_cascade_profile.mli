(** Config-driven cascade profile name resolution.

    Per RFC-0041 cascade routing SSOT, the live cascade catalog
    (cascade.json) is the only source of truth for cascade profile
    names — there is no compile-time enum here.  Code that needs to
    know "what profiles are available" reads them through
    {!catalog_names} / {!catalog_names_result} /
    {!catalog_names_for_validation}; the boot-time gate at
    [Cascade_catalog_runtime.validate_path_result] rejects keeper boot
    when the catalog is empty so a missing catalog never reaches the
    helpers below.

    @since 0.9.5 *)

type logical_use = Cascade_ref.logical_use =
  | Keeper_turn
  | Phase_recovery
  | Phase_buffer
  | Tool_required
  | Governance_judge
  | Operator_judge
  | Cross_verifier
  | Verifier
  | Autoresearch
  | Adversarial_reviewer
  | Auto_responder
  | Routing
  | Openai_compat
  | Persona_generation
  | Provider_benchmark
  | Simple_task
  | Moderate_task
  | Complex_task
  | Tool_rerank_use

val logical_use_key : logical_use -> string
(** Stable config key under [routes]. *)

val logical_use_of_string_opt : string -> logical_use option
(** Parse a logical route key or historical alias.  Concrete cascade
    profile names are not logical route keys — they live in the catalog. *)

val cascade_name_for_use : ?config_path:string -> logical_use -> string
(** Runtime cascade profile for a logical call site.

    Resolution order:
    1. [routes.<logical_use_key>] from the active cascade config, when it points
       at a live catalog profile.
    2. The first catalog entry from the live catalog.
    Raises [Failure] when the catalog is empty — boot-time validation is
    the upstream gate that prevents this state at runtime.

    This is the boundary for code that used to hardcode profile names such as
    ["governance_judge"], ["operator_judge"], ["local_recovery"], or
    ["cross_verifier"]. *)

val configured_route_targets : ?config_path:string -> unit -> string list
(** Unique non-empty profile names referenced from [routes]. *)

type runtime_name = Cascade_ref.runtime_name = Runtime_name of string
(** Catalog-aware cascade name after point-of-use runtime normalization.
    Manifest alias of {!Cascade_ref.runtime_name} (leaf module) so
    [Cascade_strategy] can carry the type without inducing a cycle. *)

val runtime_name_to_string : runtime_name -> string
val runtime_name_of_string : string -> runtime_name
(** Canonicalizes legacy aliases and live catalog names for runtime
    telemetry/admission labels.  Raw names that match a logical route key are
    resolved through {!cascade_name_for_use}; everything else passes through
    after [String.trim]. *)

val catalog_names : ?config_path:string -> unit -> string list
(** Live profile catalog discovered from the active [cascade.json].
    When the file cannot be read, returns [[]]. *)

val catalog_names_result : ?config_path:string -> unit -> (string list, string) result
(** Like {!catalog_names}, but preserves the loader error so validation
    boundaries can fail loud instead of collapsing catalog drift into an empty
    dynamic profile set. *)

val catalog_names_for_validation :
  ?config_path:string -> unit -> (string list, string) result
(** Accept-list source for the keeper cascade-name validator.

    Requires the declarative cascade catalog; retired flat-profile TOML and
    flat-key catalog fallback are intentionally not accepted. *)

val keeper_catalog_names : ?config_path:string -> unit -> string list
(** Assignable live profile names from {!catalog_names}, filtered by
    [keeper_assignable] metadata. *)

val system_catalog_names : ?config_path:string -> unit -> string list
(** Live system-only profile names present in [cascade.json]. *)

val fallback_cascade_for : ?config_path:string -> string -> string option
(** Declarative escalation hint for [name].

    Returns [Some target] when:
    - the profile [name] is present in the live catalog, AND
    - it declares a non-empty [fallback_cascade], AND
    - the [fallback_cascade] target is itself a live catalog entry.

    Returns [None] otherwise (including when the target is missing
    or self-referential). Unknown targets are logged as a single
    WARN line per startup and treated as if absent — the runtime
    must never crash because of a stale fallback hint.

    @since 0.174.0 *)

val is_system_only_cascade : string -> bool
(** Exact-name membership check against the active config's
    {!system_catalog_names}. *)

val canonicalize_with_catalog : catalog:string list -> string -> string
(** Resolves dynamic profiles against an explicit live catalog. *)

val resolve_live_with_catalog : catalog:string list -> string -> string
(** Resolves a keeper-declared cascade against an explicit live catalog.

    Names already present in the catalog pass through; logical route
    aliases collapse via [routes]; otherwise the input is returned
    trimmed and the catalog membership is the caller's responsibility. *)

val resolve_live : ?config_path:string -> string -> string
(** Like {!resolve_live_with_catalog}, but reads the active catalog from the
    resolved cascade config path. *)

val canonicalize : string -> string
(** Catalog-aware normalization: legacy aliases collapse to their canonical
    name through [routes], live catalog names pass through, otherwise
    [String.trim] is applied and the name is returned as-is.  Raises
    [Failure] when the catalog is empty (boot-time gate is upstream). *)

val normalize_declared_name : string -> string
(** Normalizes keeper-side implicit default and legacy aliases.
    Logical route aliases resolve through {!cascade_name_for_use}; otherwise
    the trimmed input is returned. *)

(** {1 cascade.json key helpers} *)

(** First canonicalize, then build the key. *)
val models_key : string -> string
val temperature_key : string -> string
val max_tokens_key : string -> string
