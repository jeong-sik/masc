type half_life = Off | Hours of int

type error =
  | Negative_amount of int
  | Non_positive_hours of int
  | Reversed_interval

let error_to_string = function
  | Negative_amount amount -> Printf.sprintf "negative Candle amount: %d" amount
  | Non_positive_hours hours -> Printf.sprintf "half-life hours must be positive: %d" hours
  | Reversed_interval -> "Candle decay interval ends before it starts"
;;

let half_life_of_hours hours =
  if hours > 0 then Ok (Hours hours) else Error (error_to_string (Non_positive_hours hours))
;;

(* RFC 3.1.1 fixes these 128 bits as monetary precision. All constants are
   immutable, derived with exact Zarith arithmetic; see the arithmetic contract. *)
let fractional_bits = 128
let scale = Z.shift_left Z.one fractional_bits
let half = Z.shift_right scale 1

let binary_factors =
  let rec factors count previous =
    if count = 0
    then []
    else
      let factor = Z.sqrt (Z.mul previous scale) in
      factor :: factors (count - 1) factor
  in
  factors fractional_bits half
;;

let fractional_coefficient fraction =
  if Z.equal fraction scale
  then half
  else
    let rec multiply bit coefficient = function
      | [] -> coefficient
      | factor :: rest ->
        let coefficient =
          if Z.testbit fraction bit
          then Z.shift_right (Z.mul coefficient factor) fractional_bits
          else coefficient
        in
        multiply (bit - 1) coefficient rest
    in
    multiply (fractional_bits - 1) scale binary_factors
;;

let elapsed_seconds ~since ~at =
  let days, picoseconds =
    Ptime.Span.to_d_ps (Ptime.diff (Candle_time.to_ptime at) (Candle_time.to_ptime since))
  in
  Z.add
    (Z.mul (Z.of_int days) (Z.of_int 86_400))
    (Z.of_int64 (Int64.div picoseconds 1_000_000_000_000L))
;;

let remaining_for_hours ~hours ~since ~at ~amount_milli =
  let amount = Z.of_int amount_milli in
  let period = Z.mul (Z.of_int hours) (Z.of_int 3_600) in
  let whole, remainder = Z.div_rem (elapsed_seconds ~since ~at) period in
  if Z.compare whole (Z.of_int (Z.numbits amount)) >= 0
  then 0
  else
    (* This conversion is bounded by the public amount's bit length, never by
       the elapsed interval or the configured hours. *)
    let whole_bits = Z.to_int whole in
    if Z.equal remainder Z.zero
    then Z.to_int (Z.shift_right amount whole_bits)
    else
      let fraction, discarded = Z.div_rem (Z.mul remainder scale) period in
      let fraction = if Z.equal discarded Z.zero then fraction else Z.succ fraction in
      let coefficient = fractional_coefficient fraction in
      (* One monetary floor: halving the amount before this multiplication
         would incorrectly lose money, e.g. 3 milli after 1.5 periods. *)
      Z.to_int (Z.shift_right (Z.mul amount coefficient) (fractional_bits + whole_bits))
;;

let remaining ~half_life ~since ~at ~amount_milli =
  if amount_milli < 0
  then Error (Negative_amount amount_milli)
  else if Candle_time.compare at since < 0
  then Error Reversed_interval
  else
    match half_life with
    | Hours hours when hours <= 0 -> Error (Non_positive_hours hours)
    | Off -> Ok amount_milli
    | Hours hours ->
      if amount_milli = 0 || Candle_time.equal since at
      then Ok amount_milli
      else Ok (remaining_for_hours ~hours ~since ~at ~amount_milli)
;;
