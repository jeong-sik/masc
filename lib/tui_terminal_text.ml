(* #38445: a terminal draws bidi controls and zero-width characters as
   nothing, so the glyphs an operator reads can differ from the bytes the
   approval hash covers (Trojan Source, CVE-2021-42574). Both terminal
   sanitizers route those codepoints through here, so the rule lives in one
   place: the codepoint is drawn as its own escape text, never dropped. *)
let is_invisible_codepoint code =
  (* Unicode's own list, not a hand-kept one: Default_Ignorable_Code_Point is
     every scalar a renderer may draw as nothing -- the bidi controls, the
     zero-widths, the word joiner family (U+2060-U+2064), the Hangul fillers
     (U+115F, U+1160, U+3164, U+FFA0), the soft hyphen, the variation
     selectors (U+FE00-U+FE0F, U+E0100-U+E01EF) and the tag block. A list
     kept by hand here missed every one of those after the tag block. *)
  Uchar.is_valid code && Uucp.Gen.is_default_ignorable (Uchar.of_int code)
;;

let zero_width_joiner = 0x200D
let variation_selector_15 = 0xFE0E
let variation_selector_16 = 0xFE0F

(* The one ZWJ that is not hiding anything: the one holding an emoji
   together. [Masc_tui_message_layout] already reads it that way when it
   measures a cluster ("a family joined by ZWJ"), and escaping it everywhere
   drew 🤷‍♂️ as six ASCII characters on the screen and put them back in the
   input line on recall. UAX #29 GB11 is the line: a ZWJ between two
   pictographs joins them and stays; every other ZWJ joins nothing a reader
   can see, so it is drawn as its escape with the rest of the invisibles.
   The scalars below sit inside a cluster without ending it -- the two
   presentation selectors and the skin tones -- so a joined ZWJ is still
   recognised after them (🧑🏽‍💻). *)
let continues_pictograph scalar =
  let code = Uchar.to_int scalar in
  code = variation_selector_15
  || code = variation_selector_16
  || Uucp.Emoji.is_emoji_modifier scalar

let scalar_at text index =
  if index >= String.length text
  then None
  else (
    let decoded = String.get_utf_8_uchar text index in
    if Uchar.utf_decode_is_valid decoded
    then Some (Uchar.utf_decode_uchar decoded)
    else None)

let opens_pictograph text index =
  match scalar_at text index with
  | Some scalar -> Uucp.Emoji.is_extended_pictographic scalar
  | None -> false

(* The tags that are not hiding anything: the ones spelling a subregion flag.
   U+1F3F4 opens the sequence, a subdivision code follows, and U+E007F closes
   it: U+1F3F4 U+E0067 U+E0062 U+E0073 U+E0063 U+E0074 U+E007F is Scotland.
   [Masc_tui_message_layout] counts that block as part of one emoji cluster,
   and the exemption here is deliberately narrower than that block: only the
   shape UTS #51 gives a subdivision, three to seven tag characters drawn
   from lowercase letters and digits. The wider grammar would carry a
   sentence -- tag space and tag punctuation spell one -- and a reader would
   see a single flag where the hash covers words. The sequence is admitted
   whole or not at all: a run that never reaches the terminator, or one
   shaped like anything but a subdivision, is loose text spelled in invisible
   characters, and the flag in front of it stays visible. *)
let tag_small_letter_first = 0xE0061
let tag_small_letter_last = 0xE007A
let tag_digit_first = 0xE0030
let tag_digit_last = 0xE0039
let tag_spec_min = 3
let tag_spec_max = 7
let cancel_tag = 0xE007F
let waving_black_flag = 0x1F3F4

let is_tag_spec code =
  (code >= tag_small_letter_first && code <= tag_small_letter_last)
  || (code >= tag_digit_first && code <= tag_digit_last)

(* Bytes of a complete subdivision sequence starting at [index] -- the
   position just past the flag -- not counting the flag itself. [None] when
   the run is too short or too long for a subdivision, meets a tag character
   outside the lowercase-and-digit shape, or ends without the terminator. *)
let tag_sequence_bytes text index =
  let length = String.length text in
  let rec scan position ~spec_count =
    if position >= length
    then None
    else (
      let decoded = String.get_utf_8_uchar text position in
      if not (Uchar.utf_decode_is_valid decoded)
      then None
      else (
        let step = Uchar.utf_decode_length decoded in
        let code = Uchar.to_int (Uchar.utf_decode_uchar decoded) in
        if code = cancel_tag
        then (
          if spec_count >= tag_spec_min && spec_count <= tag_spec_max
          then Some (position + step - index)
          else None)
        else if is_tag_spec code && spec_count < tag_spec_max
        then scan (position + step) ~spec_count:(spec_count + 1)
        else None))
  in
  scan index ~spec_count:0

(* [\uXXXX] has room for the basic plane only and the tag block needs five
   digits (U+E0061), so a wider fixed-width form of the same family carries
   them: the reader can still see where one escape ends and the next begins. *)
let escape_text code =
  if code <= 0xFFFF
  then Printf.sprintf "\\u%04X" code
  else Printf.sprintf "\\U%08X" code

(* No ASCII scalar is Default_Ignorable, a variation selector, a joiner, an
   emoji modifier, a pictograph or the flag that opens a tag sequence, so
   the walk below copies an all-ASCII text unchanged. A frame sanitises
   every cell it draws, and most cells -- names, ids, counts, key hints --
   are only ASCII, so such a text is returned as it came. *)
let escape_invisible text =
  if String.for_all (fun byte -> byte < '\x80') text then text
  else
  let output = Buffer.create (String.length text) in
  let length = String.length text in
  (* [base]: the scalar before this one, when it was drawn and is not itself
     ignorable. The one selector kept is VS15/VS16 right after a text-default
     emoji (Emoji, not Emoji_Presentation: U+2764, U+2642, a keycap digit) --
     the pairs emoji-variation-sequences.txt registers, and the ones joined
     emoji use. Every other selector is drawn as its escape: after a plain
     letter, behind another selector, with no base, and also after an
     ideograph, because this boundary cannot tell a registered IVD or
     StandardizedVariants pair from an unregistered one, and an unregistered
     pair displays as the bare base (Unicode FAQ, unsupported characters). *)
  let keeps_selector ~base scalar =
    let code = Uchar.to_int scalar in
    (code = variation_selector_15 || code = variation_selector_16)
    && Uucp.Emoji.is_emoji base
    && not (Uucp.Emoji.is_emoji_presentation base)
  in
  let rec walk index ~after_pictograph ~base =
    if index < length
    then (
      let decoded = String.get_utf_8_uchar text index in
      let step = Uchar.utf_decode_length decoded in
      let scalar = Uchar.utf_decode_uchar decoded in
      let valid = Uchar.utf_decode_is_valid decoded in
      let code = Uchar.to_int scalar in
      let flag_tags =
        if valid && code = waving_black_flag
        then tag_sequence_bytes text (index + step)
        else None
      in
      match flag_tags with
      | Some tail ->
        Buffer.add_substring output text index (step + tail);
        walk (index + step + tail) ~after_pictograph:true ~base:None
      | None ->
        let joins_two_pictographs =
          valid
          && code = zero_width_joiner
          && after_pictograph
          && opens_pictograph text (index + step)
        in
        let selects_its_base =
          valid
          && Uucp.Gen.is_variation_selector scalar
          && (match base with
              | Some base -> keeps_selector ~base scalar
              | None -> false)
        in
        let escaped =
          valid
          && is_invisible_codepoint code
          && not (joins_two_pictographs || selects_its_base)
        in
        if escaped
        then Buffer.add_string output (escape_text code)
        else Buffer.add_substring output text index step;
        let base =
          if valid && (not escaped) && not (is_invisible_codepoint code)
          then Some scalar
          else None
        in
        let after_pictograph =
          if not valid
          then false
          else if Uucp.Emoji.is_extended_pictographic scalar
          then true
          (* Only a joiner that actually joined carries the state: an escaped
             one has been written out as text, so what follows it no longer
             sits inside an emoji and a second joiner cannot ride through on
             it. *)
          else if continues_pictograph scalar || joins_two_pictographs
          then after_pictograph
          else false
        in
        walk (index + step) ~after_pictograph ~base)
  in
  walk 0 ~after_pictograph:false ~base:None;
  Buffer.contents output
;;

(* Printable ASCII (0x20..0x7E) is the one input both passes below copy
   byte for byte: no control to escape, no multi-byte sequence to check and,
   through [escape_invisible], no scalar a terminal draws as nothing. It is
   returned as it came; DEL and every other control still take the escape
   table. *)
let sanitize_terminal_text text =
  if String.for_all (fun byte -> byte >= ' ' && byte <= '~') text then text
  else
  let escaped_byte byte = Printf.sprintf "\\x%02X" byte in
  let escaped_codepoint byte = Printf.sprintf "\\u00%02X" byte in
  let output = Buffer.create (String.length text) in
  let byte_at index = Char.code text.[index] in
  let is_continuation byte = byte >= 0x80 && byte <= 0xBF in
  let valid_utf8_length index =
    let remaining = String.length text - index in
    let first = byte_at index in
    if first >= 0xC2 && first <= 0xDF && remaining >= 2
       && is_continuation (byte_at (index + 1))
    then Some 2
    else if first = 0xE0 && remaining >= 3
            && byte_at (index + 1) >= 0xA0
            && byte_at (index + 1) <= 0xBF
            && is_continuation (byte_at (index + 2))
    then Some 3
    else if first >= 0xE1 && first <= 0xEC && remaining >= 3
            && is_continuation (byte_at (index + 1))
            && is_continuation (byte_at (index + 2))
    then Some 3
    else if first = 0xED && remaining >= 3
            && byte_at (index + 1) >= 0x80
            && byte_at (index + 1) <= 0x9F
            && is_continuation (byte_at (index + 2))
    then Some 3
    else if first >= 0xEE && first <= 0xEF && remaining >= 3
            && is_continuation (byte_at (index + 1))
            && is_continuation (byte_at (index + 2))
    then Some 3
    else if first = 0xF0 && remaining >= 4
            && byte_at (index + 1) >= 0x90
            && byte_at (index + 1) <= 0xBF
            && is_continuation (byte_at (index + 2))
            && is_continuation (byte_at (index + 3))
    then Some 4
    else if first >= 0xF1 && first <= 0xF3 && remaining >= 4
            && is_continuation (byte_at (index + 1))
            && is_continuation (byte_at (index + 2))
            && is_continuation (byte_at (index + 3))
    then Some 4
    else if first = 0xF4 && remaining >= 4
            && byte_at (index + 1) >= 0x80
            && byte_at (index + 1) <= 0x8F
            && is_continuation (byte_at (index + 2))
            && is_continuation (byte_at (index + 3))
    then Some 4
    else None
  in
  let rec append index =
    if index < String.length text
    then (
      let byte = Char.code text.[index] in
      if
        byte < 0x20 || (byte >= 0x7F && byte <= 0x9F)
      then (
        Buffer.add_string output (escaped_byte byte);
        append (index + 1))
      else if byte < 0x80
      then (
        Buffer.add_char output text.[index];
        append (index + 1))
      else if
        byte = 0xC2
        && index + 1 < String.length text
        && let next = Char.code text.[index + 1] in
           next >= 0x80 && next <= 0x9F
      then (
        Buffer.add_string output (escaped_codepoint (Char.code text.[index + 1]));
        append (index + 2))
      else
        match valid_utf8_length index with
        | Some length ->
          Buffer.add_substring output text index length;
          append (index + length)
        | None ->
          Buffer.add_string output (escaped_byte byte);
          append (index + 1))
  in
  append 0;
  escape_invisible (Buffer.contents output)
;;

(* A text whose line breaks are its own shape, read whole rather than as one
   row: each LF stays a break and every line goes through the same escape
   table as a single row, so a tab, a carriage return or an ESC is drawn as
   its visible [\xNN] and never reaches the terminal as a control byte. *)
let sanitize_terminal_lines text =
  String.split_on_char '\n' text
  |> List.map sanitize_terminal_text
  |> String.concat "\n"
;;

(* One row of a text that has rows. The terminal boundary escapes control
   bytes because an external value may carry them by mistake or on purpose;
   a file's newline is neither, it is the text's own shape, and a list cell
   that prints it as [\x0A] reads as damage. So a break becomes a one-cell
   return mark, a tab a space, and the rest goes through the same escape as
   every other external value. The mark is neutral-width (U+23CE), so a
   preview grows by one cell per line, never by six. *)
let preview_line text =
  let return_mark = "\xe2\x8f\x8e" in
  let output = Buffer.create (String.length text) in
  let length = String.length text in
  let rec walk index =
    if index < length
    then (
      match text.[index] with
      | '\r' when index + 1 < length && text.[index + 1] = '\n' ->
        Buffer.add_string output return_mark;
        walk (index + 2)
      | '\n' | '\r' ->
        Buffer.add_string output return_mark;
        walk (index + 1)
      | '\t' ->
        Buffer.add_char output ' ';
        walk (index + 1)
      | byte ->
        Buffer.add_char output byte;
        walk (index + 1))
  in
  walk 0;
  sanitize_terminal_text (Buffer.contents output)
;;

let short_timestamp_of_unix_for_terminal ~localtime unix_seconds =
  let tm = localtime unix_seconds in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d" (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min
    tm.Unix.tm_sec
;;

(* {!clock_timestamp_for_terminal}'s [HH:MM:SS] shape, for a time the wire
   carries as a number rather than an RFC 3339 string -- the same pairing
   {!short_timestamp_of_unix_for_terminal} already is for
   {!short_timestamp_for_terminal}. *)
let clock_timestamp_of_unix_for_terminal ~localtime unix_seconds =
  let tm = localtime unix_seconds in
  Printf.sprintf "%02d:%02d:%02d" tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec
;;

(* The date and time beside a record, in the zone the operator's terminal is
   in. It sliced the first nineteen bytes of the server's RFC 3339 string, which
   kept a UTC reading and dropped the [Z] that said so -- "2026-08-22T00:03:00"
   under a header clock in local time read as the local hour it was not. A
   timestamp the codec cannot read keeps the slice, for the same reason
   [clock_timestamp_for_terminal] does. *)
let short_timestamp_for_terminal ~localtime text =
  sanitize_terminal_text
    (match Time_codec.parse_rfc3339_opt text with
     | Some unix_seconds -> short_timestamp_of_unix_for_terminal ~localtime unix_seconds
     | None ->
         if String.length text > 19 then String.sub text 0 19
         else if String.length text = 0 then "(never)"
         else text)
;;

(* The clock beside a row, in the zone the operator's terminal is in. The
   server writes RFC 3339 on the UTC timeline; slicing HH:MM:SS straight out
   of that string put a UTC clock on every log row under a header that showed
   local time, nine hours apart in Seoul. [localtime] is the conversion the
   caller chooses -- the terminal's own zone on a screen, a fixed one in a
   test -- so this stays a function of its inputs. A timestamp the codec
   cannot read keeps the old slice: the byte positions are still where a
   clock would be, and the sanitizer still makes them safe to draw. *)
let clock_timestamp_for_terminal ~localtime text =
  sanitize_terminal_text
    (match Time_codec.parse_rfc3339_opt text with
     | Some unix_seconds ->
         let tm = localtime unix_seconds in
         Printf.sprintf "%02d:%02d:%02d" tm.Unix.tm_hour tm.Unix.tm_min
           tm.Unix.tm_sec
     | None -> if String.length text >= 19 then String.sub text 11 8 else text)
;;
