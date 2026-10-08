(* ECMAScript Number.isSafeInteger uses the contiguous exact integer range of
   IEEE-754 binary64: -(2^53-1) through 2^53-1. Compare integer inputs before any
   float conversion so a value beyond that boundary cannot round into it. *)
let max_safe_integer = 9_007_199_254_740_991L
let min_safe_integer = Int64.neg max_safe_integer

let in_range value =
  value >= min_safe_integer && value <= max_safe_integer
  && value >= Int64.of_int min_int && value <= Int64.of_int max_int

let of_json (json : Yojson.Safe.t) =
  let error () = Error "expected a JSON integer in the ECMAScript safe-integer and OCaml int range" in
  match json with
  | `Int value when in_range (Int64.of_int value) -> Ok value
  | `Float value when Float.is_finite value && Float.trunc value = value
      && value >= Int64.to_float min_safe_integer
      && value <= Int64.to_float max_safe_integer ->
      let integer = Int64.of_float value in
      if in_range integer then Ok (Int64.to_int integer) else error ()
  | `Int _ | `Float _ | `Intlit _ | `Assoc _ | `List _ | `String _ | `Bool _ | `Null -> error ()
