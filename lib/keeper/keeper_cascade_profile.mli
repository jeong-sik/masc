(** Canonical keeper cascade profile names and legacy alias normalization.

    Keepers historically used stringly-typed cascade names in TOML, runtime
    metadata, telemetry labels, and cascade.json lookups. This module is the
    SSOT for the active keeper cascade profile and the legacy aliases that must
    continue to resolve to it.

    Three keeper-assignable profiles and one system-only profile (Tool_rerank).
    Phase-routing names ("local_only", "local_recovery") are NOT variants —
    they pass through [canonicalize_with_catalog] as catalog names.

    @since 0.9.5 *)

(** SSOT variant for the 3+1 cascade model.

    Three keeper-assignable profiles ({!Big_three}, {!Underdog}, {!Local}) and
    one system-only profile ({!Tool_rerank}).

    Adding a new profile is a compile-time event: add a variant here, then
    exhaustive [match] sites flag every consumer that needs to handle it.
    Personal/playground-only cascades must NOT be added here — they live in
    [$MASC_BASE_PATH/.masc/playground/.../cascade.json] only. *)
type t =
  | Big_three
  | Underdog
  | Local
  | Tool_rerank

val all : t list
(** [all] is exhaustive: every variant constructor of {!t} appears
    exactly once. *)

val to_string : t -> string
(** Canonical lowercase-snake-case name. *)

val of_string_opt : string -> t option
(** Parse a raw cascade name into the variant. Handles legacy aliases
    by collapsing them to [Big_three]. Returns [None] for unknown names
    and phase-routing names ("local_only", "local_recovery"). *)

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

val keeper_catalog_names : ?config_path:string -> unit -> string list
(** Assignable live profile names from {!catalog_names}, filtered by
    [keeper_assignable] metadata. *)

val system_catalog_names : ?config_path:string -> unit -> string list
(** Live system-only profile names present in [cascade.json]. *)

val is_system_only_cascade : string -> bool
(** Exact-name membership check against the active config's
    {!system_catalog_names}. *)

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
