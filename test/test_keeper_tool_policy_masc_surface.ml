open Alcotest

let check_member label name expected names =
  check bool label expected (List.mem name names)

let test_board_registry_advertises_cleanup_tool () =
  let names = List.map (fun (schema : Masc_domain.tool_schema) -> schema.name) Board_tool_registry.tools in
  check_member "board cleanup advertised" "masc_board_cleanup" true names

let test_model_surface_exposes_direct_board_operations () =
  let names = Masc.Keeper_tool_policy.keeper_model_tool_names () in
  check_member "board cleanup is model-visible" "masc_board_cleanup" true names;
  check_member "board delete is model-visible" "masc_board_delete" true names

let test_model_surface_exposes_working_capability_families () =
  let names = Masc.Keeper_tool_policy.keeper_model_tool_names () in
  List.iter
    (fun name -> check_member (name ^ " is model-visible") name true names)
    [ "Execute"
    ; "Grep"
    ; "Read"
    ; "Edit"
    ; "Write"
    ; "WebSearch"
    ; "WebFetch"
    ; "analyze_image"
    ; "keeper_voice_speak"
    ; "keeper_voice_listen"
    ; "keeper_voice_agent"
    ; "keeper_voice_sessions"
    ; "keeper_voice_session_start"
    ; "keeper_voice_session_end"
    ; "masc_fusion"
    ]

let () =
  Alcotest.run "keeper_tool_policy_masc_surface"
    [
      ( "model surface",
        [
          test_case "advertises board cleanup tool" `Quick
            test_board_registry_advertises_cleanup_tool;
          test_case
            "exposes direct Board operations"
            `Quick
            test_model_surface_exposes_direct_board_operations;
          test_case
            "exposes code web media voice and Fusion"
            `Quick
            test_model_surface_exposes_working_capability_families;
        ] );
    ]
