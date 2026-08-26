open Alcotest

module Runtime_info_json = Server_dashboard_http_runtime_info_json

let test_matching_full_and_short_sha () =
  let full = "667e2f99cf1d592a63b35a678759ed55c0d3df0f" in
  check bool "short then full" true (Runtime_info_json.commit_equal "667e2f99cf" full);
  check bool "full then short" true (Runtime_info_json.commit_equal full "667e2f99cf")
;;

let test_distinct_sha () =
  check bool
    "distinct prefix"
    false
    (Runtime_info_json.commit_equal
       "667e2f99cf"
       "667e2f99df1d592a63b35a678759ed55c0d3df0f")
;;

let test_prefix_matching_is_limited_to_git_hex () =
  check bool "short hex is not an abbreviation" false (Runtime_info_json.commit_equal "667e2f" "667e2f99");
  check bool
    "two abbreviated values are not proof"
    false
    (Runtime_info_json.commit_equal "667e2f9" "667e2f99cf");
  check bool "non-hex is not an abbreviation" false (Runtime_info_json.commit_equal "runtime" "runtime-head");
  check bool "identical opaque value remains equal" true (Runtime_info_json.commit_equal "unknown" "unknown")
;;

let test_option_comparison () =
  check
    (option bool)
    "matching optional SHAs"
    (Some true)
    (Runtime_info_json.opt_commit_equal
       (Some "667e2f99cf1d592a63b35a678759ed55c0d3df0f")
       (Some "667e2f99cf"));
  check
    (option bool)
    "missing SHA stays unknown"
    None
    (Runtime_info_json.opt_commit_equal None (Some "667e2f99cf"))
;;

let () =
  run
    "runtime_commit_equal"
    [ ( "commit identity"
      , [ test_case "matching full and short SHA" `Quick test_matching_full_and_short_sha
        ; test_case "distinct SHA" `Quick test_distinct_sha
        ; test_case
            "prefix matching is limited to Git hex"
            `Quick
            test_prefix_matching_is_limited_to_git_hex
        ; test_case "optional comparison" `Quick test_option_comparison
        ] )
    ]
;;
