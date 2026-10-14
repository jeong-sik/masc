(** The disposition a Keeper's runtime trust projection shows: the one-word
    verdict next to its reason. *)

type t =
  | Pass
  | Alert
  | Blocked
  | Degraded
      (** The row was built without reading the Keeper, because its own row
          could not be built. *)

val all : t list
(** Every disposition, in declaration order. *)

val to_wire : t -> string
(** ["Pass"], ["Alert"], ["Blocked"], ["Degraded"]: the [disposition] field of
    the trust JSON. The dashboard narrows that field to its own closed list
    ([TRUST_DISPOSITIONS]). That list and {!all} are each checked against
    [dashboard/src/api/fixtures/trust-dispositions.json], so a value added,
    renamed or removed here fails a test until the fixture and the dashboard
    list change with it. *)

val of_wire : string -> t option
(** The disposition whose {!to_wire} is the string; [None] for any other. *)

val requires_attention : t -> bool
(** [Pass] alone does not. *)
