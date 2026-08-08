(** Replace invalid UTF-8 sequences with the U+FFFD replacement character and
    disallowed control characters with spaces. Valid UTF-8 with no control
    chars is passed through unchanged. O(n).

    Validity is decided by the OCaml Stdlib UTF-8 decoder
    ([String.is_valid_utf_8] / [String.get_utf_8_uchar]), so overlong
    encodings, UTF-16 surrogates (U+D800..U+DFFF), and code points above
    U+10FFFF are rejected per the Unicode standard. A hand-rolled byte-length
    check cannot reject those classes (e.g. the overlong [0xC0 0x80] has a
    structurally well-formed lead byte and continuation), which is why this
    delegates to the Stdlib decoder.

    Control characters (0x00-0x1F except LF/CR/TAB, plus DEL 0x7F) break LLM
    prompt formatting. Replacing them at the SDK level prevents consumers from
    needing their own sanitize pass.

    @since 0.138.0 — control character sanitization added
    @since 0.139.0 — UTF-8 validation delegated to the Stdlib decoder *)

let replacement = "\xEF\xBF\xBD" (* U+FFFD *)

(** True for ASCII control characters that break prompt formatting.
    LF (0x0A), CR (0x0D), TAB (0x09) are kept — prompts rely on them.
    All disallowed control characters are single-byte ASCII (< 0x80). *)
let is_disallowed_control byte =
  (byte < 0x20 && byte <> 0x0A && byte <> 0x0D && byte <> 0x09) || byte = 0x7F
;;

(** Fast-path: already valid UTF-8 with no disallowed control characters.
    Disallowed control characters are all single-byte ASCII, so a byte scan
    settles that half without decoding. *)
let is_clean s =
  String.is_valid_utf_8 s
  && not (String.exists (fun c -> is_disallowed_control (Char.code c)) s)
;;

let sanitize s =
  if is_clean s
  then s (* fast path: no allocation *)
  else (
    let len = String.length s in
    let buf = Buffer.create len in
    let i = ref 0 in
    while !i < len do
      let dec = String.get_utf_8_uchar s !i in
      if Uchar.utf_decode_is_valid dec
      then (
        let u = Uchar.utf_decode_uchar dec in
        let code = Uchar.to_int u in
        if code < 0x80 && is_disallowed_control code
        then Buffer.add_char buf ' '
        else Buffer.add_utf_8_uchar buf u)
      else
        (* Malformed: the decoder reports a U+FFFD decode spanning the maximal
            invalid subpart; emit one replacement for it. *)
        Buffer.add_string buf replacement;
      i := !i + Uchar.utf_decode_length dec
    done;
    Buffer.contents buf)
;;

(* === Inline tests === *)

(** Every sanitized output is, by construction, valid UTF-8. *)
let is_valid out = String.is_valid_utf_8 out

let%test "ascii only unchanged" =
  let s = "Hello, world 123" in
  sanitize s == s (* physical equality: no allocation *)
;;

let%test "valid utf8 korean unchanged" =
  let s = "\xED\x95\x9C\xEA\xB5\xAD\xEC\x96\xB4" in
  (* "한국어" *)
  sanitize s == s
;;

let%test "valid utf8 emoji unchanged" =
  let s = "\xF0\x9F\x98\x80" in
  (* U+1F600 grinning face *)
  sanitize s == s
;;

let%test "empty string" =
  let s = "" in
  sanitize s == s
;;

let%test "LF CR TAB preserved" =
  let s = "a\nb\rc\td" in
  sanitize s == s (* physical equality: no allocation *)
;;

(* Malformed sequences: assert the invariant (output is valid UTF-8 and the
   valid neighbours survive) rather than an exact replacement-character count,
   which follows the Stdlib decoder's maximal-subpart substitution. *)

let%test "truncated 2-byte replaced" =
  let out = sanitize "abc\xC3" in
  is_valid out && String.length out > 3 && String.sub out 0 3 = "abc"
;;

let%test "truncated 3-byte replaced" =
  let out = sanitize "x\xE2\x80" in
  is_valid out && out.[0] = 'x' && out <> "x\xE2\x80"
;;

let%test "truncated 4-byte replaced" =
  let out = sanitize "\xF0\x9F\x98" in
  is_valid out && out <> "" && out <> "\xF0\x9F\x98"
;;

let%test "invalid continuation byte" =
  (* C3 followed by 0x00 (not a continuation); NUL becomes a space. *)
  let out = sanitize "a\xC3\x00b" in
  is_valid out
  && out.[0] = 'a'
  && String.length out >= 3
  && out.[String.length out - 1] = 'b'
;;

let%test "bare continuation bytes replaced" =
  let out = sanitize "\x80\x81" in
  is_valid out && out = replacement ^ replacement
;;

let%test "0xFF invalid byte replaced" =
  let out = sanitize "ok\xFF" in
  is_valid out && out = "ok" ^ replacement
;;

let%test "0xF8 lead byte invalid" =
  let out = sanitize "\xF8\x80\x80\x80" in
  is_valid out && out <> "\xF8\x80\x80\x80" && String.length out > 0
;;

let%test "mixed valid and invalid" =
  (* "ok" + U+00E9 (C3 A9) + 0xFF (isolated invalid) + U+2713 (E2 9C 93). *)
  let out = sanitize "ok\xC3\xA9\xFF\xE2\x9C\x93" in
  is_valid out && out = "ok\xC3\xA9" ^ replacement ^ "\xE2\x9C\x93"
;;

(* Classes a byte-length check cannot reject but the Stdlib decoder does. *)

let%test "overlong encoding rejected" =
  (* 0xC0 0x80 is an overlong encoding of U+0000; structurally well-formed. *)
  let out = sanitize "\xC0\x80" in
  is_valid out && out <> "\xC0\x80"
;;

let%test "surrogate rejected" =
  (* 0xED 0xA0 0x80 encodes U+D800, a UTF-16 surrogate forbidden in UTF-8. *)
  let out = sanitize "\xED\xA0\x80" in
  is_valid out && out <> "\xED\xA0\x80"
;;

let%test "out of range code point rejected" =
  (* 0xF4 0x90 0x80 0x80 encodes U+110000, above the U+10FFFF maximum. *)
  let out = sanitize "\xF4\x90\x80\x80" in
  is_valid out && out <> "\xF4\x90\x80\x80"
;;

let%test "NUL replaced with space" = sanitize "ab\x00cd" = "ab cd"
let%test "BEL replaced with space" = sanitize "x\x07y" = "x y"
let%test "DEL replaced with space" = sanitize "a\x7Fb" = "a b"
let%test "mixed control chars" = sanitize "\x01hello\x00\nworld\x1F" = " hello \nworld "
