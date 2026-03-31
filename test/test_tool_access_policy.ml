(** Tests for Tool_access_policy — shared allow/deny selector ADT. *)

open Alcotest
open Masc_mcp

let test_allows_name_with_explicit_deny () =
  let policy =
    Tool_access_policy.of_allowlist
      ~deny:[ "masc_board_post" ]
      [ "masc_status"; "masc_board_post" ]
  in
  check bool "status allowed" true
    (Tool_access_policy.allows_name policy "masc_status");
  check bool "board_post denied" false
    (Tool_access_policy.allows_name policy "masc_board_post")

let test_surface_resolution_respects_candidates () =
  let candidates =
    [ "masc_status"; "masc_add_task"; "masc_board_post"; "totally_unknown" ]
  in
  let policy =
    {
      Tool_access_policy.allow = Surface Tool_catalog.Local_worker;
      deny = Names [ "masc_add_task" ];
    }
  in
  let resolved = Tool_access_policy.resolve ~candidates policy in
  check bool "keeps status" true (List.mem "masc_status" resolved);
  check bool "drops denied tool" false (List.mem "masc_add_task" resolved);
  check bool "drops candidate outside surface" false
    (List.mem "totally_unknown" resolved)

let test_union_matches_any_member () =
  let selector =
    Tool_access_policy.union
      [ Names [ "masc_status" ]; Surface Tool_catalog.Admin ]
  in
  check bool "status in union" true
    (Tool_access_policy.selector_matches_name selector "masc_status");
  check bool "admin surface tool in union" true
    (Tool_access_policy.selector_matches_name selector "masc_tool_admin_update")

let () =
  run "Tool_access_policy"
    [
      ( "policy",
        [
          test_case "allows_name with explicit deny" `Quick
            test_allows_name_with_explicit_deny;
          test_case "surface resolution respects candidates" `Quick
            test_surface_resolution_respects_candidates;
          test_case "union matches any member" `Quick
            test_union_matches_any_member;
        ] );
    ]
