open Alcotest
module R = Masc.Keeper_sandbox_remote_checkouts
module C = Masc.Keeper_playground_checkouts

let test_parse_probe_json_complete () =
  let json =
    {|{
      "checkouts": [
        {
          "relative_path": "repos/masc",
          "name": "masc",
          "git_link": "directory",
          "origin": "https://github.com/jeong-sik/masc.git",
          "branch": "main",
          "head": "abcdef123456",
          "dirty": false,
          "changed_files": 0,
          "target_ref": "origin/main",
          "upstream_head": "abcdef123456",
          "ahead": 0,
          "behind": 0
        },
        {
          "relative_path": "repos/wt-fix",
          "name": "wt-fix",
          "git_link": "pointer_file",
          "origin": "https://github.com/jeong-sik/masc.git",
          "branch": "fix/remote",
          "head": "123456abcdef",
          "dirty": true,
          "changed_files": 3,
          "target_ref": "origin/main",
          "upstream_head": "abcdef123456",
          "ahead": 2,
          "behind": 1
        }
      ],
      "scanned": 150,
      "limit": null
    }|}
  in
  match R.parse_probe_json ~root:"/endpoint/root" json with
  | Error err -> failf "parse failed: %s" err
  | Ok (discovery_res, inspections) ->
    (match discovery_res with
     | Error err -> failf "discovery error: %s" (C.scan_error_to_string err)
     | Ok (C.Complete checkouts) ->
       check int "checkout count" 2 (List.length checkouts);
       check int "inspection count" 2 (List.length inspections);
       let c1 = List.nth inspections 0 in
       check string "c1 rel path" "repos/masc" c1.checkout.relative_path;
       check string "c1 abs path" "/endpoint/root/repos/masc" c1.checkout.absolute_path;
       check string "c1 name" "masc" c1.checkout.name;
       (match c1.checkout.git_link with
        | C.Git_directory -> ()
        | C.Git_pointer_file -> fail "expected Git_directory");
       check (option string) "c1 origin" (Some "https://github.com/jeong-sik/masc.git") c1.origin_url;
       check (result string string) "c1 branch" (Ok "main") c1.branch;
       check (result string string) "c1 head" (Ok "abcdef123456") c1.head;
       check (result (pair bool int) string) "c1 dirty" (Ok (false, 0)) c1.dirty;
       check (option string) "c1 target_ref" (Some "origin/main") c1.target_ref;
       check (option string) "c1 upstream_head" (Some "abcdef123456") c1.upstream_head;
       check (option int) "c1 ahead" (Some 0) c1.ahead;
       check (option int) "c1 behind" (Some 0) c1.behind;

       let c2 = List.nth inspections 1 in
       check string "c2 rel path" "repos/wt-fix" c2.checkout.relative_path;
       (match c2.checkout.git_link with
        | C.Git_pointer_file -> ()
        | C.Git_directory -> fail "expected Git_pointer_file");
       check (result (pair bool int) string) "c2 dirty" (Ok (true, 3)) c2.dirty;
       check (option int) "c2 ahead" (Some 2) c2.ahead;
       check (option int) "c2 behind" (Some 1) c2.behind
     | Ok (C.Partial _) -> fail "expected complete discovery")
;;

let test_parse_probe_json_limit_checkout_budget () =
  let json =
    {|{
      "checkouts": [
        {
          "relative_path": "c1",
          "name": "c1",
          "git_link": "directory",
          "origin": null,
          "branch": null,
          "head": null,
          "dirty": null,
          "changed_files": null,
          "target_ref": null,
          "upstream_head": null,
          "ahead": null,
          "behind": null
        }
      ],
      "scanned": 50,
      "limit": {"kind": "checkout_budget_exhausted", "budget": 12}
    }|}
  in
  match R.parse_probe_json ~root:"/root" json with
  | Error err -> failf "parse failed: %s" err
  | Ok (Ok (C.Partial { found; limit }), inspections) ->
    check int "found count" 1 (List.length found);
    check int "inspections count" 1 (List.length inspections);
    (match limit with
     | C.Checkout_budget_exhausted { budget } -> check int "budget" 12 budget
     | _ -> fail "expected Checkout_budget_exhausted")
  | _ -> fail "expected partial discovery"
;;

let test_parse_probe_json_limit_entry_budget () =
  let json =
    {|{
      "checkouts": [],
      "scanned": 8192,
      "limit": {"kind": "entry_budget_exhausted", "scanned": 8192, "budget": 8192}
    }|}
  in
  match R.parse_probe_json ~root:"/root" json with
  | Error err -> failf "parse failed: %s" err
  | Ok (Ok (C.Partial { found; limit }), inspections) ->
    check int "found count" 0 (List.length found);
    check int "inspections count" 0 (List.length inspections);
    (match limit with
     | C.Entry_budget_exhausted { scanned; budget } ->
       check int "scanned" 8192 scanned;
       check int "budget" 8192 budget
     | _ -> fail "expected Entry_budget_exhausted")
  | _ -> fail "expected partial discovery"
;;

let test_parse_probe_json_invalid () =
  match R.parse_probe_json ~root:"/root" "{not valid json" with
  | Error _ -> ()
  | Ok _ -> fail "expected json parse error"
;;

(* A row the probe did not print as promised is an error naming the field,
   not an exception and not a default. *)
let expect_error what expected raw =
  match R.parse_probe_json ~root:"/root" raw with
  | Error detail -> check string what expected detail
  | Ok _ -> failf "%s: decoded" what
;;

let row_with fields =
  Printf.sprintf
    {|{"checkouts": [{"relative_path": "c1", "name": "c1", %s
       "origin": null, "branch": null, "head": null, "dirty": null,
       "changed_files": null, "target_ref": null, "upstream_head": null,
       "ahead": null, "behind": null}], "scanned": 1, "limit": null}|}
    fields
;;

let test_an_unknown_git_link_is_an_error () =
  expect_error
    "git_link"
    {|checkouts[0]: git_link: unknown value "symlink"|}
    (row_with {|"git_link": "symlink",|})
;;

let test_a_missing_field_is_an_error_not_an_exception () =
  expect_error
    "git_link absent"
    "checkouts[0]: git_link: expected a string, got null"
    (row_with "");
  expect_error
    "relative_path wrong shape"
    "checkouts[0]: relative_path: expected a string, got an integer"
    {|{"checkouts": [{"relative_path": 3}], "scanned": 1, "limit": null}|}
;;

let test_half_a_status_is_an_error () =
  expect_error
    "dirty without changed_files"
    "checkouts[0]: dirty and changed_files come from one status read; only one is present"
    {|{"checkouts": [{"relative_path": "c1", "name": "c1", "git_link": "directory",
       "origin": null, "branch": null, "head": null, "dirty": true,
       "changed_files": null, "target_ref": null, "upstream_head": null,
       "ahead": null, "behind": null}], "scanned": 1, "limit": null}|}
;;

let test_an_unknown_limit_is_an_error () =
  expect_error
    "unknown kind"
    {|limit: unknown kind "time_budget_exhausted"|}
    {|{"checkouts": [], "scanned": 1, "limit": {"kind": "time_budget_exhausted"}}|};
  expect_error
    "budget absent"
    "budget: expected an integer, got null"
    {|{"checkouts": [], "scanned": 1, "limit": {"kind": "checkout_budget_exhausted"}}|}
;;

let test_the_wrong_top_level_shapes_are_errors () =
  expect_error "not an object" "probe output: expected an object, got a list" "[]";
  expect_error
    "checkouts not a list"
    "checkouts: expected a list, got an object"
    {|{"checkouts": {}, "scanned": 1, "limit": null}|}
;;

let () =
  run
    "Keeper_sandbox_remote_checkouts"
    [ ( "parse_probe_json"
      , [ test_case "complete discovery" `Quick test_parse_probe_json_complete
        ; test_case "checkout budget limit" `Quick test_parse_probe_json_limit_checkout_budget
        ; test_case "entry budget limit" `Quick test_parse_probe_json_limit_entry_budget
        ; test_case "invalid json" `Quick test_parse_probe_json_invalid
        ] )
    ; ( "a row that does not decode is an error"
      , [ test_case "unknown git_link" `Quick test_an_unknown_git_link_is_an_error
        ; test_case
            "missing or wrongly shaped field"
            `Quick
            test_a_missing_field_is_an_error_not_an_exception
        ; test_case "half a status" `Quick test_half_a_status_is_an_error
        ; test_case "unknown limit" `Quick test_an_unknown_limit_is_an_error
        ; test_case "wrong top-level shapes" `Quick test_the_wrong_top_level_shapes_are_errors
        ] )
    ]
;;
