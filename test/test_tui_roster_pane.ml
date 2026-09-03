(** The roster shares the screen on two conditions, and they are different
    kinds of fact.

    Before the toggle the roster appeared whenever the terminal was wide
    enough, so a keeper chat gave up 30 columns to a list the reader might
    already know by heart. Hiding it is now the reader's decision, and a
    decision has to survive a resize -- otherwise dragging the window would
    silently undo it. *)

module Pane = Masc_tui_roster_pane

let check_bool = Alcotest.(check bool)
let check_int = Alcotest.(check int)
let check_string = Alcotest.(check string)

let wide = Pane.threshold_cols + 40
let narrow = Pane.threshold_cols - 1

let test_a_wide_terminal_shows_the_roster () =
  check_bool "wide and wanted" true (Pane.shown ~hidden:false ~cols:wide)

let test_a_narrow_terminal_keeps_it_away () =
  check_bool "narrow, whatever the reader wants" false
    (Pane.shown ~hidden:false ~cols:narrow);
  check_bool "and hiding does not change that" false
    (Pane.shown ~hidden:true ~cols:narrow)

let test_hiding_wins_on_a_wide_terminal () =
  check_bool "the reader's answer decides when there is room" false
    (Pane.shown ~hidden:true ~cols:wide)

let test_toggle_changes_only_a_visible_preference () =
  Alcotest.(check (option bool)) "wide can hide" (Some true)
    (Pane.toggle_hidden ~hidden:false ~cols:wide);
  Alcotest.(check (option bool)) "wide can show" (Some false)
    (Pane.toggle_hidden ~hidden:true ~cols:wide);
  Alcotest.(check (option bool)) "narrow visible preference is untouched" None
    (Pane.toggle_hidden ~hidden:false ~cols:narrow);
  Alcotest.(check (option bool)) "narrow hidden preference is untouched" None
    (Pane.toggle_hidden ~hidden:true ~cols:narrow)

let test_hiding_survives_a_resize () =
  (* The decision is carried, not recomputed: every width answers the same
     while it stands. *)
  List.iter
    (fun cols ->
      check_bool
        (Printf.sprintf "still hidden at %d columns" cols)
        false
        (Pane.shown ~hidden:true ~cols))
    [ 20; narrow; Pane.threshold_cols; wide; 400 ]

let test_the_threshold_is_the_first_width_that_shows () =
  check_bool "one column short is too narrow" false
    (Pane.shown ~hidden:false ~cols:(Pane.threshold_cols - 1));
  check_bool "the threshold itself is wide enough" true
    (Pane.shown ~hidden:false ~cols:Pane.threshold_cols)

let test_hidden_gives_its_columns_back () =
  check_int "the surface gets the whole width" wide
    (Pane.content_cols ~hidden:true ~cols:wide);
  check_int "and only the remainder while it shows" (wide - Pane.pane_cols)
    (Pane.content_cols ~hidden:false ~cols:wide)

let test_a_narrow_terminal_never_loses_columns () =
  check_int "nothing is subtracted when nothing is drawn" narrow
    (Pane.content_cols ~hidden:false ~cols:narrow)

let test_the_pane_fits_inside_the_threshold () =
  check_bool "a shown roster always leaves the surface something" true
    (Pane.content_cols ~hidden:false ~cols:Pane.threshold_cols > 0)

let test_the_pane_keeps_an_ordinary_configured_name_whole () =
  let name = "kidsnote-pr-jira-checker" in
  let width = Pane.pane_cols - 7 in
  check_string "ordinary configured name is not ellipsized" name
    (String.trim
       (Pane.name_window ~selected:false ~frame:0 ~width name))

let test_marquee_pauses_travels_and_returns () =
  let offset frame = Pane.marquee_offset ~frame ~overflow:3 in
  List.iter (fun frame -> check_int "opening pause" 0 (offset frame))
    [ 0; 1; 2; 3; 4 ];
  check_int "travels right" 1 (offset 5);
  check_int "reaches the far edge" 3 (offset 7);
  List.iter (fun frame -> check_int "far-edge pause" 3 (offset frame))
    [ 8; 9; 10; 11; 12 ];
  check_int "travels left" 2 (offset 13);
  check_int "returns home" 0 (offset 15);
  check_int "repeats" 0 (offset 16)

let test_marquee_clamps_empty_inputs () =
  check_int "a fitting name never moves" 0
    (Pane.marquee_offset ~frame:99 ~overflow:0);
  check_int "negative values start at zero" 0
    (Pane.marquee_offset ~frame:(-9) ~overflow:(-3))

let test_selected_name_window_marks_hidden_edges () =
  check_string "starts with the head and marks the hidden tail" " abcdef…"
    (Pane.name_window ~selected:true ~frame:0 ~width:8 "abcdefghij");
  check_string "motion marks both hidden edges" "…bcdefg…"
    (Pane.name_window ~selected:true ~frame:5 ~width:8 "abcdefghij");
  check_string "the far edge exposes the full tail" "…efghij "
    (Pane.name_window ~selected:true ~frame:8 ~width:8 "abcdefghij")

let test_name_window_is_static_until_selected_and_overflowing () =
  (* An unselected row does not move, but it still has to be identifiable.
     It used to keep the head and drop the tail ("abcdefg~"), which rendered
     every keeper sharing a prefix the same. It now drops the middle, so both
     the shared family and the deciding tail survive; only the cursor row
     scrolls the whole name. See [Masc_tui_message_layout.fit_middle]. *)
  check_string "an unselected name keeps both ends" "ab\xe2\x80\xa6fghij"
    (Pane.name_window ~selected:false ~frame:8 ~width:8 "abcdefghij");
  check_int "and still occupies the exact cell budget" 8
    (Masc_tui_message_layout.display_width
       (Pane.name_window ~selected:false ~frame:8 ~width:8 "abcdefghij"));
  check_string "a short selected name stays still" "abc     "
    (Pane.name_window ~selected:true ~frame:99 ~width:8 "abc");
  check_int "a wide name still occupies the exact cell budget" 8
    (Masc_tui_message_layout.display_width
       (Pane.name_window ~selected:true ~frame:5 ~width:8 "가나다라마바사"))

(* ── which pane a cursor key belongs to ─────────────────────────────── *)

let test_a_hidden_pane_does_not_hold_the_arrows () =
  (* The reader put the roster away with Ctrl-B. The stored preference still
     says left, and acting on it moves a keeper cursor nobody can see --
     which, with the selection already at the end of the roster, moves
     nothing at all and reads as a dead key. *)
  Alcotest.(check bool)
    "not while it is put away" false
    (Masc_tui_roster_pane.arrows_go_left ~hidden:true ~cols:200
       ~preferring_left:true)

let test_a_pane_too_narrow_to_draw_does_not_hold_them_either () =
  Alcotest.(check bool)
    "nor below the width it needs" false
    (Masc_tui_roster_pane.arrows_go_left ~hidden:false
       ~cols:(Masc_tui_roster_pane.threshold_cols - 1) ~preferring_left:true)

let test_a_drawn_pane_keeps_what_the_reader_asked_for () =
  Alcotest.(check bool)
    "left when asked and drawn" true
    (Masc_tui_roster_pane.arrows_go_left ~hidden:false ~cols:200
       ~preferring_left:true);
  Alcotest.(check bool)
    "right when that is what was asked" false
    (Masc_tui_roster_pane.arrows_go_left ~hidden:false ~cols:200
       ~preferring_left:false)

let () =
  Alcotest.run "tui_roster_pane"
    [ ( "which pane holds the arrows"
      , [ Alcotest.test_case "a hidden pane does not" `Quick
            test_a_hidden_pane_does_not_hold_the_arrows
        ; Alcotest.test_case "nor one too narrow to draw" `Quick
            test_a_pane_too_narrow_to_draw_does_not_hold_them_either
        ; Alcotest.test_case "a drawn pane keeps the preference" `Quick
            test_a_drawn_pane_keeps_what_the_reader_asked_for
        ] )
    ; ( "shown"
      , [ Alcotest.test_case "a wide terminal shows the roster" `Quick
            test_a_wide_terminal_shows_the_roster
        ; Alcotest.test_case "a narrow terminal keeps it away" `Quick
            test_a_narrow_terminal_keeps_it_away
        ; Alcotest.test_case "hiding wins on a wide terminal" `Quick
            test_hiding_wins_on_a_wide_terminal
        ; Alcotest.test_case "toggle changes only a visible preference" `Quick
            test_toggle_changes_only_a_visible_preference
        ; Alcotest.test_case "hiding survives a resize" `Quick
            test_hiding_survives_a_resize
        ; Alcotest.test_case "the threshold is the first width that shows"
            `Quick test_the_threshold_is_the_first_width_that_shows
        ] )
    ; ( "columns"
      , [ Alcotest.test_case "hidden gives its columns back" `Quick
            test_hidden_gives_its_columns_back
        ; Alcotest.test_case "a narrow terminal never loses columns" `Quick
            test_a_narrow_terminal_never_loses_columns
        ; Alcotest.test_case "the pane fits inside the threshold" `Quick
            test_the_pane_fits_inside_the_threshold
        ; Alcotest.test_case "ordinary configured name reads whole" `Quick
            test_the_pane_keeps_an_ordinary_configured_name_whole
        ] )
    ; ( "marquee"
      , [ Alcotest.test_case "pauses, travels, and returns" `Quick
            test_marquee_pauses_travels_and_returns
        ; Alcotest.test_case "clamps empty inputs" `Quick
            test_marquee_clamps_empty_inputs
        ; Alcotest.test_case "marks hidden edges" `Quick
            test_selected_name_window_marks_hidden_edges
        ; Alcotest.test_case "moves only selected overflow" `Quick
            test_name_window_is_static_until_selected_and_overflowing
        ] )
    ]
