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

let () =
  Alcotest.run "tui_roster_pane"
    [ ( "shown"
      , [ Alcotest.test_case "a wide terminal shows the roster" `Quick
            test_a_wide_terminal_shows_the_roster
        ; Alcotest.test_case "a narrow terminal keeps it away" `Quick
            test_a_narrow_terminal_keeps_it_away
        ; Alcotest.test_case "hiding wins on a wide terminal" `Quick
            test_hiding_wins_on_a_wide_terminal
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
        ] )
    ]
