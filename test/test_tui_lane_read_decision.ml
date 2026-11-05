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

let test_open_addon_wins_over_the_lanes_surface () =
  let dataset = Masc.Workspace_dataset_event.Lane_addons { instance_id = "quiz-1" } in
  check bool "an Add-on open over Lanes still owns its Inspect push" true
    (Decision.of_views ~lanes:true ~addon:(Some "quiz-1") dataset
     = Decision.Read_addon "quiz-1");
  check bool "another instance is still ignored over Lanes" true
    (Decision.of_views ~lanes:true ~addon:(Some "someone-else") dataset
     = Decision.Ignore);
  check bool "Lanes still reads underneath the open Add-on" true
    (Decision.of_views ~lanes:true ~addon:(Some "quiz-1")
       Masc.Workspace_dataset_event.Lanes = Decision.Read_lanes)

let test_play_room_does_not_read_lane_surfaces () =
  List.iter (fun view ->
    check bool "Play room is handled by its own view, not Lane reads" true
      (Decision.of_dataset ~view
         (Masc.Workspace_dataset_event.Play_room { machine = Masc.Machine_lane.Dos })
       = Decision.Ignore))
    [Decision.Lanes; Decision.Overview; Decision.Addons None; Decision.Addons (Some "quiz-1")]

let () =
  run "Lane read decision"
    [ "scope",
      [ test_case "Lanes reads only while visible" `Quick test_lanes_read_only_when_visible
      ; test_case "Add-on reads only the open instance" `Quick test_addon_read_is_scoped_to_the_open_instance
      ; test_case "an open Add-on wins over Lanes" `Quick test_open_addon_wins_over_the_lanes_surface
      ; test_case "Play room does not read Lane surfaces" `Quick test_play_room_does_not_read_lane_surfaces
      ] ]
