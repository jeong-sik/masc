(** An instant on the ledger, held to the whole second in UTC.

    Every source the ledger copies from (a verifier result's [recorded_at], a
    Goal's [created_at], a Task's [completed_at]) is whole-second RFC 3339. Holding
    the instant to the second makes the written form and the value one
    thing: an event read back is equal to the event written, and two instants
    compare the way their text does. *)

type t = private Ptime.t

val of_ptime : Ptime.t -> t
(** Truncates to the whole second. *)

val to_ptime : t -> Ptime.t
val compare : t -> t -> int
val equal : t -> t -> bool

val to_rfc3339 : t -> string
(** ["YYYY-MM-DDTHH:MM:SSZ"]. *)

val of_rfc3339 : string -> (t, string) result
(** Accepts only what {!to_rfc3339} writes. An offset other than [Z], a
    fraction, a lowercase [z] or a short field is refused, so a row written by
    something else cannot pass as the ledger's own. *)

val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result

(** A calendar day as a Goal's [due_date] writes it. *)
module Date : sig
  type t = private Ptime.date

  val of_string : string -> t option
  (** Four digits, [-], two digits, [-], two digits, and a day the calendar
      has. [2026-9-3], [2026-02-30] and [ 2026-09-03] are [None]. *)

  val to_string : t -> string
  val equal : t -> t -> bool
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
end
