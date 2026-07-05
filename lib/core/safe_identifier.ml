(** Shared validation contracts for externally supplied stable identifiers. *)

let portable_name_pattern = "[A-Za-z0-9._-]+"

let portable_name_re =
  Re.Pcre.re ("^" ^ portable_name_pattern ^ "$") |> Re.compile
;;

let is_portable_name name =
  (not (String.equal name "")) && Re.execp portable_name_re name
;;

let portable_name_error ~field =
  Printf.sprintf "%s must match %s" field portable_name_pattern
;;
