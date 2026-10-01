(** The integer arithmetic of a payout (RFC-goal-candle-ledger 3.3, 3.4).

    Amounts are whole milli-candle. Nothing here uses floating point, because a
    float's [exp] and rounding can differ between machines and an amount must
    not. Every multiplication is checked against the 63-bit range before it is
    made: an amount that would overflow is refused, never wrapped. *)

type error =
  | Negative_total
  | Negative_share of int
  | No_weight  (** No weights, or they sum to zero. *)
  | Negative_weight of string
  | Duplicate_name of string
  | Rate_out_of_range of int  (** A rate or floor outside [0, 1000]. *)
  | Negative_hours of int
  | Overflow  (** An intermediate sum or product would not fit in an [int]. *)

val error_to_string : error -> string

val overdue_hours : due:Ptime.t -> passed_at:Ptime.t -> int
(** Whole hours from [due] to [passed_at], rounded down. [0] when [passed_at] is
    not later than [due]. *)

val deduction_coefficient :
  rate:int -> floor:int -> overdue_hours:int -> (int, error) result
(** In thousandths: [max floor (1000 - rate * overdue_hours)]. [rate] is the
    thousandths taken per overdue hour and [floor] is the least that is paid.
    Both must lie in [0, 1000]. The result is never above [1000], so finishing
    early never pays more. *)

val split : total:int -> (string * int) list -> ((string * int) list, error) result
(** [split ~total weights] gives each name [total * weight / sum of weights],
    rounded down. The milli-candle left over go one each to the names with the
    largest remainders. Equal remainders go to the name that sorts first, so the
    answer does not depend on the order the names are given in. The shares sum to
    [total] exactly. Names come back in the order they were given. *)

val deduct : coefficient:int -> int -> (int, error) result
(** [deduct ~coefficient share] is [share * coefficient / 1000], rounded down.
    [coefficient] must lie in [0, 1000]. A negative share is refused before any
    multiplication, including when the coefficient is zero. *)
