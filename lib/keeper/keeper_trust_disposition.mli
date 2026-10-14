(** The disposition a Keeper's runtime trust projection shows: the one-word
    verdict next to its reason. *)

type t =
  | Pass
  | Alert
  | Blocked
  | Degraded
      (** The row was built without reading the Keeper, because its own row
          could not be built. *)

val to_wire : t -> string
(** ["Pass"], ["Alert"], ["Blocked"], ["Degraded"]: the [disposition] field of
    the trust JSON. *)

val requires_attention : t -> bool
(** [Pass] alone does not. *)
