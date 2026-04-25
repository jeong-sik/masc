(** Canonical keeper cascade profile names and legacy alias normalization.

    Keepers historically used stringly-typed cascade names in TOML, runtime
    metadata, telemetry labels, and cascade.json lookups. This module is the
    SSOT for the active keeper cascade profile and the legacy aliases that must
    continue to resolve to it.

    One keeper-assignable bootstrap profile (Big_three) and one system-only
    profile (Tool_rerank).
    Catalog-routed names ("keeper_unified", "tool_use_strict",
    "resilient_breaker", "local_only", "local_recovery") are NOT variants —
    they pass through [canonicalize_with_catalog] as catalog names.

    @since 0.9.5 *)

(** SSOT variant for the 1+1 cascade model.

    One keeper-assignable bootstrap profile ({!Big_three}) and one system-only
    profile ({!Tool_rerank}).

    Adding a new profile is a compile-time event: add a variant here, then
    exhaustive [match] sites flag every consumer that needs to handle it.
    Personal/playground-only cascades must NOT be added here — they live in
    [$MASC_BASE_PATH/.masc/playground/.../cascade.json] only. *)
type t =
  | Big_three
  | Tool_rerank

val all : t list
(** [all] is exhaustive: every variant constructor of {!t} appears
    exactly once. *)

val to_string : t -> string
(** Canonical lowercase-snake-case name. *)

val of_string_opt : string -> t option
(** Parse a raw cascade name into the variant. Handles legacy aliases
    by collapsing them to [Big_three]. Returns [None] for unknown names
    and catalog-routed names ("keeper_unified", "tool_use_strict",
    "resilient_breaker", "local_only", "local_recovery"). *)

val canonical : string -> t
(** [canonical raw] = [of_string_opt raw |> Option.value ~default]. *)

val default : t
val default_name : string
(** [default_name = to_string default = "big_three"]. *)

val known_cascades : string list
(** [known_cascades = List.map to_string all]. Provided for consumers
    that still operate on strings; new code should take {!t} directly. *)

val catalog_names : ?config_path:string -> unit -> string list
(** Live profile catalog discovered from the active [cascade.json].
    When the file cannot be read, returns [[]]. *)

val catalog_names_result : ?config_path:string -> unit -> (string list, string) result
(** Like {!catalog_names}, but preserves the loader error so validation
    boundaries can fail loud instead of collapsing catalog drift into an empty
    dynamic profile set. *)

(** Provenance of the names returned by {!catalog_names_with_toml_fallback}. *)
type catalog_names_source =
  | Live_catalog
      (** The full strict catalog ([Cascade_config_loader.load_catalog])
          succeeded; names are the live, validated catalog entries. *)
  | Toml_section_fallback of { catalog_error : string }
      (** Strict catalog load failed but [cascade.toml] was parseable.
          Names come from the top-level table sections; [catalog_error]
          is the original loader error so callers can WARN about the
          degraded mode. *)

val catalog_names_with_toml_fallback :
  ?config_path:string ->
  unit ->
  (string list * catalog_names_source, string) result
(** #10259 — accept-list source for the keeper cascade-name validator.

    On strict-load success, returns the live catalog names tagged
    [Live_catalog].  On strict-load failure, falls back to enumerating
    [cascade.toml]'s top-level table sections (filtering meta-keys
    starting with ['_']) and tags the result [Toml_section_fallback].
    Returns [Error _] when neither source produces a non-empty name list.
    An empty degraded fallback is not a safe success for the validator.

    This decouples the validator's accept list from full strict
    materialization so a localized field-whitelist regression in the
    materializer does not silently reject every operator-defined
    cascade across the fleet. *)

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

val is_system_only_cascade : ?config_path:string -> string -> bool
(** Exact-name membership check against the active config's
    {!system_catalog_names}.  [?config_path] overrides the
    resolver-derived path so unit tests can pin the contract
    against a fixture cascade.toml. *)

val canonicalize_with_catalog : catalog:string list -> string -> string
(** Resolves dynamic profiles against an explicit live catalog. *)

val resolve_live_with_catalog : catalog:string list -> string -> string
(** Resolves a keeper-declared cascade against an explicit live catalog.

    Compile-time built-in names absent from the runtime catalog are treated
    as drift and fall back to {!default_name}. *)

val resolve_live : ?config_path:string -> string -> string
(** Like {!resolve_live_with_catalog}, but reads the active catalog from the
    resolved cascade config path. *)

val canonicalize : string -> string
(** [canonicalize raw = to_string (canonical raw)]. Legacy aliases collapse
    to their canonical name, live catalog names pass through, unknown values
    fall back to {!default_name}. *)

val normalize_declared_name : string -> string
(** Normalizes keeper-side implicit default and legacy aliases.
    Unknown nonblank names are preserved (trimmed). *)

(** {1 cascade.json key helpers} *)

val models_key_t : t -> string
val temperature_key_t : t -> string
val max_tokens_key_t : t -> string

(** String-based wrappers; first canonicalize, then build the key. *)
val models_key : string -> string
val temperature_key : string -> string
val max_tokens_key : string -> string
