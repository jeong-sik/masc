(** Failing recovery floor includes essential MASC tools.

    Resolves board P1 (research, 2026-05-07): "9 keepers × 0 claimable
    masc_web_search". Root cause was [Keeper_tool_policy.failing_minimum_tool_names]
    returning only the [removable=false] shard floor (base shard's 9 local tools),
    so any task contract requiring [masc_web_search] became unclaimable when
    a keeper entered decision_layer >= 2.

    Properties pinned:
    1. Shard floor preserved (5 base read-only tools present).
    2. Essential MASC subset present (masc_status / web_search / web_fetch /
       approval_pending) — mirrors [masc.essential] in tool_policy.toml.
    3. No duplicates (sort_uniq).
    4. Non-empty (TLA+ ToolSetNeverEmpty). *)

let test_includes_shard_floor () =
  let names = Masc_mcp.Keeper_tool_policy.failing_minimum_tool_names () in
  let assert_includes tool =
    Alcotest.(check bool)
      (Printf.sprintf "%s in shard floor" tool) true (List.mem tool names)
  in
  assert_includes "keeper_stay_silent";
  assert_includes "keeper_time_now";
  assert_includes "keeper_context_status";
  assert_includes "keeper_memory_search";
  assert_includes "keeper_tools_list"

let test_includes_essential_masc () =
  let names = Masc_mcp.Keeper_tool_policy.failing_minimum_tool_names () in
  let assert_includes tool =
    Alcotest.(check bool)
      (Printf.sprintf "%s in essential masc" tool) true (List.mem tool names)
  in
  assert_includes "masc_status";
  assert_includes "masc_web_search";
  assert_includes "masc_web_fetch";
  assert_includes "masc_approval_pending"

let test_no_duplicates () =
  let names = Masc_mcp.Keeper_tool_policy.failing_minimum_tool_names () in
  let sorted = List.sort_uniq String.compare names in
  Alcotest.(check int) "no duplicates after union"
    (List.length sorted) (List.length names)

let test_nonempty () =
  let names = Masc_mcp.Keeper_tool_policy.failing_minimum_tool_names () in
  Alcotest.(check bool) "non-empty (TLA+ ToolSetNeverEmpty)"
    true (names <> [])

let test_essential_masc_ssot_matches_toml () =
  (* Mirrors [masc.essential] in config/tool_policy.toml. If toml drifts,
     update [Keeper_tool_policy.essential_masc_minimum_names] to match. *)
  let expected = [
    "masc_status";
    "masc_web_search";
    "masc_web_fetch";
    "masc_approval_pending";
  ] in
  Alcotest.(check (list string))
    "essential_masc_minimum_names mirrors [masc.essential] toml group"
    expected
    Masc_mcp.Keeper_tool_policy.essential_masc_minimum_names

let () =
  Alcotest.run "failing_minimum_essential" [
    "shard_floor", [
      Alcotest.test_case "shard floor preserved" `Quick test_includes_shard_floor;
    ];
    "essential_masc", [
      Alcotest.test_case "essential MASC included" `Quick test_includes_essential_masc;
    ];
    "ssot", [
      Alcotest.test_case "essential masc list matches toml" `Quick
        test_essential_masc_ssot_matches_toml;
    ];
    "invariants", [
      Alcotest.test_case "no duplicates" `Quick test_no_duplicates;
      Alcotest.test_case "non-empty (TLA+)" `Quick test_nonempty;
    ];
  ]
