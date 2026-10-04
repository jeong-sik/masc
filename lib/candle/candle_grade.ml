type t = string
let to_string value = value
let of_string value =
  if String.length value = 0 then None
  else if String.for_all (function
    | 'a' .. 'z' | '0' .. '9' | '_' | '-' -> true
    | _ -> false) value then Some value
  else None
