module Hearth = Masc_tui_board_hearth

let check_next name expected ~current ~census =
  Alcotest.(check (option string)) name expected (Hearth.next ~current ~census)

(* All, then each hearth in turn, then all again -- so the cycle always has a
   way back to the whole board. The census arrives busiest first, which is how
   a press or two reaches the hearth most of the board is in. *)
let test_the_cycle_returns_to_every_hearth () =
  let census = [ "verification", 447; "ops", 239; "triage", 81 ] in
  check_next "all leads to the busiest" (Some "verification") ~current:None
    ~census;
  check_next "then the next" (Some "ops") ~current:(Some "verification")
    ~census;
  check_next "then the next again" (Some "triage") ~current:(Some "ops")
    ~census;
  check_next "then back to all" None ~current:(Some "triage") ~census

(* Two ways the cycle could strand a reader on a narrowing they cannot leave. *)
let test_the_cycle_cannot_strand_the_reader () =
  check_next "a board with no hearths stays at all" None ~current:None
    ~census:[];
  check_next "and drops a narrowing it can no longer offer" None
    ~current:(Some "ops") ~census:[];
  (* A hearth that emptied out between two censuses. Returning to the whole
     board is the honest answer to "what comes after it". *)
  check_next "a hearth the census no longer holds returns to all" None
    ~current:(Some "retired")
    ~census:[ "verification", 447; "ops", 239 ]

(* The census is the board's own count, not the page's. A hearth whose posts
   all fall outside the listing on screen is still reachable, which is the
   whole reason the count comes from the server. *)
let test_a_hearth_absent_from_the_page_is_still_reachable () =
  check_next "a hearth with no post on this page is offered" (Some "archive")
    ~current:(Some "ops")
    ~census:[ "verification", 447; "ops", 239; "archive", 3 ]

let () =
  Alcotest.run
    "tui board hearth"
    [ ( "cycle"
      , [ Alcotest.test_case "returns to every hearth" `Quick
            test_the_cycle_returns_to_every_hearth
        ; Alcotest.test_case "cannot strand the reader" `Quick
            test_the_cycle_cannot_strand_the_reader
        ; Alcotest.test_case "a hearth absent from the page is reachable"
            `Quick test_a_hearth_absent_from_the_page_is_still_reachable
        ] )
    ]
