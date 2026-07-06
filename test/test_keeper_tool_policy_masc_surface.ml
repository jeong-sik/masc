open Alcotest

let names_from_board_registry () =
  Masc.Keeper_tool_policy.keeper_supported_masc_tool_names_from_schemas
    Board_tool_registry.tools

let check_member label name expected names =
  check bool label expected (List.mem name names)

let test_board_registry_advertises_cleanup_tool () =
  let names = List.map (fun (schema : Masc_domain.tool_schema) -> schema.name) Board_tool_registry.tools in
  check_member "board cleanup advertised" "masc_board_cleanup" true names

let test_raw_board_wrappers_filtered_without_hiding_read_tools () =
  let names = names_from_board_registry () in
  check_member "raw board post filtered" "masc_board_post" false names;
  check_member "raw board comment filtered" "masc_board_comment" false names;
  check_member "raw board vote filtered" "masc_board_vote" false names;
  check_member
    "raw board curation submit filtered"
    "masc_board_curation_submit"
    false
    names;
  check_member "raw board cleanup filtered" "masc_board_cleanup" false names;
  check_member "raw board delete filtered" "masc_board_delete" false names;
  check_member "board list remains visible" "masc_board_list" true names;
  check_member "board post get remains visible" "masc_board_post_get" true names;
  check_member "board stats remains visible" "masc_board_stats" true names

let () =
  Alcotest.run "keeper_tool_policy_masc_surface"
    [
      ( "board wrapper filter",
        [
          test_case "advertises board cleanup tool" `Quick
            test_board_registry_advertises_cleanup_tool;
          test_case
            "filters raw board write tools with keeper wrappers"
            `Quick
            test_raw_board_wrappers_filtered_without_hiding_read_tools;
        ] );
    ]
