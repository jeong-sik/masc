type t = int

let initial = 0
let equal = Int.equal

let next generation =
  if Int.equal generation Int.max_int
  then Error "Board attention partition generation is exhausted"
  else Ok (generation + 1)
;;

let is_direct_successor ~previous generation =
  not (Int.equal previous Int.max_int)
  && Int.equal generation (previous + 1)
;;

let to_yojson generation = `Int generation

let of_yojson = function
  | `Int generation when generation >= 0 -> Ok generation
  | `Int _ -> Error "Board attention partition generation must be nonnegative"
  | _ -> Error "Board attention partition generation must be an integer"
;;
