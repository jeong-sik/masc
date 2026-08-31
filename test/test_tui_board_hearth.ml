module Hearth = Masc_tui_board_hearth
open Masc_tui_types

let post ?hearth id =
  { bp_id = id
  ; bp_author = "author"
  ; bp_title = "title-" ^ id
  ; bp_body = ""
  ; bp_votes = 0
  ; bp_comment_count = 0
  ; bp_created_at = "2026-08-31T00:00:00Z"
  ; bp_hearth = hearth
  ; bp_kind = None
  }

let strings = Alcotest.(list string)

(* Busiest first, so a press or two reaches the hearth most of the board is in.
   This workspace has 24 of them and 1550 of 2171 posts in one. *)
let test_vocabulary_leads_with_the_busiest_hearth () =
  Alcotest.check strings "the crowded hearth leads"
    [ "verification"; "ops"; "release" ]
    (Hearth.vocabulary
       [ post "a" ~hearth:"ops"
       ; post "b" ~hearth:"verification"
       ; post "c" ~hearth:"verification"
       ; post "d" ~hearth:"release"
       ; post "e" ~hearth:"verification"
       ; post "f" ~hearth:"ops"
       ]);
  Alcotest.check strings "a tie reads in name order" [ "alpha"; "beta" ]
    (Hearth.vocabulary [ post "a" ~hearth:"beta"; post "b" ~hearth:"alpha" ])

(* A post with no hearth is not a hearth called "". Neither is one whose
   hearth is whitespace: the store normalises on write, and a listing that
   offered a blank narrowing would take the reader to an empty board. *)
let test_a_post_without_a_hearth_contributes_none () =
  Alcotest.check strings "no hearth, no entry" [ "ops" ]
    (Hearth.vocabulary
       [ post "a"; post "b" ~hearth:"ops"; post "c" ~hearth:"   " ]);
  Alcotest.check strings "a board with no hearths offers nothing" []
    (Hearth.vocabulary [ post "a"; post "b" ])

let check_next name expected ~current ~vocabulary =
  Alcotest.(check (option string)) name expected (Hearth.next ~current ~vocabulary)

(* All, then each hearth in turn, then all again -- so the cycle always has a
   way back to the whole board. *)
let test_the_cycle_returns_to_every_hearth () =
  let vocabulary = [ "verification"; "ops" ] in
  check_next "all leads to the busiest" (Some "verification") ~current:None
    ~vocabulary;
  check_next "then the next" (Some "ops") ~current:(Some "verification")
    ~vocabulary;
  check_next "then back to all" None ~current:(Some "ops") ~vocabulary

(* Two ways the cycle could strand a reader on a narrowing they cannot leave. *)
let test_the_cycle_cannot_strand_the_reader () =
  check_next "a board with no hearths stays at all" None ~current:None
    ~vocabulary:[];
  check_next "and drops a narrowing it can no longer offer" None
    ~current:(Some "ops") ~vocabulary:[];
  (* A hearth that emptied out between two listings. Returning to the whole
     board is the honest answer to "what comes after it". *)
  check_next "a hearth the board no longer holds returns to all" None
    ~current:(Some "retired") ~vocabulary:[ "verification"; "ops" ]

let () =
  Alcotest.run
    "tui board hearth"
    [ ( "vocabulary"
      , [ Alcotest.test_case "leads with the busiest hearth" `Quick
            test_vocabulary_leads_with_the_busiest_hearth
        ; Alcotest.test_case "a post without a hearth contributes none" `Quick
            test_a_post_without_a_hearth_contributes_none
        ] )
    ; ( "cycle"
      , [ Alcotest.test_case "returns to every hearth" `Quick
            test_the_cycle_returns_to_every_hearth
        ; Alcotest.test_case "cannot strand the reader" `Quick
            test_the_cycle_cannot_strand_the_reader
        ] )
    ]
