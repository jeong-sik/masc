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

(* The narrowest terminal that fits the narrow pane, so the cases hold for any
   floor the pane declares. *)
let narrow_fits_cols = Pane.threshold_cols

let test_home_starts_like_every_other_surface () =
  let on_home = Masc_tui_types.acting_pane_layout (state_on Masc_tui_types.Overview) in
  let on_board = Masc_tui_types.acting_pane_layout (state_on Masc_tui_types.Board) in
  check bool "Home and Board start with the same layout" true (on_home = on_board)

let test_home_draws_the_pane_where_the_pane_fits () =
  let layout = Masc_tui_types.acting_pane_layout (state_on Masc_tui_types.Overview) in
  check bool "the pane takes columns beside Home at its floor" true
    (Pane.drawn_cols ~layout ~cols:narrow_fits_cols > 0);
  check int "and none below its floor" 0
    (Pane.drawn_cols ~layout ~cols:(narrow_fits_cols - 1))

let test_a_reader_choice_still_hides_the_pane_on_home () =
  let state = state_on Masc_tui_types.Overview in
  state.acting_pane_preference <- Masc_tui_types.Chosen_acting_pane Pane.Hidden;
  let layout = Masc_tui_types.acting_pane_layout state in
  check int "a hidden pane takes no column" 0
    (Pane.drawn_cols ~layout ~cols:narrow_fits_cols)

let () =
  run "tui acting pane default"
    [ ( "default layout"
      , [ test_case "Home starts like every other surface" `Quick
            test_home_starts_like_every_other_surface
        ; test_case "Home draws the pane where the pane fits" `Quick
            test_home_draws_the_pane_where_the_pane_fits
        ; test_case "a reader choice still hides the pane on Home" `Quick
            test_a_reader_choice_still_hides_the_pane_on_home
        ] )
    ]
