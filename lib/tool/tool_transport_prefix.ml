let value = "mcp__masc__"
let length = String.length value
let has name = String.starts_with ~prefix:value name
let add name = value ^ name

let strip name =
  if String.length name > length && has name
  then String.sub name length (String.length name - length)
  else name
;;
