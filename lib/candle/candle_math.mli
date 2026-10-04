type share_rounding = Largest_remainder | Down
type tie_break = Name_ascending | Name_descending
type deduction_rounding = Floor | Ceil
type distribution = {
  share_rounding : share_rounding;
  tie_break : tie_break;
  deduction_rounding : deduction_rounding;
}

(** The integer arithmetic of a payout (RFC-goal-candle-ledger 3.3, 3.4).

    Amounts are whole milli-candle. Nothing here uses floating point, because a
    float's [exp] and rounding can differ between machines and an amount must
    not. Intermediate products, weight sums and remainders are exact Zarith
    integers. Public amounts remain [int]; a result outside that range is
    refused, never wrapped. *)

type error =
  | Negative_total
  | Negative_share of int
  | No_weight  (** No weights, or they sum to zero. *)
  | Negative_weight of string
  | Duplicate_name of string
  | Rate_out_of_range of int  (** A rate or floor outside [0, 1000]. *)
  | Negative_hours of int
  | Overflow  (** A final public amount would not fit in an [int]. *)

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

val split : rounding:share_rounding -> tie_break:tie_break -> total:int -> (string * int) list -> ((string * int) list, error) result
(** [split ~total weights] gives each name [total * weight / sum of weights],
    rounded down. [Down] leaves the remainder unissued; [Largest_remainder]
    gives the milli-candle left over one each to the names with the
    largest remainders. Equal remainders follow the explicit [tie_break], so the
    answer does not depend on the order the names are given in. With [Largest_remainder], the shares sum to [total] exactly. Names come back in the order they were given. *)

val deduct : rounding:deduction_rounding -> coefficient:int -> int -> (int, error) result
(** [deduct ~coefficient share] is [share * coefficient / 1000], rounded by the explicit policy.
    [coefficient] must lie in [0, 1000]. A negative share is refused before any
    multiplication, including when the coefficient is zero. *)
