(** Checked cumulative credits from the authoritative Candle ledger.
    Values are never clamped or wrapped. This projection does not authorize
    a recipient: the settlement boundary validates durable candidate evidence. *)
type t
type error = Duplicate_payment of string | Balance_overflow of string
val error_to_string : error -> string
val empty : t
val balance : t -> keeper:string -> int
val credit : t -> Candle_payment.t -> (t, error) result
(** Atomically add every allocation, or return an error without a partial
    result. A Goal can be credited only once. *)
val of_events : Candle_event.t list -> (t, error) result
(** Replay paid facts in order. Other facts do not change balances. *)
