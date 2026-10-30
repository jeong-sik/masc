(* The two-set layout, letter by letter, in the direction that reads back.

   One table is authoritative: every Hangul letter to the key characters
   that type it, in Unicode compatibility order (U+3131 ㄱ .. U+3163 ㅣ),
   which is the order a terminal sends a lone letter in. The three
   syllable-part lists below name their letters in the conjoining-jamo index
   order (choseong U+1100 .., jungseong U+1161 .., jongseong U+11A8 ..) and
   look each letter up in that one table, so a spelling exists in exactly
   one place. A letter two keys type together -- the compound vowels and the
   cluster finals -- carries both key characters, because replay owes the
   dispatch every key the operator pressed, not one standing in for two.

   The tense letters are shifted spellings ([ㄲ] is [R]), which is the
   two-set layout's own answer for them; see the interface for the shift
   limit above the table. *)

let two_set =
  [ "ㄱ", "r"; "ㄲ", "R"; "ㄳ", "rt"; "ㄴ", "s"; "ㄵ", "sw"; "ㄶ", "sg"
  ; "ㄷ", "e"; "ㄸ", "E"; "ㄹ", "f"; "ㄺ", "fr"; "ㄻ", "fa"; "ㄼ", "fq"
  ; "ㄽ", "ft"; "ㄾ", "fx"; "ㄿ", "fv"; "ㅀ", "fg"; "ㅁ", "a"; "ㅂ", "q"
  ; "ㅃ", "Q"; "ㅄ", "qt"; "ㅅ", "t"; "ㅆ", "T"; "ㅇ", "d"; "ㅈ", "w"
  ; "ㅉ", "W"; "ㅊ", "c"; "ㅋ", "z"; "ㅌ", "x"; "ㅍ", "v"; "ㅎ", "g"
  ; "ㅏ", "k"; "ㅐ", "o"; "ㅑ", "i"; "ㅒ", "O"; "ㅓ", "j"; "ㅔ", "p"
  ; "ㅕ", "u"; "ㅖ", "P"; "ㅗ", "h"; "ㅘ", "hk"; "ㅙ", "ho"; "ㅚ", "hl"
  ; "ㅛ", "y"; "ㅜ", "n"; "ㅝ", "nj"; "ㅞ", "np"; "ㅟ", "nl"; "ㅠ", "b"
  ; "ㅡ", "m"; "ㅢ", "ml"; "ㅣ", "l" ]

(* Choseong, in conjoining-jamo order (U+1100 .. U+1112). *)
let cho_letters =
  [ "ㄱ"; "ㄲ"; "ㄴ"; "ㄷ"; "ㄸ"; "ㄹ"; "ㅁ"; "ㅂ"; "ㅃ"; "ㅅ"; "ㅆ"; "ㅇ"
  ; "ㅈ"; "ㅉ"; "ㅊ"; "ㅋ"; "ㅌ"; "ㅍ"; "ㅎ" ]

(* Jungseong, in conjoining-jamo order (U+1161 .. U+1175). *)
let jung_letters =
  [ "ㅏ"; "ㅐ"; "ㅑ"; "ㅒ"; "ㅓ"; "ㅔ"; "ㅕ"; "ㅖ"; "ㅗ"; "ㅘ"; "ㅙ"; "ㅚ"
  ; "ㅛ"; "ㅜ"; "ㅝ"; "ㅞ"; "ㅟ"; "ㅠ"; "ㅡ"; "ㅢ"; "ㅣ" ]

(* Jongseong, in conjoining-jamo order (U+11A8 .. U+11C2). Index 0 is no
   final, so this list starts at the first letter a final can be. *)
let jong_letters =
  [ "ㄱ"; "ㄲ"; "ㄳ"; "ㄴ"; "ㄵ"; "ㄶ"; "ㄷ"; "ㄹ"; "ㄺ"; "ㄻ"; "ㄼ"; "ㄽ"
  ; "ㄾ"; "ㄿ"; "ㅀ"; "ㅁ"; "ㅂ"; "ㅄ"; "ㅅ"; "ㅆ"; "ㅇ"; "ㅈ"; "ㅊ"; "ㅋ"
  ; "ㅌ"; "ㅍ"; "ㅎ" ]

(* Every key the layout spells is one character, so the key list of a letter
   is its spelling's characters. [assoc] rather than [assoc_opt]: a letter
   the order lists name that the table does not spell is a table bug, and it
   fails loudly here at startup rather than misreading a key quietly. *)
let keys_of_spelling spelling =
  String.to_seq spelling |> Seq.map (String.make 1) |> List.of_seq

let keys_of_letter letter = keys_of_spelling (List.assoc letter two_set)

let cho_keys = List.map keys_of_letter cho_letters
let jung_keys = List.map keys_of_letter jung_letters
let jong_keys = List.map keys_of_letter jong_letters
let compat_keys = List.map (fun (_, spelling) -> keys_of_spelling spelling) two_set

(* Unicode block bounds; each guard below reads the range its pair names. *)
let syllable_first = 0xAC00
let syllable_last = 0xD7A3
let compatibility_first = 0x3131
let compatibility_last = 0x3163
let choseong_first = 0x1100
let choseong_last = 0x1112
let jungseong_first = 0x1161
let jungseong_last = 0x1175
let jongseong_first = 0x11A8
let jongseong_last = 0x11C2

(* The syllable block's own arithmetic (KS X 1026): a syllable is
   0xAC00 + ((cho * 21) + jung) * 28 + jong. *)
let jungseong_count = 21
let jongseong_count = 28
let choseong_stride = jungseong_count * jongseong_count

let syllable_keys codepoint =
  let offset = codepoint - syllable_first in
  let cho = offset / choseong_stride in
  let jung = (offset / jongseong_count) mod jungseong_count in
  let jong = offset mod jongseong_count in
  List.nth cho_keys cho @ List.nth jung_keys jung
  @ if jong = 0 then [] else List.nth jong_keys (jong - 1)

(* One scalar, as a code point, or [None] for anything that is not exactly
   one: the decoder this reads from hands out one key per scalar, so a longer
   or shorter string is not a key this module reads. Overlong encodings are
   rejected rather than decoded, the same answer the decoder gives them. *)
let scalar_code name =
  let length = String.length name in
  if length = 0 then None
  else
    let lead_code = Char.code name.[0] in
    let expected, partial =
      if lead_code < 0x80 then (1, lead_code)
      else if lead_code < 0xE0 then (2, lead_code land 0x1F)
      else if lead_code < 0xF0 then (3, lead_code land 0x0F)
      else if lead_code < 0xF8 then (4, lead_code land 0x07)
      else (0, 0)
    in
    if expected = 0 || length <> expected then None
    else
      let minimum =
        match expected with
        | 1 -> 0
        | 2 -> 0x80
        | 3 -> 0x800
        | _ -> 0x10000
      in
      let rec walk position partial =
        if position >= expected then Some partial
        else
          let code = Char.code name.[position] in
          if code land 0xC0 <> 0x80 then None
          else walk (position + 1) ((partial lsl 6) lor (code land 0x3F))
      in
      match walk 1 partial with
      | Some codepoint when codepoint >= minimum -> Some codepoint
      | _ -> None

let latin_keys name =
  match scalar_code name with
  | None -> None
  | Some codepoint when codepoint >= syllable_first && codepoint <= syllable_last ->
      Some (syllable_keys codepoint)
  | Some codepoint
    when codepoint >= compatibility_first && codepoint <= compatibility_last ->
      Some (List.nth compat_keys (codepoint - compatibility_first))
  | Some codepoint when codepoint >= choseong_first && codepoint <= choseong_last ->
      Some (List.nth cho_keys (codepoint - choseong_first))
  | Some codepoint
    when codepoint >= jungseong_first && codepoint <= jungseong_last ->
      Some (List.nth jung_keys (codepoint - jungseong_first))
  | Some codepoint when codepoint >= jongseong_first && codepoint <= jongseong_last ->
      Some (List.nth jong_keys (codepoint - jongseong_first))
  | Some _ -> None

let single_latin_key name =
  match latin_keys name with
  | Some [key] -> Some key
  | Some ([] | _ :: _ :: _) | None -> None
