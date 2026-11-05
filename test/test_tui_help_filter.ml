(* The cheat sheet's filter keeps the keys a typed query names. What is checked
   is which sections and entries survive a query: a section whose title holds
   it stays whole, an entry stays when its key or its action holds it, and a
   section left with no entry is not drawn. *)

let sections =
  [ ("Navigation", [ ("Tab", "next surface"); ("?", "help screen") ])
  ; ("Board", [ ("j/k", "scroll posts"); ("Enter", "open the post") ])
  ; ("Scrolling", [ ("g", "first row"); ("G", "last row") ])
  ]

let shape = Alcotest.(list (pair string (list (pair string string))))
let filtered query = Masc_tui_help.filter_sections ~query ~heading:Fun.id sections

(* The sheet marks the section of the surface the reader is on. The mark is
   not part of the name, so a query does not match it. *)
let mark = " (here)"

let heading title =
  if String.ends_with ~suffix:mark title then
    String.sub title 0 (String.length title - String.length mark)
  else title

let test_empty_query_keeps_every_section () =
  Alcotest.check shape "all sections as written" sections (filtered "")

let test_entry_matches_by_key () =
  Alcotest.check shape "the Enter entry" [ ("Board", [ ("Enter", "open the post") ]) ]
    (filtered "enter")

let test_entry_matches_by_action () =
  Alcotest.check shape "the help entry" [ ("Navigation", [ ("?", "help screen") ]) ]
    (filtered "help")

let test_case_does_not_matter () =
  Alcotest.check shape "upper case finds the Tab entry"
    [ ("Navigation", [ ("Tab", "next surface") ]) ]
    (filtered "TAB")

let test_title_keeps_the_section_whole () =
  Alcotest.check shape "both entries of Scrolling, though neither holds the query"
    [ ("Scrolling", [ ("g", "first row"); ("G", "last row") ]) ]
    (filtered "scrolling")

let test_title_and_entry_matches_both_count () =
  Alcotest.check shape "the matching entry of Board, then all of Scrolling"
    [ ("Board", [ ("j/k", "scroll posts") ])
    ; ("Scrolling", [ ("g", "first row"); ("G", "last row") ])
    ]
    (filtered "scroll")

let test_section_without_a_match_goes () =
  Alcotest.check shape "nothing is left" [] (filtered "zzz")

let test_mark_beside_a_title_does_not_match () =
  let marked = [ ("Board" ^ mark, [ ("j/k", "scroll posts") ]) ] in
  Alcotest.check shape "the mark answers nothing" []
    (Masc_tui_help.filter_sections ~query:"here" ~heading marked);
  Alcotest.check shape "the name still keeps the section whole"
    [ ("Board" ^ mark, [ ("j/k", "scroll posts") ]) ]
    (Masc_tui_help.filter_sections ~query:"board" ~heading marked)

let () =
  Alcotest.run "tui_help_filter"
    [ ( "filter_sections"
      , [ Alcotest.test_case "empty query keeps every section" `Quick
            test_empty_query_keeps_every_section
        ; Alcotest.test_case "entry matches by key" `Quick test_entry_matches_by_key
        ; Alcotest.test_case "entry matches by action" `Quick test_entry_matches_by_action
        ; Alcotest.test_case "case does not matter" `Quick test_case_does_not_matter
        ; Alcotest.test_case "title keeps the section whole" `Quick
            test_title_keeps_the_section_whole
        ; Alcotest.test_case "title and entry matches both count" `Quick
            test_title_and_entry_matches_both_count
        ; Alcotest.test_case "section without a match goes" `Quick
            test_section_without_a_match_goes
        ; Alcotest.test_case "mark beside a title does not match" `Quick
            test_mark_beside_a_title_does_not_match
        ] )
    ]
