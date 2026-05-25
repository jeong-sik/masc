(** Canonical cascade name with no silent auto-normalization.
    All downstream consumers see only the canonical form. *)

type t = private string
(** Opaque — constructor enforces canonical prefix. *)

val of_string : string -> (t, [ `Invalid_prefix | `Empty ]) result
(** Parse a raw cascade name.
    - Accepts: "tier-group.X", "tier.X", "route.X" (canonical prefixes)
    - Rejects: bare "X" without prefix -> [`Invalid_prefix]
    - Rejects: empty string -> [`Empty] *)

val of_string_exn : string -> t
(** Development-time convenience. Raises [Failure] on invalid input. *)

val of_string_or : fallback:t -> string -> t
(** Parse a cascade name, returning [fallback] on invalid input instead of
    raising. Use at sites where the input may be a public (stripped) catalog
    name that lacks a canonical prefix. *)

val to_string : t -> string
(** Extract canonical string for profile_lookup, manifest emission,
    Prometheus labels. *)

val pp : Format.formatter -> t -> unit

val is_canonical_prefix : string -> bool
(** [true] if string starts with "tier-group.", "tier.", or "route.". *)
