(** Per-keeper policy (RFC-keeper-vision-delegation-tool §2.4) for how an incoming
    image is handled. Resolved deterministically from persisted keeper config —
    NOT derived from runtime capability (RFC-0265 §3.4: capability is reassignable,
    so deriving the gate from it would make the same keeper flip behavior across
    turns). *)

type t =
  | Delegate
      (** Store the incoming image and replace it with a text placeholder; the
          image is read only via the [analyze_image] tool, never entering the
          conversation. *)
  | Reroute
      (** Leave the image inline; RFC-0265 reroutes the whole turn to a
          vision-capable runtime (pre-RFC behavior). *)
  | Inherit
      (** No explicit per-keeper choice — resolves to {!default}. *)

val default : t
(** [Reroute] — preserves pre-RFC behavior, so a keeper with no configured
    policy is unaffected. *)

val to_string : t -> string

val of_string_result : string -> (t, string) result
(** ["delegate" | "reroute" | "inherit"], case- and whitespace-insensitive.
    [Error] includes the unknown value and expected tokens. Use this for
    operator-authored TOML so typos fail loudly instead of falling through to a
    default policy. *)

val of_string : string -> t option
(** ["delegate" | "reroute" | "inherit"], case- and whitespace-insensitive.
    [None] for anything else. Prefer {!of_string_result} or
    {!of_string_or_log} at config boundaries so unknown values are not silent. *)

val of_string_or_log : ?source:string -> string -> t option
(** Option parser for legacy optional JSON/profile-default boundaries. Logs
    unknown values before returning [None]. *)

val resolve_optional : t option -> t
(** Resolve [Some Inherit] and absent per-keeper policy through the system
    default. Keeps default resolution at the policy boundary instead of each
    call site open-coding permissive fallbacks. *)

val delegates : t -> bool
(** [true] iff the effective policy intercepts images for delegation:
    [Delegate -> true], [Reroute -> false], [Inherit -> delegates default]. *)
