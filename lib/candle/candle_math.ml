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
  | Overflow -> "the arithmetic does not fit in 63 bits"
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

(* [a * b / c] and [a * b mod c], with the product checked first. *)
let scaled ~a ~b ~c =
  if a > 0 && b > max_int / a
  then Error Overflow
  else (
    let product = a * b in
    Ok (product / c, product mod c))
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
       else if sum > max_int - weight
       then Error Overflow
       else Ok (sum + weight))
    (Ok 0)
    weights
;;

(* The names that get one more milli-candle, in the order they get it: the
   largest remainder first, and the name that sorts first among equals. *)
let by_remainder (name_a, remainder_a) (name_b, remainder_b) =
  match Int.compare remainder_b remainder_a with
  | 0 -> String.compare name_a name_b
  | order -> order
;;

let split ~total weights =
  if total < 0
  then Error Negative_total
  else
    let* () =
      match first_duplicate [] weights with
      | Some name -> Error (Duplicate_name name)
      | None -> Ok ()
    in
    let* sum = weight_sum weights in
    if sum = 0
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
        |> List.sort by_remainder
        |> List.filteri (fun index _ -> index < left)
        |> List.map fst
      in
      Ok
        (List.map
           (fun (name, base, _) -> name, if List.mem name extra then base + 1 else base)
           parts)
;;

let deduct ~coefficient share =
  let* () = check_thousandths coefficient in
  if share < 0 then Error (Negative_share share)
  else
    let* deducted, (_ : int) = scaled ~a:share ~b:coefficient ~c:thousand in
    Ok deducted
;;
