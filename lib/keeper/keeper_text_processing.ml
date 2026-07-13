(** Keeper text normalization and legacy fragment diagnostics. *)

(* Pre-compiled regex patterns — compiled once at module init. *)
let re_whitespace = Re.Pcre.re "[ \t\r\n]+" |> Re.compile
let re_terminal_punct = Re.Pcre.re "[.!?。！？]$" |> Re.compile
let re_korean_ending =
  Re.Pcre.re "(다|요|니다|습니다|중입니다|함)$" |> Re.compile
let re_unclosed_bracket = Re.Pcre.re {|["'(\[{]$|} |> Re.compile
let re_trailing_punct = Re.Pcre.re "[:;,\\-]$" |> Re.compile
let re_trailing_connector =
  Re.Pcre.re "(and|or|with|to|for|그리고|또는|및)$" |> Re.compile

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

let normalize_proactive_text (raw : string) : string =
  raw
  |> Re.replace_string re_whitespace ~by:" "
  |> String.trim

let extract_checkin_text (raw : string) : string option =
  let cleaned = normalize_proactive_text raw in
  if cleaned = "" then None else Some cleaned

let proactive_has_terminal_punct (s : string) : bool =
  let t = String.trim s in
  t <> "" && Re.execp re_terminal_punct t

let proactive_has_terminal_korean_ending (s : string) : bool =
  let t = String.trim s in
  t <> "" && Re.execp re_korean_ending t

let proactive_has_terminal_ending (s : string) : bool =
  proactive_has_terminal_punct s || proactive_has_terminal_korean_ending s

let proactive_looks_fragmentary (s : string) : bool =
  let t = String.trim s in
  t = ""
  || Re.execp re_unclosed_bracket t
  || Re.execp re_trailing_punct t

let looks_fragmentary_history_text (raw : string) : bool =
  let t = normalize_proactive_text raw in
  if t = "" then true
  else
    let hard_fragment = proactive_looks_fragmentary t in
    let has_terminal = proactive_has_terminal_ending t in
    let ends_korean_sentence = Re.execp re_korean_ending t in
    let short_unterminated =
      (not has_terminal) && (not ends_korean_sentence) && String.length t <= 24
    in
    let trailing_connector =
      (not has_terminal)
      && Re.execp re_trailing_connector (String.lowercase_ascii t)
    in
    hard_fragment || short_unterminated || trailing_connector
