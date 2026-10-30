type t = string
type refusal = Too_short | Not_printable

let minimum_length = 16
let is_visible_ascii c = Char.code c >= 33 && Char.code c <= 126

let of_text text =
  let token = String.trim text in
  if String.length token < minimum_length
  then Error Too_short
  else if not (String.for_all is_visible_ascii token)
  then Error Not_printable
  else Ok token

let to_string token = token
let equal = String.equal

let refusal_message = function
  | Too_short ->
    Printf.sprintf "it holds fewer than %d characters" minimum_length
  | Not_printable -> "it holds a space, a control character or a non-ASCII character"
