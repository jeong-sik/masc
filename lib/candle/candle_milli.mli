(** Milli-candle, the ledger's one unit of account: 1 Candle = 1000
    milli-candle. Half a Candle is 500.

    A non-negative integer. No float appears anywhere in the ledger. Every
    operation that could leave 63 bits or go below zero says so in its result
    instead of wrapping or clamping. *)

type t = private int

type error =
  | Negative of int
  | Overflow

val error_to_string : error -> string
val zero : t

val of_int : int -> (t, error) result
(** [Error (Negative n)] for [n < 0]. *)

val to_int : t -> int

val add : t -> t -> (t, error) result
(** [Error Overflow] when the sum does not fit a 63-bit integer. *)

val sum : t list -> (t, error) result

val sub : t -> t -> t option
(** [sub a b] is [None] when [b] is larger than [a]. A balance never goes below
    zero and is never clamped to it. *)

val equal : t -> t -> bool
val compare : t -> t -> int
val to_yojson : t -> Yojson.Safe.t

val of_yojson : Yojson.Safe.t -> (t, string) result
(** A JSON integer only. A float, a string or a negative number is refused. *)
