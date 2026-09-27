type t = string

let suffix = ".toml"

(* The loader lists every immediate child whose name ends in [suffix], so the
   file [.toml] is a declaration too and its name is [""]. Only what cannot be
   an immediate child's name is refused. *)
let of_name name =
  if String.contains name '/' || String.contains name '\000' then None else Some name
;;

let of_file_name file_name =
  if Filename.check_suffix file_name suffix
  then of_name (Filename.chop_suffix file_name suffix)
  else None
;;

let to_string name = name
