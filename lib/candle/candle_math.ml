type share_rounding = Largest_remainder | Down
type tie_break = Name_ascending | Name_descending
type deduction_rounding = Floor | Ceil
type distribution = {
  share_rounding : share_rounding;
  tie_break : tie_break;
  deduction_rounding : deduction_rounding;
}

(* See candle_math.mli. *)

let ( let* ) = Result.bind

type error =
  | Negative_total
  | Negative_share of int
  | No_weight
  | Negative_weight of string
  | Duplicate_name of string
  | Rate_out_of_range of int
  | Negative_hours of int
  | Overflow

let error_to_string = function
  | Negative_total -> "the total is negative"
  | Negative_share share -> Printf.sprintf "the share %d is negative" share
  | No_weight -> "there is no weight to share by"
  | Negative_weight name -> Printf.sprintf "the weight of %s is negative" name
  | Duplicate_name name -> Printf.sprintf "%s is named twice" name
  | Rate_out_of_range value -> Printf.sprintf "%d is outside 0..1000" value
  | Negative_hours hours -> Printf.sprintf "%d hours is negative" hours
  | Overflow -> "the final amount does not fit in an integer"
;;

let thousand = 1000
let hours_per_day = 24
let picoseconds_per_hour = 3_600_000_000_000_000L

let overdue_hours ~due ~passed_at =
  let days, picoseconds = Ptime.Span.to_d_ps (Ptime.diff passed_at due) in
  if days < 0
  then 0
  else (days * hours_per_day) + Int64.to_int (Int64.div picoseconds picoseconds_per_hour)
;;

let check_thousandths value =
  if value < 0 || value > thousand then Error (Rate_out_of_range value) else Ok ()
;;

let deduction_coefficient ~rate ~floor ~overdue_hours =
  let* () = check_thousandths rate in
  let* () = check_thousandths floor in
  if overdue_hours < 0
  then Error (Negative_hours overdue_hours)
  else (
    (* A rate of zero takes nothing however late; otherwise the product is
       checked before it is made. *)
    let taken =
      if rate = 0
      then 0
      else if overdue_hours > max_int / rate
      then max_int
      else rate * overdue_hours
    in
    Ok (max floor (thousand - taken)))
;;

(* The callers validate nonnegative inputs and a positive denominator. Keep
   the product and remainder exact; only the public monetary quotient is int. *)
let scaled ~a ~b ~c =
  let quotient, remainder = Z.div_rem (Z.mul (Z.of_int a) (Z.of_int b)) c in
  if Z.fits_int quotient
  then Ok (Z.to_int quotient, remainder)
  else Error Overflow
;;

let rec first_duplicate seen = function
  | [] -> None
  | (name, _) :: rest ->
    if List.mem name seen then Some name else first_duplicate (name :: seen) rest
;;

let weight_sum weights =
  List.fold_left
    (fun sum (name, weight) ->
       let* sum = sum in
       if weight < 0
       then Error (Negative_weight name)
       else Ok (Z.add sum (Z.of_int weight)))
    (Ok Z.zero)
    weights
;;

(* The names that get one more milli-candle, in the order they get it: the
   largest remainder first, with the explicit name-order policy for equals. *)
let by_remainder ~tie_break (name_a, remainder_a) (name_b, remainder_b) =
  match Z.compare remainder_b remainder_a with
  | 0 -> (match tie_break with Name_ascending -> String.compare name_a name_b
    | Name_descending -> String.compare name_b name_a)
  | order -> order
;;

let split ~rounding ~tie_break ~total weights =
  if total < 0
  then Error Negative_total
  else
    let* () =
      match first_duplicate [] weights with
      | Some name -> Error (Duplicate_name name)
      | None -> Ok ()
    in
    let* sum = weight_sum weights in
    if Z.equal sum Z.zero
    then Error No_weight
    else
      let* parts =
        List.fold_left
          (fun parts (name, weight) ->
             let* parts = parts in
             let* base, remainder = scaled ~a:total ~b:weight ~c:sum in
             Ok ((name, base, remainder) :: parts))
          (Ok [])
          weights
      in
      let parts = List.rev parts in
      let left = total - List.fold_left (fun acc (_, base, _) -> acc + base) 0 parts in
      let extra =
        List.map (fun (name, _, remainder) -> name, remainder) parts
        |> List.sort (by_remainder ~tie_break)
        |> List.filteri (fun index _ -> match rounding with
      | Largest_remainder -> index < left | Down -> false)
        |> List.map fst
      in
      Ok
        (List.map
           (fun (name, base, _) -> name, if List.mem name extra then base + 1 else base)
           parts)
;;

let deduct ~rounding ~coefficient share =
  let* () = check_thousandths coefficient in
  if share < 0 then Error (Negative_share share)
  else
    let* deducted, remainder = scaled ~a:share ~b:coefficient ~c:(Z.of_int thousand) in
    Ok (match rounding with
      | Floor -> deducted
      | Ceil -> if Z.equal remainder Z.zero then deducted else deducted + 1)
;;
