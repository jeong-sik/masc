type selector = Builtin of string | Lane_addon of string

let parse value =
  let prefix = "addon:" in
  if String.starts_with ~prefix value then
    let name = String.sub value (String.length prefix) (String.length value - String.length prefix) in
    if name <> "" && String.equal name (String.trim name)
    then Lane_addon name else Builtin value
  else Builtin value

let matches ~lane_addon ~name value =
  match parse value with
  | Builtin denied -> String.equal denied name
  | Lane_addon denied -> lane_addon && String.equal denied name
