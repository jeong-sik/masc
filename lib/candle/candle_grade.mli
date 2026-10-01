(** Operator-selected payout grades. Amounts belong to Candle configuration. *)
type t = Trivial | Small | Medium | Large | Epic
val all : t list
val to_string : t -> string
val of_string : string -> t option
