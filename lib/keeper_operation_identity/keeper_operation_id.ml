type t = string

let max_length = 128

let of_string value =
  let length = String.length value in
  let rec valid_chars index =
    if index = length
    then true
    else
      match value.[index] with
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' | '.' ->
        valid_chars (index + 1)
      | _ -> false
  in
  if length = 0
  then Error "operation_id must not be empty"
  else if length > max_length
  then Error "operation_id exceeds 128 bytes"
  else if String.equal value "." || String.equal value ".."
  then Error "operation_id must not be a path segment"
  else if valid_chars 0
  then Ok value
  else Error "operation_id contains an unsupported character"
;;

let to_string value = value
let equal = String.equal
