type observation = Found of string | Missing | Unsupported | Unavailable
external item : string -> bool -> int * string = "masc_antigravity_keychain_item"
let read ~path = match item path false with
  | 0, value when String.trim value <> "" -> Found value
  | 1, _ -> Missing
  | 2, _ -> Unsupported
  | _ -> Unavailable
let clear ~path = match item path true with
  | (0 | 1 | 2), _ -> Ok ()
  | _ -> Error ()
