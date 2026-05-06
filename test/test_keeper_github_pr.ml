open Alcotest

module K = Masc_mcp.Keeper_tool_github_pr

let test_pr_list_argv_uses_repo_state_limit_json () =
  check (list string) "argv"
    [
      "gh";
      "pr";
      "list";
      "-R";
      "owner/repo";
      "--state";
      "open";
      "--limit";
      "20";
      "--json";
      "number,title,state,isDraft,headRefName,baseRefName,mergeable,reviewDecision,url,updatedAt";
    ]
    (K.For_testing.build_pr_list_argv ~repo:"owner/repo" ~state:"open" ~limit:20)

let test_pr_status_argv_accepts_number () =
  let argv =
    K.For_testing.build_pr_status_argv ~repo:"owner/repo" ~pr_number:42
  in
  check bool "uses gh pr view" true
    (List.exists (String.equal "view") argv);
  check bool "contains number" true
    (List.exists (String.equal "42") argv);
  check bool "contains json fields" true
    (List.exists
       (fun s -> String.starts_with ~prefix:"number,title,state" s)
       argv)

let test_pr_create_argv_is_draft_only () =
  check (list string) "argv"
    [
      "gh";
      "pr";
      "create";
      "-R";
      "owner/repo";
      "--draft";
      "--title";
      "Title";
      "--body";
      "Body";
      "--base";
      "main";
      "--head";
      "feature";
    ]
    (K.For_testing.build_pr_create_argv ~repo:"owner/repo" ~title:"Title"
       ~body:"Body" ~base:(Some "main") ~head:(Some "feature"))

let test_draft_request_rejects_ready_prs () =
  check bool "omitted draft accepted" true
    (K.For_testing.draft_request_allowed (`Assoc []));
  check bool "draft true accepted" true
    (K.For_testing.draft_request_allowed
       (`Assoc [ ("draft", `Bool true) ]));
  check bool "draft false rejected" false
    (K.For_testing.draft_request_allowed
       (`Assoc [ ("draft", `Bool false) ]));
  check bool "ready true rejected" false
    (K.For_testing.draft_request_allowed
       (`Assoc [ ("ready", `Bool true) ]))

let () =
  run "keeper_github_pr"
    [
      ( "argv",
        [
          test_case "pr list argv" `Quick
            test_pr_list_argv_uses_repo_state_limit_json;
          test_case "pr status argv" `Quick
            test_pr_status_argv_accepts_number;
          test_case "pr create argv is draft" `Quick
            test_pr_create_argv_is_draft_only;
          test_case "draft request guard" `Quick
            test_draft_request_rejects_ready_prs;
        ] );
    ]
