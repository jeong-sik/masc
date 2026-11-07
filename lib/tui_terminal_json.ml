type context = Outside_string | In_string

(* An inside-string run from Yojson's canonical output has no literal JSON
   backslashes: the scanner emits those escape sequences separately. The
   sanitizer's supplementary-plane escapes can therefore be written as JSON
   surrogate-pair escapes without confusing them with input literals. *)
let json_supplementary_escapes text =
  if not (String.contains text '\\') then text
  else
    let out = Buffer.create (String.length text) in
    let length = String.length text in
    let rec loop i =
      if i < length then
        if text.[i] = '\\' && i + 10 <= length && text.[i + 1] = 'U' then
          let hex = String.sub text (i + 2) 8 in
          match int_of_string_opt ("0x" ^ hex) with
          | Some code when code > 0xffff && code <= 0x10ffff ->
            let value = code - 0x10000 in
            Buffer.add_string out (Printf.sprintf "\\u%04X\\u%04X"
              (0xd800 + (value lsr 10)) (0xdc00 + (value land 0x3ff)));
            loop (i + 10)
          | Some _ | None -> Buffer.add_char out text.[i]; loop (i + 1)
        else (Buffer.add_char out text.[i]; loop (i + 1)) in
    loop 0; Buffer.contents out

let sanitize_canonical_preview text =
  let out = Buffer.create (String.length text) in
  let length = String.length text in
  let emit context start stop =
    if stop > start then begin
      let rec printable at =
        at >= stop ||
        let byte = text.[at] in
        ((byte >= ' ' && byte <= '~') || (context = Outside_string && byte = '\n'))
        && printable (at + 1) in
      if printable start then Buffer.add_substring out text start (stop - start)
      else begin
        let value = String.sub text start (stop - start)
          |> Tui_terminal_text.escape_invisible in
        let value = match context with
          | Outside_string -> Tui_terminal_text.sanitize_terminal_lines value
          | In_string -> Tui_terminal_text.sanitize_terminal_text value
            |> json_supplementary_escapes in
        Buffer.add_string out value
      end
    end in
  let is_hex = function
    | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
    | _ -> false in
  let escape_length i =
    if i + 1 >= length then Some 1
    else match text.[i + 1] with
      | '"' | '\\' | '/' | 'b' | 'f' | 'n' | 'r' | 't' -> Some 2
      | 'u' ->
        let ending = min length (i + 6) in
        let rec all_hex at = at >= ending || (is_hex text.[at] && all_hex (at + 1)) in
        if all_hex (i + 2) then Some (ending - i) else None
      | _ -> None in
  let rec loop context start i =
    if i >= length then emit context start i
    else match context, text.[i] with
    | Outside_string, '"' ->
      emit context start i; Buffer.add_char out '"'; loop In_string (i + 1) (i + 1)
    | In_string, '"' ->
      emit context start i; Buffer.add_char out '"'; loop Outside_string (i + 1) (i + 1)
    | In_string, '\\' ->
      emit context start i;
      let count = match escape_length i with Some count -> count | None -> 1 in
      Buffer.add_substring out text i count;
      loop In_string (i + count) (i + count)
    | (Outside_string | In_string), _ -> loop context start (i + 1) in
  loop Outside_string 0 0; Buffer.contents out
