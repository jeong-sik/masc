(** Deterministic exponential wallet decay (RFC-goal-candle-ledger 3.1.1).
    Pure: callers pass a whole-second interval and an explicit half-life.
    No clock, file, mutable state or floating-point exponential is used. *)

type half_life = Off | Hours of int
(** [Hours] must contain a positive public integer. The constructor remains
    visible for closed pattern matching; {!remaining} also rejects invalid
    constructed values before applying any identity or zero shortcut. *)

type error =
  | Negative_amount of int
  | Non_positive_hours of int
  | Reversed_interval

val error_to_string : error -> string
val half_life_of_hours : int -> (half_life, string) result
(** The config/event boundary constructor: rejects zero and negative hours. *)

val remaining
  : half_life:half_life
  -> since:Candle_time.t
  -> at:Candle_time.t
  -> amount_milli:int
  -> (int, error) result
(** [Off] and equal instants preserve the amount. A reversed interval or a
    negative amount is an error even under [Off]. [Hours h] uses exact whole
    seconds and a Zarith period [h * 3600], so large periods never wrap.

    Economic calculation contract: Q128 coefficients. Split elapsed periods
    into a whole part and a fraction; round the fractional exponent upward
    to 128 binary fractional bits. Binary factors are obtained by descending
    exact integer square roots, rounded down, and coefficient products round
    down. Multiply the original amount by the coefficient, then apply the
    whole-period power of two and the Q128 scale in ONE final downward shift.
    Do not round the amount before the fractional multiplication.

    Exact whole half-lives yield [floor(amount / 2^periods)]. Fractional
    results are conservative fixed-point approximations, never greater than
    the real exponential result. Before final monetary flooring, coefficient
    quantization loses less than [641 * amount / 2^128] milli-Candle. With
    public amount [< 2^62] this is below [641 * 2^-66], hence below one milli.
    The final integer may be one below the floor of the ideal real result;
    equality with that real floor is NOT the calculation contract. On the
    supported whole-second inputs results are nonincreasing with elapsed
    time. Details and the monotonicity bound are in
    [docs/design/candle-decay-arithmetic.md]. *)
