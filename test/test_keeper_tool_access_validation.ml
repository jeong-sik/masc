(* RFC-0273 §3.1 — set_policy tool_access validation (delta-only known-name
   check). Pure-function coverage of Server_dashboard_http_keeper_api_post
   .unknown_added_tool_names: newly-added names must be known candidates; names
   already on the keeper are grandfathered; removals are always allowed. *)

module P = Server_dashboard_http_keeper_api_post

let check_names msg expected actual = Alcotest.(check (list string)) msg expected actual

let candidates = [ "masc_status"; "WebSearch"; "WebFetch"; "masc_board_post" ]

let test_all_known_accepted () =
  check_names "all known -> nothing rejected" []
    (P.unknown_added_tool_names ~candidate_names:candidates ~existing:[]
       ~requested:[ "masc_status"; "WebSearch" ])

let test_unknown_rejected () =
  check_names "newly-added unknown -> rejected" [ "masc_bogus" ]
    (P.unknown_added_tool_names ~candidate_names:candidates ~existing:[]
       ~requested:[ "masc_status"; "masc_bogus" ])

let test_legacy_grandfathered () =
  (* A stale/renamed name already persisted on the keeper is NOT re-validated,
     so a legacy keeper stays editable. *)
  check_names "pre-existing unknown grandfathered" []
    (P.unknown_added_tool_names ~candidate_names:candidates
       ~existing:[ "masc_renamed_old" ]
       ~requested:[ "masc_renamed_old"; "masc_status" ])

let test_new_unknown_amid_legacy () =
  check_names "only the newly-added unknown is reported" [ "masc_typo" ]
    (P.unknown_added_tool_names ~candidate_names:candidates
       ~existing:[ "masc_renamed_old" ]
       ~requested:[ "masc_renamed_old"; "masc_status"; "masc_typo" ])

let test_removal_allowed () =
  check_names "removing a name -> nothing rejected" []
    (P.unknown_added_tool_names ~candidate_names:candidates
       ~existing:[ "masc_status"; "WebSearch" ] ~requested:[ "masc_status" ])

let test_multiple_unknown_reported_in_order () =
  check_names "all newly-added unknowns reported in request order"
    [ "z_bad"; "a_bad" ]
    (P.unknown_added_tool_names ~candidate_names:candidates ~existing:[]
       ~requested:[ "masc_status"; "z_bad"; "WebFetch"; "a_bad" ])

let () =
  Alcotest.run "keeper_tool_access_validation"
    [ ( "delta",
        [ Alcotest.test_case "all known accepted" `Quick test_all_known_accepted;
          Alcotest.test_case "unknown rejected" `Quick test_unknown_rejected;
          Alcotest.test_case "legacy grandfathered" `Quick test_legacy_grandfathered;
          Alcotest.test_case "new unknown amid legacy" `Quick test_new_unknown_amid_legacy;
          Alcotest.test_case "removal allowed" `Quick test_removal_allowed;
          Alcotest.test_case "multiple unknown in order" `Quick
            test_multiple_unknown_reported_in_order ] ) ]
