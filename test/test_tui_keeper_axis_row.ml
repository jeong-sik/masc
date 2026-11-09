(* Which cells a Keepers row draws in each view, and which rows draw a second
   line (RFC-0515 §2.4, §2.6, E8, E16). *)

module Model = Masc_tui_keeper_list_model
module Axis_row = Masc_tui_keeper_axis_row
module Trail = Masc_tui_keeper_trail

let failed = Trail.Trail_failed { ended_at = None; last = None; walk = Trail.Walk_absent }

let before_label = function
  | Axis_row.Hour_pulse -> "pulse"
  | Axis_row.Fact_ages -> "fact ages"

let current_label = function
  | Axis_row.Librarian_pass -> "librarian pass"
  | Axis_row.Update_age -> "update age"

let next_label = function
  | Axis_row.Lag_digest_gap -> "lag, digest, gap"
  | Axis_row.Lag_stale_facts -> "lag, stale, facts"

let shape_label = function
  | Axis_row.List_columns -> "list columns"
  | Axis_row.Grid Axis_row.Activity_columns -> "grid of the activity columns"
  | Axis_row.Axis { before; current; next } ->
      String.concat " · " [ before_label before; current_label current; next_label next ]

let second_line_label = function
  | Axis_row.No_second_line -> "none"
  | Axis_row.List_detail -> "list detail"
  | Axis_row.Failure_chain -> "failure chain"

let test_each_view_picks_the_cells_of_its_axis_row () =
  List.iter
    (fun view ->
      let expected =
        match view with
        | Model.Plain -> "list columns"
        | Model.By_memory -> "pulse · librarian pass · lag, digest, gap"
        | Model.By_age -> "fact ages · update age · lag, stale, facts"
        | Model.By_state | Model.By_cause | Model.By_time | Model.By_runtime | Model.Day_wall ->
            "grid of the activity columns"
      in
      Alcotest.(check string) (Model.view_label view) expected
        (shape_label (Axis_row.shape_of_view view)))
    Model.views

let test_two_lines_add_a_line_under_an_axis_row_only_when_failing () =
  let axis = Axis_row.shape_of_view Model.By_state in
  let list = Axis_row.shape_of_view Model.Plain in
  let check name expected shape density trail =
    Alcotest.(check string) name expected
      (second_line_label (Axis_row.second_line shape density trail))
  in
  check "a failing axis row draws its failure" "failure chain" axis Model.Two_lines failed;
  check "a sound axis row stays one line" "none" axis Model.Two_lines Trail.Trail_sound;
  check "a list row keeps its detailed line" "list detail" list Model.Two_lines Trail.Trail_sound;
  check "a failing list row keeps its detailed line" "list detail" list Model.Two_lines failed;
  check "one line draws no failure under an axis row" "none" axis Model.One_line failed;
  check "one line draws no detail under a list row" "none" list Model.One_line failed

let () =
  Alcotest.run "tui_keeper_axis_row"
    [ ( "shape"
      , [ Alcotest.test_case "each view picks the cells of its axis row" `Quick
            test_each_view_picks_the_cells_of_its_axis_row
        ] )
    ; ( "second line"
      , [ Alcotest.test_case "two lines add a line under an axis row only when failing" `Quick
            test_two_lines_add_a_line_under_an_axis_row_only_when_failing
        ] )
    ]
