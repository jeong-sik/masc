(* The strips a reader switches along share one drawing: the current entry
   marked, the others plain, two cells between. Activity's readings and
   Config's panes used to put a "|" between names and a space before the
   unmarked ones, so a marked name sat hard against the bar before it:
   "runtime.toml |▸models | params". *)

let plain tabs = Masc_tui_theme.strip_sgr (Masc_tui_ansi.tab_strip tabs)

let test_one_mark_two_cells_apart () =
  Alcotest.(check string) "the current entry wears the mark"
    "runtime.toml  \xe2\x96\xb8models  params"
    (plain [ ("runtime.toml", false); ("models", true); ("params", false) ])

let test_no_bar_between_names () =
  let drawn = plain [ ("Events", true); ("Logs", false) ] in
  Alcotest.(check bool) "no bar" false (String.contains drawn '|');
  Alcotest.(check string) "the first entry can be current" "\xe2\x96\xb8Events  Logs" drawn

let test_a_strip_with_nothing_current_marks_nothing () =
  Alcotest.(check string) "no mark when nothing is current" "a  b"
    (plain [ ("a", false); ("b", false) ])

let () =
  Alcotest.run "tui_tab_strip"
    [ ( "tab strip"
      , [ Alcotest.test_case "one mark, two cells apart" `Quick
            test_one_mark_two_cells_apart
        ; Alcotest.test_case "no bar between names" `Quick test_no_bar_between_names
        ; Alcotest.test_case "nothing current marks nothing" `Quick
            test_a_strip_with_nothing_current_marks_nothing
        ] )
    ]
