open Alcotest
module Mark = Masc_tui_board_kind_mark
module Types = Masc_tui_types

(* Who put a post on the Board. The column exists for a ratio -- on this
   workspace 22 of 2171 posts were written by a person -- and until now nothing
   on screen or in the help sheet said what its marks meant. *)

let test_a_person_and_an_automation_are_told_apart () =
  check string "a person" "@" (Mark.glyph (Some Types.Post_by_person));
  check string "an automation" "\xe2\x97\x90"
    (Mark.glyph (Some Types.Post_by_automation))

let test_the_ground_carries_no_mark () =
  check string "the system's posts are two thirds of the board" " "
    (Mark.glyph (Some Types.Post_by_system));
  check string "and a kind the wire did not say draws the same blank" " "
    (Mark.glyph None)

let test_a_kind_this_build_does_not_know_says_so () =
  check string "not quietly folded into one of the others" "?"
    (Mark.glyph (Some (Types.Post_kind_unknown "sponsored")))

let test_every_drawn_mark_has_a_word () =
  check int "one legend row per mark that is not a blank"
    (List.length Mark.kinds) (List.length Mark.legend);
  List.iter
    (fun post_kind ->
      let mark = Mark.glyph post_kind in
      if not (String.equal mark " ") then
        check bool ("the legend names " ^ mark) true
          (List.exists (fun (m, _) -> String.equal m mark) Mark.legend))
    [ Some Types.Post_by_person
    ; Some Types.Post_by_automation
    ; Some (Types.Post_kind_unknown "sponsored")
    ; Some Types.Post_by_system
    ; None
    ]

let () =
  run "tui board kind mark"
    [ ( "who wrote it"
      , [ test_case "a person and an automation are told apart" `Quick
            test_a_person_and_an_automation_are_told_apart
        ; test_case "the ground carries no mark" `Quick
            test_the_ground_carries_no_mark
        ; test_case "a kind this build does not know says so" `Quick
            test_a_kind_this_build_does_not_know_says_so
        ; test_case "every drawn mark has a word" `Quick
            test_every_drawn_mark_has_a_word
        ] )
    ]
