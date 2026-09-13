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

(* The Runtime header kept a private [tab] helper that drew this strip's two
   styles by hand. It matched only while nobody changed either one. *)
let test_the_runtime_header_draws_through_the_strip () =
  Alcotest.(check bool) "render_runtime names its two views through tab_strip"
    true
    (Ast_grep.count_calls_in_value_binding ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"render_runtime" ~callee:"tab_strip"
     >= 1)

let () =
  Alcotest.run "tui_tab_strip"
    [ ( "tab strip"
      , [ Alcotest.test_case "one mark, two cells apart" `Quick
            test_one_mark_two_cells_apart
        ; Alcotest.test_case "no bar between names" `Quick test_no_bar_between_names
        ; Alcotest.test_case "nothing current marks nothing" `Quick
            test_a_strip_with_nothing_current_marks_nothing
        ; Alcotest.test_case "the runtime header draws through the strip" `Quick
            test_the_runtime_header_draws_through_the_strip
        ] )
    ]
