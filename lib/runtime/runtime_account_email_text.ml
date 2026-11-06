type t = string

let max_bytes = 254

let displayable_byte char =
  let code = Char.code char in
  code > 0x20 && code <> 0x7f

let of_string text =
  let length = String.length text in
  if length = 0 || length > max_bytes || not (String.is_valid_utf_8 text) then None
  else if String.for_all displayable_byte text then Some text
  else None

let to_string email = email
