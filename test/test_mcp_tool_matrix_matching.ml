module Cases = Test_mcp_tool_matrix_cases

let test_mixed_case_fatal_and_guard_fragments () =
  Cases.For_testing.regression_case_insensitive_matching ()

let test_direct_case_insensitive_contains_any () =
  Alcotest.(check bool)
    "mixed-case response matches lowercase fragment"
    true
    (Cases.For_testing.contains_any "Already Joined" [ "already joined" ])

let () =
  Alcotest.run
    "mcp tool matrix matching"
    [
      ( "contains_any"
      , [
          Alcotest.test_case
            "fatal and guard fragments are case-insensitive"
            `Quick
            test_mixed_case_fatal_and_guard_fragments
        ; Alcotest.test_case
            "direct mixed-case guard match"
            `Quick
            test_direct_case_insensitive_contains_any
        ] )
    ]
