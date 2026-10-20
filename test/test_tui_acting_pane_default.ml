(* Which Activity pane layout a surface starts with. Home gets the same
   default as every other surface, so a wide terminal does not leave its right
   side empty, and an explicit reader choice still decides on any surface. *)

open Alcotest
module Pane = Masc_tui_acting_pane

let state_on view =
  let state =
    Masc_tui_types.create_state ~workspace:"test" ~port:8935
      ~refresh_interval:2.0 ()
  in
  state.view <- view;
  state

let layout_label = Pane.layout_label

let wide_terminal_cols = 220

let test_home_starts_like_every_other_surface () =
  let on_home = Masc_tui_types.acting_pane_layout (state_on Masc_tui_types.Overview) in
  let on_board = Masc_tui_types.acting_pane_layout (state_on Masc_tui_types.Board) in
  check string "Home and Board start with the same layout"
    (layout_label on_board) (layout_label on_home)

let test_home_draws_the_pane_on_a_wide_terminal () =
  let layout = Masc_tui_types.acting_pane_layout (state_on Masc_tui_types.Overview) in
  check bool "the pane takes columns beside Home" true
    (Pane.drawn_cols ~layout ~cols:wide_terminal_cols > 0)

let test_a_reader_choice_still_hides_the_pane_on_home () =
  let state = state_on Masc_tui_types.Overview in
  state.acting_pane_preference <- Masc_tui_types.Chosen_acting_pane Pane.Hidden;
  let layout = Masc_tui_types.acting_pane_layout state in
  check int "a hidden pane takes no column" 0
    (Pane.drawn_cols ~layout ~cols:wide_terminal_cols)

let () =
  run "tui acting pane default"
    [ ( "default layout"
      , [ test_case "Home starts like every other surface" `Quick
            test_home_starts_like_every_other_surface
        ; test_case "Home draws the pane on a wide terminal" `Quick
            test_home_draws_the_pane_on_a_wide_terminal
        ; test_case "a reader choice still hides the pane on Home" `Quick
            test_a_reader_choice_still_hides_the_pane_on_home
        ] )
    ]
