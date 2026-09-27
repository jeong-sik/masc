(* One rule for a configured official-client account home. Runtime TOML and
   direct client configurations are separate entry points, so both call this
   parser instead of maintaining copies of the path predicate. *)
let of_string home =
  if String.contains home '\000'
  then Error "account_home contains a NUL byte"
  else if not (String_util.is_valid_utf8 home)
  then Error "account_home is not valid UTF-8"
  else if home = "" || home <> String.trim home || Filename.is_relative home
  then Error "account_home must be a non-empty absolute path without surrounding whitespace"
  else Ok home

let of_inherited home =
  if home = "" || home <> String.trim home
  then Error "inherited CLI home must be non-empty without surrounding whitespace"
  else
    let absolute =
      if Filename.is_relative home then Filename.concat (Sys.getcwd ()) home else home
    in
    of_string absolute

let is_valid home = Result.is_ok (of_string home)
