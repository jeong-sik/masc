(** Opaque provider identifier — phantom-typed wrapper around the
    canonical-name string set in [Provider_adapter.cn_*].

    Created to address RFC-0038 §4.1: provider names should be
    type-distinguished from arbitrary strings so the compiler can
    block accidental cross-kind comparisons (e.g. comparing a
    provider id with a cascade name) and so the literal duplication
    of canonical names across ~14 files is forced through a single
    typed surface.

    Constructors are restricted to {!of_canonical}, which validates
    the input against the registered set, and to the named
    accessors ({!ollama}, {!claude}, ...) which mirror the
    [Provider_adapter.cn_*] constants.

    Equality compares the underlying string.  [to_string] returns
    the canonical name for serialization or interop with code that
    still takes [string].

    @since 2026-05-07 (RFC-0038 §5 Phase B) *)

type t = private string

(** {1 Construction} *)

val of_canonical : string -> t option
(** Return [Some t] iff [s] equals one of the canonical names
    registered in [Provider_adapter.cn_*].  [None] for any other
    string, including aliases, telemetry tags, or category labels.

    Use this at boundaries where a raw string arrives from config /
    JSON / environment and must be validated before being trusted as
    a provider id. *)

val of_canonical_exn : string -> t
(** Like {!of_canonical} but raises [Invalid_argument] on a value
    not in the canonical set.  Use when the failure should be
    treated as a programming error (e.g. tests, internal lookups). *)

(** {1 Comparison} *)

val equal : t -> t -> bool

val compare : t -> t -> int

(** {1 Conversion} *)

val to_string : t -> string

val matches_string : t -> string -> bool
(** [matches_string t s] is [String.equal (to_string t) s].
    Convenience for boundary code that has a raw [string] (e.g. an
    {!Provider_adapter.adapter} record's [canonical_name] field) and
    wants to compare against a known [t] without first validating
    the string through {!of_canonical}.  Useful for hot paths where
    validation overhead is unwanted. *)

(** {1 Stable accessors}

    One value per [Provider_adapter.cn_*] constant.  These shadow
    the existing [cn_*] strings with type-tagged equivalents.  Old
    [cn_*] symbols remain in {!Provider_adapter} as [string] aliases
    for backward compatibility — see RFC-0038 §5 Phase B for the
    migration plan. *)

val ollama : t
val llama : t
val claude : t
val claude_api : t
val codex : t
val codex_api : t
val gemini : t
val gemini_api : t
val kimi : t
val kimi_api : t
val kimi_coding : t
val glm : t
val glm_coding_plan : t
val openrouter : t
val custom : t

(** {1 Set membership} *)

val all_canonical : t list
(** All registered provider ids in declaration order.  Stable across
    runs and useful for iterating the provider catalog without
    reaching into [Provider_adapter.direct_adapters]. *)
