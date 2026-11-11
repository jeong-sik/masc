(* The cheat sheet's filter keeps the keys a typed query names. What is checked
   is which sections and entries survive a query: a section whose title holds
   it stays whole, an entry stays when its key or its action holds it, and a
   section left with no entry is not drawn. The second half checks what each
   key does to the filter: which keys are text while a query is typed, how
   Enter and Esc settle it, and that a Korean-mode key types the letters that
   were pressed. *)

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

(* --- what a key does to the filter --- *)

open Masc_tui_help

let pp_filter ppf = function
  | Masc_tui_help.Off -> Format.pp_print_string ppf "Off"
  | Masc_tui_help.Typing query -> Format.fprintf ppf "Typing %S" query
  | Masc_tui_help.Kept query -> Format.fprintf ppf "Kept %S" query

let pp_key_move ppf move =
  Format.pp_print_string ppf
    (match move with
     | Masc_tui_scroll.Line_down -> "Line_down"
     | Masc_tui_scroll.Line_up -> "Line_up"
     | Masc_tui_scroll.Page_down -> "Page_down"
     | Masc_tui_scroll.Page_up -> "Page_up"
     | Masc_tui_scroll.To_top -> "To_top"
     | Masc_tui_scroll.To_end -> "To_end")

let pp_step ppf = function
  | Masc_tui_help.Set_filter { filter; scroll_to_top } ->
      Format.fprintf ppf "Set_filter (%a, scroll_to_top=%b)" pp_filter filter
        scroll_to_top
  | Masc_tui_help.Close -> Format.pp_print_string ppf "Close"
  | Masc_tui_help.Toggle_hints -> Format.pp_print_string ppf "Toggle_hints"
  | Masc_tui_help.Scroll move -> Format.fprintf ppf "Scroll %a" pp_key_move move
  | Masc_tui_help.Ignore -> Format.pp_print_string ppf "Ignore"

let step_t = Alcotest.testable pp_step ( = )
let filter_t = Alcotest.testable pp_filter ( = )

(* A different query is a different sheet, shown from its top. *)
let retyped query =
  Masc_tui_help.Set_filter { filter = Masc_tui_help.Typing query; scroll_to_top = true }

let settled filter =
  Masc_tui_help.Set_filter { filter; scroll_to_top = false }

let cleared =
  Masc_tui_help.Set_filter { filter = Masc_tui_help.Off; scroll_to_top = true }

let check_steps label filter cases =
  List.iter
    (fun (key, expected) ->
      Alcotest.check step_t
        (Printf.sprintf "%s: %S" label key)
        expected
        (Masc_tui_help.step filter ~key))
    cases

let test_filter_query () =
  Alcotest.(check string) "off holds nothing" "" (Masc_tui_help.filter_query Off);
  Alcotest.(check string) "typing holds the text" "ab"
    (Masc_tui_help.filter_query (Typing "ab"));
  Alcotest.(check string) "kept holds the text" "ab"
    (Masc_tui_help.filter_query (Kept "ab"))

let test_off_keys () =
  check_steps "off" Masc_tui_help.Off
    [ ("/", settled (Typing ""))
    ; ("?", Close)
    ; ("esc", Close)
    ; ("h", Toggle_hints)
    ; ("j", Scroll Masc_tui_scroll.Line_down)
    ; ("k", Scroll Masc_tui_scroll.Line_up)
    ; ("down", Scroll Masc_tui_scroll.Line_down)
    ; ("up", Scroll Masc_tui_scroll.Line_up)
    ; ("pageup", Scroll Masc_tui_scroll.Page_up)
    ; ("pagedown", Scroll Masc_tui_scroll.Page_down)
    ; ("g", Scroll Masc_tui_scroll.To_top)
    ; ("G", Scroll Masc_tui_scroll.To_end)
    ; ("home", Scroll Masc_tui_scroll.To_top)
    ; ("end", Scroll Masc_tui_scroll.To_end)
    ; ("x", Ignore)
    ; ("\r", Ignore)
    ; ("tab", Ignore)
    ]

let test_typing_takes_printable_keys_as_text () =
  check_steps "typing ab" (Masc_tui_help.Typing "ab")
    [ ("h", retyped "abh")
    ; ("j", retyped "abj")
    ; ("k", retyped "abk")
    ; ("g", retyped "abg")
    ; ("G", retyped "abG")
    ; ("?", retyped "ab?")
    ; ("/", retyped "ab/")
    ; (" ", retyped "ab ")
    ; ("7", retyped "ab7")
    ; ("\xc3\xa9", retyped "ab\xc3\xa9")
    ]

let test_typing_enter_settles_the_query () =
  check_steps "typing ab" (Masc_tui_help.Typing "ab")
    [ ("\r", settled (Kept "ab")); ("\n", settled (Kept "ab")) ];
  check_steps "typing nothing" (Masc_tui_help.Typing "")
    [ ("\r", settled Off); ("\n", settled Off) ]

let test_typing_esc_clears () =
  check_steps "typing ab" (Masc_tui_help.Typing "ab") [ ("esc", cleared) ];
  check_steps "typing nothing" (Masc_tui_help.Typing "") [ ("esc", cleared) ]

let test_typing_backspace_drops_one_character () =
  check_steps "typing ab" (Masc_tui_help.Typing "ab")
    [ ("\127", retyped "a"); ("\b", retyped "a") ];
  check_steps "typing a" (Masc_tui_help.Typing "a") [ ("\127", retyped "") ];
  check_steps "typing nothing" (Masc_tui_help.Typing "")
    [ ("\127", retyped "") ];
  check_steps "typing a then e-acute" (Masc_tui_help.Typing "a\xc3\xa9")
    [ ("\127", retyped "a") ]

let test_typing_scrolls_with_the_arrows_and_pages () =
  check_steps "typing ab" (Masc_tui_help.Typing "ab")
    [ ("down", Scroll Masc_tui_scroll.Line_down)
    ; ("up", Scroll Masc_tui_scroll.Line_up)
    ; ("pageup", Scroll Masc_tui_scroll.Page_up)
    ; ("pagedown", Scroll Masc_tui_scroll.Page_down)
    ]

let test_typing_ignores_control_keys () =
  check_steps "typing ab" (Masc_tui_help.Typing "ab")
    [ ("tab", Ignore); ("\t", Ignore); ("left", Ignore); ("home", Ignore) ]

let test_kept_keys () =
  check_steps "kept ab" (Masc_tui_help.Kept "ab")
    [ ("esc", cleared)
    ; ("/", settled (Typing "ab"))
    ; ("?", Close)
    ; ("h", Toggle_hints)
    ; ("j", Scroll Masc_tui_scroll.Line_down)
    ; ("g", Scroll Masc_tui_scroll.To_top)
    ; ("G", Scroll Masc_tui_scroll.To_end)
    ; ("end", Scroll Masc_tui_scroll.To_end)
    ; ("x", Ignore)
    ; ("\r", Ignore)
    ]

(* Esc clears a kept query, and only the Esc after that closes the sheet. *)
let test_esc_clears_before_it_closes () =
  Alcotest.check step_t "first Esc on a kept query" cleared
    (Masc_tui_help.step (Masc_tui_help.Kept "ab") ~key:"esc");
  Alcotest.check step_t "next Esc on the whole sheet" Close
    (Masc_tui_help.step Masc_tui_help.Off ~key:"esc")

let type_keys keys =
  List.fold_left
    (fun filter key ->
      match Masc_tui_help.step filter ~key with
      | Masc_tui_help.Set_filter { filter; _ } -> filter
      | other -> Alcotest.failf "key %S gave %a" key pp_step other)
    (Masc_tui_help.Typing "") keys

let test_korean_mode_types_the_letters_pressed () =
  (* The word as the terminal commits it: composed syllables and lone jamo. *)
  Alcotest.check filter_t "approve typed as Hangul"
    (Masc_tui_help.Typing "approve")
    (type_keys [ "\xeb\xa9\x94"; "\xe3\x85\x94"; "\xea\xb0\xb6"; "\xe3\x84\xb7" ]);
  Alcotest.check filter_t "approve typed as single letters"
    (Masc_tui_help.Typing "approve")
    (type_keys
       [ "\xe3\x85\x81"; "\xe3\x85\x94"; "\xe3\x85\x94"; "\xe3\x84\xb1"
       ; "\xe3\x85\x90"; "\xe3\x85\x8d"; "\xe3\x84\xb7" ]);
  Alcotest.check filter_t "Latin and Hangul keys in one query"
    (Masc_tui_help.Typing "hap")
    (type_keys [ "h"; "\xeb\xa9\x94" ])

let test_filter_chain_from_off_to_closed () =
  (* /, text, Enter, Esc, Esc: the sheet narrows, settles, widens, closes. *)
  let apply filter key =
    match Masc_tui_help.step filter ~key with
    | Masc_tui_help.Set_filter { filter; _ } -> filter
    | other -> Alcotest.failf "key %S gave %a" key pp_step other
  in
  let typing = apply Masc_tui_help.Off "/" in
  Alcotest.check filter_t "slash opens the filter" (Masc_tui_help.Typing "") typing;
  let typed = apply (apply typing "a") "b" in
  Alcotest.check filter_t "text is typed" (Masc_tui_help.Typing "ab") typed;
  let kept = apply typed "\r" in
  Alcotest.check filter_t "Enter keeps it" (Masc_tui_help.Kept "ab") kept;
  let cleared_filter = apply kept "esc" in
  Alcotest.check filter_t "Esc clears it" Masc_tui_help.Off cleared_filter;
  Alcotest.check step_t "the next Esc closes the sheet" Close
    (Masc_tui_help.step cleared_filter ~key:"esc")

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
    ; ( "step"
      , [ Alcotest.test_case "filter_query" `Quick test_filter_query
        ; Alcotest.test_case "off: the sheet's own keys" `Quick test_off_keys
        ; Alcotest.test_case "typing: printable keys are text" `Quick
            test_typing_takes_printable_keys_as_text
        ; Alcotest.test_case "typing: Enter settles the query" `Quick
            test_typing_enter_settles_the_query
        ; Alcotest.test_case "typing: Esc clears" `Quick test_typing_esc_clears
        ; Alcotest.test_case "typing: Backspace drops one character" `Quick
            test_typing_backspace_drops_one_character
        ; Alcotest.test_case "typing: arrows and pages scroll" `Quick
            test_typing_scrolls_with_the_arrows_and_pages
        ; Alcotest.test_case "typing: control keys do nothing" `Quick
            test_typing_ignores_control_keys
        ; Alcotest.test_case "kept: the sheet's keys come back" `Quick test_kept_keys
        ; Alcotest.test_case "Esc clears before it closes" `Quick
            test_esc_clears_before_it_closes
        ; Alcotest.test_case "Korean mode types the letters pressed" `Quick
            test_korean_mode_types_the_letters_pressed
        ; Alcotest.test_case "off to kept to closed" `Quick
            test_filter_chain_from_off_to_closed
        ] )
    ]
