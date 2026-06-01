open Alcotest

module CTS = Workspace_task_schedule

let test_none_rejects_non_empty_required_tools () =
  let pred = CTS.make_required_tools_predicate () in
  check bool "empty required_tools passes" true (pred []);
  check bool "single required tool rejected" false (pred [ "tool_execute" ]);
  check bool "multiple required tools rejected" false
    (pred [ "tool_execute"; "Write" ])
;;

let test_none_accepts_empty_required_tools () =
  let pred = CTS.make_required_tools_predicate () in
  check bool "empty list passes" true (pred []);
  check bool "empty contract passes" true (pred [])
;;

let test_some_accepts_matching_tools () =
  let pred =
    CTS.make_required_tools_predicate
      ~agent_tool_names:[ "tool_execute"; "Write"; "Read" ]
      ()
  in
  check bool "matching tool passes" true (pred [ "tool_execute" ]);
  check bool "multiple matching tools pass" true
    (pred [ "tool_execute"; "Write" ]);
  check bool "empty required passes" true (pred [])
;;

let test_some_rejects_missing_tools () =
  let pred =
    CTS.make_required_tools_predicate
      ~agent_tool_names:[ "Write"; "Read" ]
      ()
  in
  check bool "missing tool rejected" false (pred [ "tool_execute" ]);
  check bool "partial match rejected" false (pred [ "Write"; "tool_execute" ])
;;

let test_some_accepts_when_all_present () =
  let pred =
    CTS.make_required_tools_predicate
      ~agent_tool_names:[ "tool_execute"; "Write"; "Read"; "Grep" ]
      ()
  in
  check bool "all present passes" true
    (pred [ "tool_execute"; "Write"; "Read" ])
;;

let () =
  run
    "make_required_tools_predicate"
    [
      ( "none_branch"
      , [
          test_case
            "rejects tasks with non-empty required_tools"
            `Quick
            test_none_rejects_non_empty_required_tools
        ; test_case
            "accepts tasks with empty required_tools"
            `Quick
            test_none_accepts_empty_required_tools
        ] )
    ; ( "some_branch"
      , [
          test_case
            "accepts tasks whose required_tools are in the allowed set"
            `Quick
            test_some_accepts_matching_tools
        ; test_case
            "rejects tasks with tools not in the allowed set"
            `Quick
            test_some_rejects_missing_tools
        ; test_case
            "accepts when all required tools are present"
            `Quick
            test_some_accepts_when_all_present
        ] )
    ]
;;
