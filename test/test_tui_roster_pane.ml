(** The roster shares the screen on two conditions, and they are different
    kinds of fact.

    Before the toggle the roster appeared whenever the terminal was wide
    enough, so a keeper chat gave up 30 columns to a list the reader might
    already know by heart. Hiding it is now the reader's decision, and a
    decision has to survive a resize -- otherwise dragging the window would
    silently undo it. *)

module Pane = Masc_tui_roster_pane

let check_bool = Alcotest.(check bool)
let wide = Pane.threshold_cols + 40
let narrow = Pane.threshold_cols - 1

let test_explicit_choice_survives_width_changes () =
  List.iter (fun (preference, expected) ->
    let preference = match Pane.toggle_preference preference ~cols:wide with
      | Some preference -> preference
      | None -> Alcotest.fail "wide toggle must record a choice" in
    List.iter (fun cols ->
      check_bool "explicit choice survives resizing"
        (expected && cols >= Pane.threshold_cols)
        (Pane.shown ~hidden:(Pane.effective_hidden preference) ~cols))
      [wide; narrow; Pane.threshold_cols; wide])
    [Pane.Shown, false; Pane.Hidden, true]

let test_narrow_toggle_preserves_preference () =
  List.iter (fun preference ->
    match Pane.toggle_preference preference ~cols:narrow with
    | None -> ()
    | Some _ -> Alcotest.fail "a narrow toggle changed the stored preference")
    [Pane.Hidden; Pane.Shown]

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
      , [ Alcotest.test_case "explicit choice survives surface and width changes" `Quick
            test_explicit_choice_survives_width_changes
        ; Alcotest.test_case "narrow toggle preserves every preference" `Quick
            test_narrow_toggle_preserves_preference
        ; Alcotest.test_case "a wide terminal shows the roster" `Quick
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
      , [] )
    ; ( "marquee"
      , [] )
    ]
