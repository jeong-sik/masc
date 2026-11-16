(* One rule for a configured official-client account home. Runtime TOML and
   direct client configurations are separate entry points, so both call this
   parser instead of maintaining copies of the path predicate. *)
let expand_tilde_under ~home path =
  if String.equal path "~" || String.starts_with ~prefix:"~/" path
  then (
    match home with
    | Some h ->
      let h = String.trim h in
      if h = "" || Filename.is_relative h
      then path
      else if String.equal path "~"
      then h
      else Filename.concat h (String.sub path 2 (String.length path - 2))
    | None -> path)
  else path

let of_string_under ~home raw =
  if String.contains raw '\000'
  then Error "account_home contains a NUL byte"
  else if not (String_util.is_valid_utf8 raw)
  then Error "account_home is not valid UTF-8"
  else if raw = "" || raw <> String.trim raw
  then Error "account_home must be a non-empty absolute path without surrounding whitespace"
  else
    let expanded = expand_tilde_under ~home raw in
    if Filename.is_relative expanded
    then Error "account_home must be a non-empty absolute path without surrounding whitespace"
    else Ok expanded

let of_string raw = of_string_under ~home:(Sys.getenv_opt "HOME") raw

let of_inherited home =
  if home = "" || home <> String.trim home
  then Error "inherited CLI home must be non-empty without surrounding whitespace"
  else
    let expanded = expand_tilde_under ~home:(Sys.getenv_opt "HOME") home in
    let absolute =
      if Filename.is_relative expanded then Filename.concat (Sys.getcwd ()) expanded else expanded
    in
    of_string absolute

let is_valid home = Result.is_ok (of_string home)
