type t = string

let of_string model_id =
  let trimmed = String.trim model_id in
  if String.equal trimmed ""
  then Error "model_id must contain non-whitespace text"
  else if not (String.equal model_id trimmed)
  then Error "model_id must not have surrounding whitespace"
  else Ok model_id
;;

let to_string value = value
let equal = String.equal
let compare = String.compare
let hash = Hashtbl.hash
let pp = Format.pp_print_string
