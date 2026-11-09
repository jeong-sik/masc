(* Which cells a Keepers row draws in each view, and which rows draw a second
   line (RFC-0515 §2.4, §2.6, E8, E16). *)

module Model = Masc_tui_keeper_list_model
module Axis_row = Masc_tui_keeper_axis_row
module Trail = Masc_tui_keeper_trail

let failed = Trail.Trail_failed { ended_at = None; last = None; walk = Trail.Walk_absent }

let shape_label = function
  | Axis_row.List_columns -> "list columns"
  | Axis_row.Axis { before = Axis_row.Hour_pulse; current = Axis_row.Activity; next = Axis_row.Run_path_lag }
    -> "pulse · activity · run, path, lag"

let second_line_label = function
  | Axis_row.No_second_line -> "none"
  | Axis_row.List_detail -> "list detail"
  | Axis_row.Failure_chain -> "failure chain"

let test_every_view_but_the_list_draws_the_axis_row () =
  List.iter
    (fun view ->
      let expected =
        match view with
        | Model.Plain -> "list columns"
        | Model.By_state | Model.By_cause | Model.By_time | Model.By_memory | Model.By_age
        | Model.By_runtime | Model.Day_wall -> "pulse · activity · run, path, lag"
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
      , [ Alcotest.test_case "every view but the list draws the axis row" `Quick
            test_every_view_but_the_list_draws_the_axis_row
        ] )
    ; ( "second line"
      , [ Alcotest.test_case "two lines add a line under an axis row only when failing" `Quick
            test_two_lines_add_a_line_under_an_axis_row_only_when_failing
        ] )
    ]
