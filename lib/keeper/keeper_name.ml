(** Keeper name validation. *)

let valid_re = Re.Pcre.re "^[A-Za-z0-9._-]+$" |> Re.compile

let validate name =
  name <> "" && Re.execp valid_re name
