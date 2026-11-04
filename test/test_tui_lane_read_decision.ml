open Alcotest

module Decision = Masc_tui_lane_read_decision

let test_lanes_read_only_when_visible () =
  check bool "Lanes is read on its own surface" true
    (Decision.of_dataset ~view:Decision.Lanes
       Masc.Workspace_dataset_event.Lanes = Decision.Read_lanes);
  check bool "Lanes is not read for another surface" true
    (Decision.of_dataset ~view:Decision.Overview
       Masc.Workspace_dataset_event.Lanes = Decision.Ignore)

let test_addon_read_is_scoped_to_the_open_instance () =
  let dataset = Masc.Workspace_dataset_event.Lane_addons { instance_id = "quiz-1" } in
  check bool "the open instance is read" true
    (Decision.of_dataset ~view:(Decision.Addons (Some "quiz-1")) dataset
     = Decision.Read_addon "quiz-1");
  check bool "another instance is not read" true
    (Decision.of_dataset ~view:(Decision.Addons (Some "someone-else")) dataset
     = Decision.Ignore);
  check bool "no open instance means no read" true
    (Decision.of_dataset ~view:(Decision.Addons None) dataset = Decision.Ignore)

let () =
  run "Lane read decision"
    [ "scope",
      [ test_case "Lanes reads only while visible" `Quick test_lanes_read_only_when_visible
      ; test_case "Add-on reads only the open instance" `Quick test_addon_read_is_scoped_to_the_open_instance
      ] ]
