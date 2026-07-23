let render ~persona_extended =
  let s = String_util.escape_xml (String.trim persona_extended) in
  if s = "" then None else Some (Printf.sprintf "<persona>\n%s\n</persona>" s)
