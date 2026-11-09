(* Which cells a Keepers row draws in each view, and which rows draw a second
   line (RFC-0515 §2.4, §2.4.6, §2.6, E8, E16). *)

module Model = Masc_tui_keeper_list_model
module Axis_row = Masc_tui_keeper_axis_row
module Trail = Masc_tui_keeper_trail

let failed = Trail.Trail_failed { ended_at = None; last = None; walk = Trail.Walk_absent }

let shape_label = function
  | Axis_row.List_columns -> "list columns"
  | Axis_row.Grid Axis_row.Activity_columns -> "grid of the activity columns"
  | Axis_row.Grid Axis_row.Memory_columns -> "grid of the memory columns"
  | Axis_row.Grid Axis_row.Age_columns -> "grid of the age columns"

let second_line_label = function
  | Axis_row.No_second_line -> "none"
  | Axis_row.List_detail -> "list detail"
  | Axis_row.Failure_chain -> "failure chain"

let test_each_view_picks_the_columns_it_draws () =
  List.iter
    (fun view ->
      let expected =
        match view with
        | Model.Plain -> "list columns"
        | Model.By_memory -> "grid of the memory columns"
        | Model.By_age -> "grid of the age columns"
        | Model.By_state | Model.By_cause | Model.By_time | Model.By_runtime | Model.Day_wall ->
            "grid of the activity columns"
      in
      Alcotest.(check string) (Model.view_label view) expected
        (shape_label (Axis_row.shape_of_view view)))
    Model.views

let check name expected view density trail =
  Alcotest.(check string) name expected
    (second_line_label (Axis_row.second_line view density trail))

let test_the_state_and_cause_views_add_a_line_only_under_a_failing_keeper () =
  List.iter
    (fun view ->
      let label = Model.view_label view in
      check (label ^ ": a failing row draws its failure") "failure chain" view Model.Two_lines failed;
      check (label ^ ": a sound row stays one line") "none" view Model.Two_lines Trail.Trail_sound;
      check (label ^ ": one line draws no failure") "none" view Model.One_line failed)
    [ Model.By_state; Model.By_cause ]

let test_the_other_views_keep_one_line () =
  List.iter
    (fun view ->
      check (Model.view_label view ^ ": a failing row stays one line") "none" view Model.Two_lines
        failed)
    [ Model.By_time; Model.By_memory; Model.By_age; Model.By_runtime; Model.Day_wall ]

let test_the_list_keeps_its_detailed_line () =
  check "a list row keeps its detailed line" "list detail" Model.Plain Model.Two_lines
    Trail.Trail_sound;
  check "a failing list row keeps its detailed line" "list detail" Model.Plain Model.Two_lines failed;
  check "one line draws no detail under a list row" "none" Model.Plain Model.One_line failed

let () =
  Alcotest.run "tui_keeper_axis_row"
    [ ( "shape"
      , [ Alcotest.test_case "each view picks the columns it draws" `Quick
            test_each_view_picks_the_columns_it_draws
        ] )
    ; ( "second line"
      , [ Alcotest.test_case "the state and cause views add a line only under a failing keeper"
            `Quick test_the_state_and_cause_views_add_a_line_only_under_a_failing_keeper
        ; Alcotest.test_case "the other views keep one line" `Quick
            test_the_other_views_keep_one_line
        ; Alcotest.test_case "the list keeps its detailed line" `Quick
            test_the_list_keeps_its_detailed_line
        ] )
    ]
