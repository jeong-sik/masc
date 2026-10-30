(* The two-set layout read backwards, checked against the keyboard an
   operator's hands know.

   The spellings below are written here and not read out of the module: each
   entry states what pressing that key in Korean mode commits, which is the
   fact the translation exists to restore. The block-order lists carry only
   codepoints -- Unicode's own ordering facts -- and look their spellings up
   in this file's table, so a wrong letter order or a wrong spelling in the
   module fails against ground truth written independently of it. *)

open Alcotest

let spellings = list string
let maybe_spellings = option spellings

let utf8 codepoint =
  let byte n shift mask = Char.chr (((codepoint lsr shift) land mask) lor n) in
  let b = Buffer.create 4 in
  let add char = Buffer.add_char b char in
  if codepoint < 0x80 then add (Char.chr codepoint)
  else if codepoint < 0x800 then (add (byte 0xC0 6 0x1F); add (byte 0x80 0 0x3F))
  else if codepoint < 0x10000 then
    (add (byte 0xE0 12 0x0F); add (byte 0x80 6 0x3F); add (byte 0x80 0 0x3F))
  else
    ( add (byte 0xF0 18 0x07)
    ; add (byte 0x80 12 0x3F)
    ; add (byte 0x80 6 0x3F)
    ; add (byte 0x80 0 0x3F) );
  Buffer.contents b

(* Every letter of the layout, compatibility block order (U+3131 .. U+3163),
   to the keys that type it. *)
let letters =
  [ 0x3131, [ "r" ] (* ㄱ *); 0x3132, [ "R" ] (* ㄲ *); 0x3133, [ "r"; "t" ] (* ㄳ *)
  ; 0x3134, [ "s" ] (* ㄴ *); 0x3135, [ "s"; "w" ] (* ㄵ *)
  ; 0x3136, [ "s"; "g" ] (* ㄶ *); 0x3137, [ "e" ] (* ㄷ *)
  ; 0x3138, [ "E" ] (* ㄸ *); 0x3139, [ "f" ] (* ㄹ *)
  ; 0x313A, [ "f"; "r" ] (* ㄺ *); 0x313B, [ "f"; "a" ] (* ㄻ *)
  ; 0x313C, [ "f"; "q" ] (* ㄼ *); 0x313D, [ "f"; "t" ] (* ㄽ *)
  ; 0x313E, [ "f"; "x" ] (* ㄾ *); 0x313F, [ "f"; "v" ] (* ㄿ *)
  ; 0x3140, [ "f"; "g" ] (* ㅀ *); 0x3141, [ "a" ] (* ㅁ *)
  ; 0x3142, [ "q" ] (* ㅂ *); 0x3143, [ "Q" ] (* ㅃ *)
  ; 0x3144, [ "q"; "t" ] (* ㅄ *); 0x3145, [ "t" ] (* ㅅ *)
  ; 0x3146, [ "T" ] (* ㅆ *); 0x3147, [ "d" ] (* ㅇ *)
  ; 0x3148, [ "w" ] (* ㅈ *); 0x3149, [ "W" ] (* ㅉ *)
  ; 0x314A, [ "c" ] (* ㅊ *); 0x314B, [ "z" ] (* ㅋ *)
  ; 0x314C, [ "x" ] (* ㅌ *); 0x314D, [ "v" ] (* ㅍ *)
  ; 0x314E, [ "g" ] (* ㅎ *); 0x314F, [ "k" ] (* ㅏ *)
  ; 0x3150, [ "o" ] (* ㅐ *); 0x3151, [ "i" ] (* ㅑ *)
  ; 0x3152, [ "O" ] (* ㅒ *); 0x3153, [ "j" ] (* ㅓ *)
  ; 0x3154, [ "p" ] (* ㅔ *); 0x3155, [ "u" ] (* ㅕ *)
  ; 0x3156, [ "P" ] (* ㅖ *); 0x3157, [ "h" ] (* ㅗ *)
  ; 0x3158, [ "h"; "k" ] (* ㅘ *); 0x3159, [ "h"; "o" ] (* ㅙ *)
  ; 0x315A, [ "h"; "l" ] (* ㅚ *); 0x315B, [ "y" ] (* ㅛ *)
  ; 0x315C, [ "n" ] (* ㅜ *); 0x315D, [ "n"; "j" ] (* ㅝ *)
  ; 0x315E, [ "n"; "p" ] (* ㅞ *); 0x315F, [ "n"; "l" ] (* ㅟ *)
  ; 0x3160, [ "b" ] (* ㅠ *); 0x3161, [ "m" ] (* ㅡ *)
  ; 0x3162, [ "m"; "l" ] (* ㅢ *); 0x3163, [ "l" ] (* ㅣ *) ]

let spelling codepoint = List.assoc codepoint letters

(* The syllable parts in conjoining-jamo index order, spelled as
   compatibility codepoints: choseong U+1100 .. U+1112, jungseong U+1161 ..
   U+1175, jongseong U+11A8 .. U+11C2. *)
let cho = [ 0x3131; 0x3132; 0x3134; 0x3137; 0x3138; 0x3139; 0x3141; 0x3142; 0x3143; 0x3145; 0x3146; 0x3147; 0x3148; 0x3149; 0x314A; 0x314B; 0x314C; 0x314D; 0x314E ]

let jung =
  [ 0x314F; 0x3150; 0x3151; 0x3152; 0x3153; 0x3154; 0x3155; 0x3156; 0x3157
  ; 0x3158; 0x3159; 0x315A; 0x315B; 0x315C; 0x315D; 0x315E; 0x315F; 0x3160
  ; 0x3161; 0x3162; 0x3163 ]

let jong =
  [ 0x3131; 0x3132; 0x3133; 0x3134; 0x3135; 0x3136; 0x3137; 0x3139; 0x313A
  ; 0x313B; 0x313C; 0x313D; 0x313E; 0x313F; 0x3140; 0x3141; 0x3142; 0x3144
  ; 0x3145; 0x3146; 0x3147; 0x3148; 0x314A; 0x314B; 0x314C; 0x314D; 0x314E ]

let part_spelling part index = spelling (List.nth part index)

let test_every_letter () =
  List.iteri
    (fun position (codepoint, expected) ->
      check maybe_spellings
        (Printf.sprintf "letter U+%04X at %d" codepoint position)
        (Some expected)
        (Masc_tui_key_ime.latin_keys (utf8 codepoint)))
    letters

let test_conjoining_jamo () =
  let cases =
    [ (0x1100, [ "r" ]) (* ㄱ cho *); (0x1101, [ "R" ]) (* ㄲ cho *)
    ; (0x1112, [ "g" ]) (* ㅎ cho last *); (0x1161, [ "k" ]) (* ㅏ jung *)
    ; (0x116A, [ "h"; "k" ]) (* ㅘ jung compound *)
    ; (0x1175, [ "l" ]) (* ㅣ jung last *)
    ; (0x11A8, [ "r" ]) (* ㄱ jong first *)
    ; (0x11B0, [ "f"; "r" ]) (* ㄺ jong compound *)
    ; (0x11C2, [ "g" ]) (* ㅎ jong last *) ]
  in
  List.iteri
    (fun position (codepoint, expected) ->
      check maybe_spellings
        (Printf.sprintf "jamo U+%04X at %d" codepoint position)
        (Some expected)
        (Masc_tui_key_ime.latin_keys (utf8 codepoint)))
    cases

let test_known_syllables () =
  let cases =
    [ ("하", [ "g"; "k" ]); ("각", [ "r"; "k"; "r" ]); ("과", [ "r"; "h"; "k" ])
    ; ("닭", [ "e"; "k"; "f"; "r" ]); ("까", [ "R"; "k" ])
    ; ("없", [ "d"; "j"; "q"; "t" ]); ("값", [ "r"; "k"; "q"; "t" ])
    ; ("희", [ "g"; "m"; "l" ]); ("월", [ "d"; "n"; "j"; "f" ])
    ; ("의", [ "d"; "m"; "l" ]); ("뷁", [ "q"; "n"; "p"; "f"; "r" ]) ]
  in
  List.iteri
    (fun position (syllable, expected) ->
      check maybe_spellings (Printf.sprintf "%s at %d" syllable position)
        (Some expected)
        (Masc_tui_key_ime.latin_keys syllable))
    cases

let test_every_syllable () =
  (* The syllable block's arithmetic restated here (KS X 1026), so the sweep
     derives each expectation from this file's tables rather than the
     module's. *)
  let mismatches =
    let rec walk codepoint acc =
      if codepoint > 0xD7A3 then List.rev acc
      else
        let offset = codepoint - 0xAC00 in
        let expected =
          part_spelling cho (offset / 588)
          @ part_spelling jung ((offset / 28) mod 21)
          @ if offset mod 28 = 0 then []
            else part_spelling jong ((offset mod 28) - 1)
        in
        let mismatch =
          match Masc_tui_key_ime.latin_keys (utf8 codepoint) with
          | Some keys when keys = expected -> None
          | other ->
              Some
                (Printf.sprintf "U+%04X: %s"
                   codepoint
                   (match other with
                    | Some keys -> String.concat "" keys
                    | None -> "not Hangul"))
        in
        walk (codepoint + 1) (match mismatch with Some m -> m :: acc | None -> acc)
    in
    walk 0xAC00 []
  in
  check (Alcotest.list Alcotest.string) "no syllable reads back wrong"
    [] mismatches

let test_keys_the_layout_cannot_spell () =
  let cases =
    [ ("j", None); ("Q", None); ("esc", None); ("\r", None); ("\127", None)
    ; ("", None); ("jk", None); ("한글", None)
    ; (utf8 0x3164, None) (* Hangul filler: no key types it *)
    ; (utf8 0x6F22, None) (* 漢 *)
    ; (utf8 0x1F600, None) (* an emoji outside the BMP *) ]
  in
  List.iteri
    (fun position (name, expected) ->
      check maybe_spellings (Printf.sprintf "%S at %d" name position) expected
        (Masc_tui_key_ime.latin_keys name))
    cases

let test_single_command_does_not_replay_compound_input () =
  let cases =
    [ "ㅓ", Some "j"; "ㅏ", Some "k"; "ㅜ", Some "n"; "ㅣ", Some "l"
    ; "ㄱ", Some "r"; "ㅟ", None; "눈", None; "n", None; "한글", None ] in
  List.iter (fun (input, expected) ->
    check (option string) input expected (Masc_tui_key_ime.single_latin_key input)) cases

let () =
  Alcotest.run "test_tui_key_ime"
    [ ( "the two-set layout"
      , [ test_case "every letter reads back" `Quick test_every_letter
        ; test_case "conjoining jamo read back" `Quick test_conjoining_jamo
        ] )
    ; ( "syllables"
      , [ test_case "known syllables decompose in typing order" `Quick
            test_known_syllables
        ; test_case "the whole block reads back" `Quick test_every_syllable
        ] )
    ; ( "not ours"
      , [ test_case "what the layout cannot spell passes through" `Quick
            test_keys_the_layout_cannot_spell
        ; test_case "a panel command is never replayed from compound input" `Quick
            test_single_command_does_not_replay_compound_input ] )
    ]
;;
