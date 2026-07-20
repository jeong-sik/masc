(** UTF-8-safe Keeper text operations. *)

let utf8_char_width s i =
  let byte = Char.code s.[i] in
  if byte land 0x80 = 0 then 1
  else if byte land 0xE0 = 0xC0 then 2
  else if byte land 0xF0 = 0xE0 then 3
  else if byte land 0xF8 = 0xF0 then 4
  else 1

let truncate_utf8_prefix ~max_bytes s =
  let max_bytes = max 0 max_bytes in
  let len = String.length s in
  if len <= max_bytes then s, false
  else
    let rec loop i =
      if i >= len
      then i
      else
        let next = i + utf8_char_width s i in
        if next > max_bytes then i else loop next
    in
    String.sub s 0 (loop 0), true
