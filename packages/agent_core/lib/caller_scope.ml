type t = string

let of_string value =
  if String.trim value = ""
  then Error "caller scope must not be blank"
  else Ok value
;;

let to_string t = t
let to_json t = `String t

let of_json = function
  | `String value -> of_string value
  | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null ->
    Error "caller scope must be a JSON string"
;;
