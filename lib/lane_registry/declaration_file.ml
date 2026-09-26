type t = string

let suffix = ".toml"

let of_name name =
  if String.length name = 0 || String.contains name '/' then None else Some name
;;

let of_file_name file_name =
  if Filename.check_suffix file_name suffix
  then of_name (Filename.chop_suffix file_name suffix)
  else None
;;

let to_string name = name
