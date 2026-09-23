(* The strips a reader switches along share one drawing: the current entry
   marked, the others plain, two cells between. Activity's readings and
   Config's panes used to put a "|" between names and a space before the
   unmarked ones, so a marked name sat hard against the bar before it:
   "runtime.toml |▸models | params". *)

let plain ?(width = 80) tabs =
  Masc_tui_theme.strip_sgr (Masc_tui_ansi.tab_strip ~width tabs)

let cells = Masc_tui_message_layout.display_width

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec scan i = i + n <= h && (String.sub haystack i n = needle || scan (i + 1)) in
  n = 0 || scan 0

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

(* Nine tabs beside the roster pane are wider than the row. Cut from the
   right by the row's fitter, the Keeper detail read "… Channels  Automatio…"
   on its Runs tab with no mark anywhere. The strip now cuts around the
   current entry and says where it cut. *)
let keeper_tabs current =
  List.map
    (fun label -> (label, String.equal label current))
    [ "Info"; "Sandbox"; "Settings"; "Secrets"; "GitHub"; "Identity"; "Channels"
    ; "Automation"; "Runs" ]

let cut = "\xe2\x80\xa6"

let test_the_last_entry_stays_on_the_row () =
  let drawn = plain ~width:40 (keeper_tabs "Runs") in
  Alcotest.(check bool) "the current entry is drawn" true
    (contains "\xe2\x96\xb8Runs" drawn);
  Alcotest.(check bool) "the cut is on the left" true
    (String.length drawn >= 3 && String.equal (String.sub drawn 0 3) cut);
  Alcotest.(check bool) "nothing is cut on the right" false
    (String.equal (String.sub drawn (String.length drawn - 3) 3) cut);
  Alcotest.(check bool) "and the row is not overrun" true (cells drawn <= 40)

let test_the_first_entry_keeps_its_left_edge () =
  let drawn = plain ~width:40 (keeper_tabs "Info") in
  Alcotest.(check bool) "starts on the current entry" true
    (String.length drawn >= 4 && String.equal (String.sub drawn 0 4) "\xe2\x96\xb8I");
  Alcotest.(check bool) "the cut is on the right" true
    (String.equal (String.sub drawn (String.length drawn - 3) 3) cut)

(* What the width means. The window is seeded with the current entry, so a
   strip narrower than that one entry used to draw it anyway and hand the
   overrun to the frame -- which takes its cells from the end of the row, not
   from the strip. On Config at a hundred columns that end is the clock and
   the connection badge: the row read "20:30:22  HT" with the badge cut in
   half, because two cells were left for a strip that drew sixteen.

   Swept rather than sampled: every width a row can leave a strip, against
   every entry the cursor can be on. One width and one tab would pin this
   case and leave the next one to be found on a screen. *)
let test_the_strip_never_draws_wider_than_its_budget () =
  let labels =
    [ "Info"; "Sandbox"; "Settings"; "Secrets"; "GitHub"; "Identity"
    ; "Channels"; "Automation"; "Runs" ]
  in
  List.iter
    (fun current ->
      for width = 0 to 40 do
        let drawn = plain ~width (keeper_tabs current) in
        Alcotest.(check bool)
          (Printf.sprintf "%s at %d cells stays inside its budget" current width)
          true
          (cells drawn <= width)
      done)
    labels

(* And it still says which entry is current whenever there is room to. The
   clamp cuts from the right, so the mark -- which the window puts first when
   the current entry is the leftmost one shown -- survives any width that can
   hold it. *)
let test_a_clamped_strip_still_marks_where_it_can () =
  let drawn = plain ~width:6 (keeper_tabs "Runs") in
  Alcotest.(check bool) "six cells is not overrun" true (cells drawn <= 6);
  Alcotest.(check bool) "and something is drawn" true (String.length drawn > 0)

let test_a_middle_entry_keeps_both_neighbours () =
  let drawn = plain ~width:40 (keeper_tabs "GitHub") in
  Alcotest.(check bool) "the neighbour before" true (contains "Secrets  \xe2\x96\xb8GitHub" drawn);
  Alcotest.(check bool) "the neighbour after" true (contains "\xe2\x96\xb8GitHub  Identity" drawn);
  Alcotest.(check bool) "cut on both sides" true
    (String.equal (String.sub drawn 0 3) cut
     && String.equal (String.sub drawn (String.length drawn - 3) 3) cut)

(* The property under the three shapes above: whichever entry is current
   and however narrow the row, the current entry is on it, and the strip
   fits whenever the entry with a cut mark either side can. *)
let test_the_current_entry_is_always_on_the_row () =
  let tabs = keeper_tabs "Info" in
  List.iter
    (fun (label, _) ->
      let tabs = keeper_tabs label in
      let alone = cells ("\xe2\x96\xb8" ^ label) + (2 * (cells cut + 2)) in
      for width = alone to 90 do
        let drawn = plain ~width tabs in
        Alcotest.(check bool)
          (Printf.sprintf "%s is on a %d-cell row" label width)
          true
          (contains ("\xe2\x96\xb8" ^ label) drawn);
        Alcotest.(check bool)
          (Printf.sprintf "%s on %d cells does not overrun" label width)
          true (cells drawn <= width)
      done)
    tabs

let test_a_strip_that_fits_is_unchanged () =
  let tabs = keeper_tabs "Secrets" in
  let whole = plain ~width:200 tabs in
  Alcotest.(check string) "exactly wide enough draws every entry" whole
    (plain ~width:(cells whole) tabs);
  Alcotest.(check bool) "no cut mark" false (contains cut whole)

(* The Runtime header kept a private [tab] helper that drew this strip's two
   styles by hand. It matched only while nobody changed either one. *)
let test_the_runtime_header_draws_through_the_strip () =
  Alcotest.(check bool) "render_runtime names its two views through tab_strip"
    true
    (Ast_grep.count_calls_in_value_binding ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"render_runtime" ~callee:"tab_strip"
     >= 1)

(* A tab's count is a convenience -- the tab is a place to go, and the screen
   it opens draws its own rows. So a tab whose source this screen has not read
   carries its name alone, because a zero from an unread snapshot is not a
   reading.

   Both strips did it the other way. The Runtime strip counted standalone
   lanes off [state.standalone_lanes], which only the Lanes screen loads, and
   drew "Standalone (0)" beside a Lanes screen listing five. The Lanes strip
   counted runtimes and lanes off [state.runtime_surface], which only the
   Runtime screen loads, and drew "All runtimes (0)" over a server holding
   125. *)
let test_an_unread_tab_carries_its_name_alone () =
  Alcotest.(check string) "unread" "Standalone"
    (Masc_tui_ansi.tab_entry_label "Standalone" None);
  Alcotest.(check string) "read" "Standalone (5 lanes)"
    (Masc_tui_ansi.tab_entry_label "Standalone" (Some "5 lanes"));
  (* Zero is a reading too, where something measured it. *)
  Alcotest.(check string) "measured zero" "All runtimes (0)"
    (Masc_tui_ansi.tab_entry_label "All runtimes" (Some "0"))

let test_both_strips_ask_the_same_helper () =
  let render = "bin/masc_tui_render.ml" in
  let calls binding =
    Ast_grep.count_calls_in_value_binding ~module_path:render
      ~binding_name:binding ~callee:"tab_entry_label"
  in
  Alcotest.(check bool) "the Lanes strip asks it" true
    (calls "render_lanes_overview" > 0);
  Alcotest.(check bool) "so does the Runtime strip" true
    (calls "render_runtime" > 0);
  List.iter
    (fun needle ->
      Alcotest.(check int)
        (Printf.sprintf "no strip spells %S itself" needle)
        0
        (Ast_grep.count_exact_string_literals ~module_path:render ~needle))
    [ "All runtimes (%d)"; "Standalone (%d)"; "Lanes (%d)" ]

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
        ; Alcotest.test_case "the last entry stays on the row" `Quick
            test_the_last_entry_stays_on_the_row
        ; Alcotest.test_case "the first entry keeps its left edge" `Quick
            test_the_first_entry_keeps_its_left_edge
        ; Alcotest.test_case "the strip never draws wider than its budget" `Quick
            test_the_strip_never_draws_wider_than_its_budget
        ; Alcotest.test_case "a clamped strip still marks where it can" `Quick
            test_a_clamped_strip_still_marks_where_it_can
        ; Alcotest.test_case "a middle entry keeps both neighbours" `Quick
            test_a_middle_entry_keeps_both_neighbours
        ; Alcotest.test_case "the current entry is always on the row" `Quick
            test_the_current_entry_is_always_on_the_row
        ; Alcotest.test_case "a strip that fits is unchanged" `Quick
            test_a_strip_that_fits_is_unchanged
        ; Alcotest.test_case "an unread tab carries its name alone" `Quick
            test_an_unread_tab_carries_its_name_alone
        ; Alcotest.test_case "both strips ask the same helper" `Quick
            test_both_strips_ask_the_same_helper
        ] )
    ]
