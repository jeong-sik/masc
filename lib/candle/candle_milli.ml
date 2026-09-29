type t = int

type error =
  | Negative of int
  | Overflow

let error_to_string = function
  | Negative amount -> Printf.sprintf "milli-candle amount %d is negative" amount
  | Overflow -> "milli-candle amount does not fit a 63-bit integer"
;;

let zero = 0

let of_int amount = if amount < 0 then Error (Negative amount) else Ok amount
let to_int amount = amount

(* Both operands are non-negative, so a sum that wrapped past [max_int] is the
   only way for the result to be negative. *)
let add left right =
  let total = left + right in
  if total < 0 then Error Overflow else Ok total
;;

let sum amounts =
  List.fold_left
    (fun total amount -> Result.bind total (fun so_far -> add so_far amount))
    (Ok zero)
    amounts
;;

let sub left right = if right > left then None else Some (left - right)
let equal = Int.equal
let compare = Int.compare
let to_yojson amount = `Int amount

let of_yojson json =
  Result.bind (Candle_json.as_int json) (fun amount ->
    Result.map_error error_to_string (of_int amount))
;;
