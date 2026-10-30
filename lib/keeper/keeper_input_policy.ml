type t = Small | Wide
let default = Small
let to_string = function Small -> "small" | Wide -> "wide"
let of_string = function "small" -> Some Small | "wide" -> Some Wide | _ -> None
let to_yojson policy = `String (to_string policy)
