type key =
  | Named of { name : string; advertised : bool }
  | Advertised_char of string
  | Other_char

type event =
  | Surface_opened of { from : string option; to_ : string }
  | Key_unchanged of { surface : string; key : key }
  | Capped of { limit : int }

(* A terminal that does not speak the Kitty keyboard protocol sends these keys
   as one raw byte, and the handlers match both spellings. The trace writes the
   word either way, so one key is one value. *)
let control_word byte =
  match byte with
  | '\r' | '\n' -> Some "enter"
  | '\t' -> Some "tab"
  | '\127' -> Some "backspace"
  | '\000' -> Some "ctrl-space"
  | '\001' .. '\026' ->
    Some ("ctrl-" ^ String.make 1 (Char.chr (Char.code byte + 96)))
  | '\028' -> Some "ctrl-backslash"
  | '\029' -> Some "ctrl-right-bracket"
  | '\030' -> Some "ctrl-caret"
  | '\031' -> Some "ctrl-underscore"
  | _ -> None

(* The longest word the decoder spells, [ctrl-alt-shift-pageup], with room. *)
let max_word_bytes = 32

(* The decoder names a key that is not text with lowercase ASCII words joined
   by hyphens. Typed text reaches it one character at a time, so a string of
   two or more characters in this shape is a name and never a draft. *)
let is_word text =
  let length = String.length text in
  length >= 2
  && length <= max_word_bytes
  && String.for_all
       (function 'a' .. 'z' | '0' .. '9' | '-' -> true | _ -> false)
       text

let is_one_scalar text =
  (not (String.equal text ""))
  &&
  let decoded = String.get_utf_8_uchar text 0 in
  Uchar.utf_decode_is_valid decoded
  && Uchar.utf_decode_length decoded = String.length text

(* The footer spells [PgUp] where the decoder says [pageup], and an upper-case
   letter where a Kitty terminal says [shift-g]. *)
let footer_aliases =
  [ "pgup", "pageup"
  ; "pgdn", "pagedown"
  ; "ctrl-\\", "ctrl-backslash"
  ; "ctrl-]", "ctrl-right-bracket"
  ; "ctrl-^", "ctrl-caret"
  ; "ctrl-_", "ctrl-underscore"
  ]

let arrow_glyphs = [ "←", "left"; "↑", "up"; "→", "right"; "↓", "down" ]

(* [^T] is [Ctrl-T]. *)
let caret_as_ctrl atom =
  if String.length atom = 2 && Char.equal atom.[0] '^'
  then "Ctrl-" ^ String.make 1 atom.[1]
  else atom

(* [Shift+←] is [Shift-←]. *)
let plus_as_hyphen atom = String.concat "-" (String.split_on_char '+' atom)

(* An arrow drawn as a glyph, alone or after a modifier, is the word. *)
let glyph_as_word atom =
  List.fold_left
    (fun atom (glyph, word) ->
      if String.ends_with ~suffix:glyph atom
      then String.sub atom 0 (String.length atom - String.length glyph) ^ word
      else atom)
    atom arrow_glyphs

let footer_word atom =
  if String.length atom = 1 && atom.[0] >= 'A' && atom.[0] <= 'Z'
  then "shift-" ^ String.lowercase_ascii atom
  else (
    let lowered =
      atom |> caret_as_ctrl |> plus_as_hyphen |> glyph_as_word |> String.lowercase_ascii
    in
    match List.assoc_opt lowered footer_aliases with
    | Some word -> word
    | None -> lowered)

let classify ~advertised raw =
  let named name =
    Named
      { name
      ; advertised =
          List.exists (fun atom -> String.equal (footer_word atom) name) advertised
      }
  in
  if is_one_scalar raw
  then (
    let word = if String.length raw = 1 then control_word raw.[0] else None in
    match word with
    | Some word -> named word
    | None ->
      let spelling = if String.equal raw " " then "Space" else raw in
      if List.exists (String.equal spelling) advertised
      then Advertised_char spelling
      else Other_char)
  else if is_word raw
  then named raw
  else Other_char

let is_digit = function
  | '0' .. '9' -> true
  | _ -> false

(* The header clock is eight bytes, [HH:MM:SS], and a longer run of digits
   around it ([123:45:67]) is something else. *)
let clock_at line start =
  let length = String.length line in
  let digit offset = is_digit line.[start + offset] in
  let colon offset = Char.equal line.[start + offset] ':' in
  start + 8 <= length
  && digit 0 && digit 1 && colon 2 && digit 3 && digit 4 && colon 5 && digit 6
  && digit 7
  && (start = 0 || not (is_digit line.[start - 1]))
  && (start + 8 = length || not (is_digit line.[start + 8]))

let without_clock line =
  let masked = Bytes.of_string line in
  let rec scan start =
    if start + 8 <= String.length line
    then
      if clock_at line start
      then (
        List.iter (fun offset -> Bytes.set masked (start + offset) '0') [ 0; 1; 3; 4; 6; 7 ];
        scan (start + 8))
      else scan (start + 1)
  in
  scan 0;
  Bytes.to_string masked

let observe ~previous_surface ~surface ~key ~result ~advertised =
  let opened =
    match previous_surface with
    | Some previous when String.equal previous surface -> []
    | Some _ | None -> [ Surface_opened { from = previous_surface; to_ = surface } ]
  in
  let unchanged =
    match key, result with
    | Some raw, Masc_tui_frame_presenter.Unchanged ->
      [ Key_unchanged { surface; key = classify ~advertised raw } ]
    | Some _, Masc_tui_frame_presenter.Presented _
    | None, (Masc_tui_frame_presenter.Unchanged | Masc_tui_frame_presenter.Presented _) ->
      []
  in
  opened @ unchanged

let to_json_line ~at event =
  let fields =
    match event with
    | Surface_opened { from; to_ } ->
      [ "kind", `String "surface"
      ; ( "from"
        , match from with
          | Some from -> `String from
          | None -> `Null )
      ; "to", `String to_
      ]
    | Key_unchanged { surface; key } ->
      let word, advertised =
        match key with
        | Named { name; advertised } -> name, advertised
        | Advertised_char spelling -> spelling, true
        | Other_char -> "char", false
      in
      [ "kind", `String "key_unchanged"
      ; "surface", `String surface
      ; "key", `String word
      ; "advertised", `Bool advertised
      ]
    | Capped { limit } -> [ "kind", `String "capped"; "limit", `Int limit ]
  in
  Yojson.Safe.to_string (`Assoc (("t", `Float at) :: fields))
