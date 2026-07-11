open Alcotest

let names_from_board_registry () =
  Masc.Keeper_tool_policy.keeper_supported_masc_tool_names_from_schemas
    Board_tool_registry.tools

let check_member label name expected names =
  check bool label expected (List.mem name names)

let test_board_registry_advertises_cleanup_tool () =
  let names = List.map (fun (schema : Masc_domain.tool_schema) -> schema.name) Board_tool_registry.tools in
  check_member "board cleanup advertised" "masc_board_cleanup" true names

let test_board_keeper_projection_is_exhaustive () =
  let names = names_from_board_registry () in
  List.iter
    (fun board_name ->
      let raw_name = Tool_name.Board_name.to_string board_name in
      match Keeper_tool_name.board_projection_of_masc_board_name board_name with
      | Keeper_tool_name.Direct_masc ->
        check_member (raw_name ^ " direct Keeper route") raw_name true names
      | Keeper_tool_name.Keeper_wrapper _ | Keeper_tool_name.External_only ->
        check_member (raw_name ^ " raw route excluded") raw_name false names)
    Tool_name.Board_name.all

let () =
  Alcotest.run "keeper_tool_policy_masc_surface"
    [
      ( "board wrapper filter",
        [
          test_case "advertises board cleanup tool" `Quick
            test_board_registry_advertises_cleanup_tool;
          test_case
            "projects every Board operation by typed policy"
            `Quick
            test_board_keeper_projection_is_exhaustive;
        ] );
    ]
