(** Canonical keeper cascade profile names and legacy alias normalization.

    Keepers historically used stringly-typed cascade names in TOML, runtime
    metadata, telemetry labels, and cascade.json lookups. This module is the
    SSOT for the active keeper cascade profile and the legacy aliases that must
    continue to resolve to it. *)

(** SSOT for valid cascade profiles in repo [config/cascade.json].

    Adding a new profile is a compile-time event: add a variant here
    and every exhaustive [match] across the codebase flags the consumer
    sites that need to handle it. Personal/playground-only cascades
    must NOT be added here — they live in
    [$MASC_BASE_PATH/.masc/playground/.../cascade.json].

    @since 0.9.5 *)
type t =
  | Default
  | Keeper_unified
  | Sangsu
  | Local_only
  | Local_recovery
  | Tool_rerank
  (* v1 active catalog (2026-04-17): keepers route through these via
     [config/cascade.json] presets. Adding a profile here unlocks lookup
     for [<name>_models]/[<name>_temperature]/[<name>_max_tokens] keys.
     Without the variant, [canonicalize] silently collapses the name to
     [Keeper_unified] and the runtime never reads the user's preset. *)
  | Nick0cave
  | Capacity_queue_trio
  | Vendor_mix_balanced
  | Cost_tier_ladder
  | Oauth_cli_rotate
  | Quality_sticky_glm51
  | Tool_use_strict
  | Resilient_breaker

val all : t list
(** [all] is exhaustive: every variant constructor of {!t} appears
    exactly once. Consumers that need to enumerate profiles should
    derive from this rather than maintaining a parallel list. *)

val to_string : t -> string
(** Canonical lowercase-snake-case name, matching the
    [<name>_models]/[<name>_temperature]/[<name>_max_tokens] convention
    in [config/cascade.json]. *)

val of_string_opt : string -> t option
(** Parse a raw cascade name into the variant. Handles legacy aliases
    ([oas-keeper_unified], [coding_first], [keeper_turn], [keeper_reply])
    by collapsing them to their canonical variant. Returns [None] for
    unknown names — use {!canonical} when you want a forced fallback. *)

val canonical : string -> t
(** [canonical raw] = [of_string_opt raw |> Option.value ~default]. *)

val default : t
val default_name : string
(** [default_name = to_string default = "keeper_unified"]. *)

val known_cascades : string list
(** [known_cascades = List.map to_string all]. Provided for consumers
    that still operate on strings (cascade.json key prefixes, metric
    label allow-list); new code should take {!t} directly. *)

val catalog_names : ?config_path:string -> unit -> string list
(** Live profile catalog discovered from the active [cascade.json].
    Discovery is delegated to {!Cascade_config_loader.load_catalog}, so
    profiles are surfaced from recognized cascade schema keys
    (for example [{name}_models], [{name}_temperature],
    [{name}_strategy], ...). When the file cannot be read, returns [[]]
    rather than synthesizing a hardcoded catalog. *)

val keeper_catalog_names : ?config_path:string -> unit -> string list
(** Assignable live profile names from {!catalog_names}, filtered by
    explicit [{name}_keeper_assignable = false] metadata in
    [cascade.json]. Read failures return [[]]. *)

val system_catalog_names : ?config_path:string -> unit -> string list
(** Live system-only profile names present in [cascade.json], selected
    by explicit [{name}_keeper_assignable = false] metadata. Read
    failures return [[]]. *)

val is_system_only_cascade : string -> bool
(** Exact-name membership check against the active config's
    {!system_catalog_names}. *)

val canonicalize_with_catalog : catalog:string list -> string -> string
(** Like {!canonicalize}, but resolves dynamic profiles against an explicit
    live catalog instead of the active config path. Intended for tests and
    server-side validation flows that already loaded the catalog. *)

val canonicalize : string -> string
(** [canonicalize raw = to_string (canonical raw)]. Existing
    string-based call sites continue to work; legacy aliases collapse to
    their canonical built-in name, live catalog names pass through, and
    unknown values fall back to {!default_name}. *)

(** {1 cascade.json key helpers} *)

val models_key_t : t -> string
val temperature_key_t : t -> string
val max_tokens_key_t : t -> string

(** String-based wrappers; first canonicalize, then build the key. *)
val models_key : string -> string
val temperature_key : string -> string
val max_tokens_key : string -> string
