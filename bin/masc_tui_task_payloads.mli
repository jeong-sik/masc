(** Immutable Task data from one actual producer observation. The original
    list identity and its equal stable values stay together. No read freshness,
    workspace authority, timestamp, durable identity or cache is represented. *)
type t
val empty : t
val observe : Masc_domain.task list -> t
val values : t -> Masc_domain.task list
(** Constant-time access to the current observation's Task values. *)

type comparison
type preparation = Immediate of t | Compare of comparison
val prepare : previous:t -> t -> preparation
(** Constant-time decision. The same immutable producer list reuses its stable
    values; cold/empty reads keep the new values. New producer lists require
    full comparison. The caller still reads/adopts all fresh source metadata. *)
val finish : comparison -> t
(** Pure CPU work over captured immutable observations. New membership/order
    is retained; only exact typed-equal Tasks under unique prior IDs are reused.
    The result retains the new raw producer identity for the next observation.
    The caller must retain original source/request admission and cancellation. *)
