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

val of_string : string -> t option
(** ["delegate" | "reroute" | "inherit"], case- and whitespace-insensitive.
    [None] for anything else (no Unknown->Permissive collapse). *)

val delegates : t -> bool
(** [true] iff the effective policy intercepts images for delegation:
    [Delegate -> true], [Reroute -> false], [Inherit -> delegates default]. *)
