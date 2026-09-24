(* One rule for a configured official-client account home. Runtime TOML and
   direct client configurations are separate entry points, so both call this
   parser instead of maintaining copies of the path predicate. *)
let of_string home =
  if home = "" || home <> String.trim home || Filename.is_relative home
  then Error "account_home must be a non-empty absolute path without surrounding whitespace"
  else Ok home

let is_valid home = Result.is_ok (of_string home)
