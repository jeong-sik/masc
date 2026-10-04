type t = string

let prefix = "wmsg-"
let random_bytes = 16
let create () = Random_id.prefixed ~prefix ~bytes:random_bytes
let to_string value = value

let of_string value =
  let prefix_length = String.length prefix in
  let expected_length = prefix_length + (2 * random_bytes) in
  let rec lower_hex index =
    if index = expected_length then true
    else match value.[index] with
      | '0' .. '9' | 'a' .. 'f' -> lower_hex (index + 1)
      | _ -> false
  in
  if String.length value = expected_length
     && String.starts_with ~prefix value && lower_hex prefix_length
  then Ok value
  else Error "workspace request id must be wmsg- followed by 32 lowercase hexadecimal digits"
