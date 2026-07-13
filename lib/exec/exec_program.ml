type t = { name : string }

type unknown = [ `Unknown of string ]

let of_string raw =
  if raw = ""
  then Error (`Unknown raw)
  else Ok { name = raw }
;;

let to_string t = t.name
let pp fmt t = Format.pp_print_string fmt t.name
let equal a b = String.equal a.name b.name
let to_yojson t = `String t.name
