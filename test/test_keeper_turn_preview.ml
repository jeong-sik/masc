open Masc

(* The live-glance plane behind the Answering overlay's preview panel.
   Pins the UTF-8 tail cut, the blank-text guard, and that a tool note
   never erases the last visible words. *)

let test_tail_cuts_on_utf8_boundary () =
  let hangul = String.concat "" (List.init 200 (fun _ -> "\xea\xb0\x80")) in
  Keeper_turn_preview.note_text ~keeper_name:"tail-keeper" ~now:1. hangul;
  match Keeper_turn_preview.current ~keeper_name:"tail-keeper" with
  | None -> Alcotest.fail "text was noted but nothing is current"
  | Some preview ->
    Alcotest.(check bool) "tail fits the byte budget" true
      (String.length preview.Keeper_turn_preview.text_tail
       <= Keeper_turn_preview.tail_bytes);
    Alcotest.(check int) "and starts on a UTF-8 boundary (whole glyphs)" 0
      (String.length preview.Keeper_turn_preview.text_tail mod 3)
;;

let test_blank_text_does_not_erase_the_last_words () =
  Keeper_turn_preview.note_text ~keeper_name:"blank-keeper" ~now:1. "words";
  Keeper_turn_preview.note_text ~keeper_name:"blank-keeper" ~now:2. "   ";
  match Keeper_turn_preview.current ~keeper_name:"blank-keeper" with
  | None -> Alcotest.fail "entry vanished"
  | Some preview ->
    Alcotest.(check string) "a tool-only turn keeps the last visible words"
      "words" preview.Keeper_turn_preview.text_tail
;;

let test_tool_note_keeps_text_and_text_keeps_tool () =
  Keeper_turn_preview.note_text ~keeper_name:"mix-keeper" ~now:1. "drafting";
  Keeper_turn_preview.note_tool ~keeper_name:"mix-keeper" ~now:2.
    (Some "Execute");
  (match Keeper_turn_preview.current ~keeper_name:"mix-keeper" with
   | Some { Keeper_turn_preview.text_tail; current_tool; _ } ->
     Alcotest.(check string) "tool note kept the text" "drafting" text_tail;
     Alcotest.(check (option string)) "and recorded the tool"
       (Some "Execute") current_tool
   | None -> Alcotest.fail "entry vanished");
  Keeper_turn_preview.note_text ~keeper_name:"mix-keeper" ~now:3. "still going";
  match Keeper_turn_preview.current ~keeper_name:"mix-keeper" with
  | Some { Keeper_turn_preview.text_tail; current_tool; _ } ->
    Alcotest.(check string) "text note replaced the tail" "still going"
      text_tail;
    Alcotest.(check (option string)) "and kept the tool" (Some "Execute")
      current_tool
  | None -> Alcotest.fail "entry vanished"
;;

let test_unknown_keeper_has_no_preview () =
  Alcotest.(check bool) "no note, no glance" true
    (Keeper_turn_preview.current ~keeper_name:"never-noted" = None)
;;

let () =
  Alcotest.run "keeper_turn_preview"
    [ ( "keeper-turn-preview"
      , [ Alcotest.test_case "tail cuts on a UTF-8 boundary" `Quick
            test_tail_cuts_on_utf8_boundary
        ; Alcotest.test_case "blank text does not erase the last words" `Quick
            test_blank_text_does_not_erase_the_last_words
        ; Alcotest.test_case "tool and text notes do not clobber each other"
            `Quick test_tool_note_keeps_text_and_text_keeps_tool
        ; Alcotest.test_case "unknown keeper has no preview" `Quick
            test_unknown_keeper_has_no_preview
        ] )
    ]
;;
