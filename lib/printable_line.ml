let cut_mark = "..."

(* The bytes kept as they are. Any other byte, and the backslash that marks
   one, is written as [\xNN]. *)
let written_as_is byte = byte >= ' ' && byte <= '~' && byte <> '\\'

let hex_value byte =
  if byte >= '0' && byte <= '9' then Some (Char.code byte - Char.code '0')
  else if byte >= 'A' && byte <= 'F' then Some (Char.code byte - Char.code 'A' + 10)
  else None

let write ~limit text =
  let written = Buffer.create (String.length text) in
  let rec add index =
    if index = String.length text then Buffer.contents written
    else (
      let byte = text.[index] in
      let piece =
        if written_as_is byte then String.make 1 byte
        else Printf.sprintf "\\x%02X" (Char.code byte)
      in
      if Buffer.length written + String.length piece > limit
      then Buffer.contents written ^ cut_mark
      else (
        Buffer.add_string written piece;
        add (index + 1)))
  in
  add 0

(* The pieces the writer leaves: a byte written as it is, and [\xNN] for one
   that is not. A cut falls between pieces, so the mark after it is three
   more bytes written as they are. *)
let rec written_pieces raw index =
  if index = String.length raw then true
  else if raw.[index] = '\\' then
    index + 4 <= String.length raw
    && raw.[index + 1] = 'x'
    && (match hex_value raw.[index + 2], hex_value raw.[index + 3] with
        | Some high, Some low -> not (written_as_is (Char.chr ((16 * high) + low)))
        | Some _, None | None, (Some _ | None) -> false)
    && written_pieces raw (index + 4)
  else written_as_is raw.[index] && written_pieces raw (index + 1)

let written ~limit raw =
  let length = String.length raw in
  let cut = length <= limit + String.length cut_mark && String.ends_with ~suffix:cut_mark raw in
  (length <= limit || cut) && written_pieces raw 0
