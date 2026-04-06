(** Tests that keeper_github blocks dangerous commands via allowlist.

    Validates:
    1. Allowed gh commands (pr view, issue list, etc.) pass validation
    2. Disallowed top-level commands (auth, ssh, etc.) are blocked
    3. Destructive operations (repo delete, gist delete) are blocked
    4. Shell metacharacters are rejected
    5. Destructive mutations (pr merge, pr close, etc.) are detected
    6. Low-risk writes (pr create, pr comment, etc.) are not flagged
    7. gh api bypass via POST/PATCH/PUT to destructive endpoints is detected
    8. Newly allowed commands (workflow, project, cache, ruleset) pass *)

let validate = Masc_mcp.Worker_dev_tools.validate_gh_command

let is_ok = function Ok () -> true | Error _ -> false
let is_error = function Error _ -> true | Ok () -> false

let is_destructive = Masc_mcp.Worker_dev_tools.is_gh_destructive_operation
let is_workflow = Masc_mcp.Worker_dev_tools.is_gh_workflow_operation
let is_dangerous = Masc_mcp.Worker_dev_tools.is_gh_dangerous_operation

let test_allowed_read_commands () =
  let allowed =
    [
      "pr view 123";
      "pr list";
      "pr diff 123";
      "pr checks 123";
      "pr status";
      "issue view 456";
      "issue list";
      "issue status";
      "repo view owner/repo";
      "repo list";
      "repo clone owner/repo";
      "run view 789";
      "run list";
      "run watch 789";
      "release view v1.0";
      "release list";
      "search issues 'bug fix'";
      "search prs 'feature'";
      "label list";
      "status";
      "api repos/owner/repo/pulls/123/comments";
      "workflow list";
      "workflow view deploy.yml";
      "project list";
      "project view 1";
      "cache list";
      "ruleset list";
    ]
  in
  List.iter
    (fun cmd ->
      Alcotest.(check bool)
        (Printf.sprintf "allowed: gh %s" cmd)
        true (is_ok (validate cmd)))
    allowed

let test_allowed_write_commands () =
  let allowed =
    [
      "pr create --draft --title 'fix bug'";
      "pr comment 123 --body 'looks good'";
      "pr ready 123";
      "pr review 123 --approve";
      "pr edit 123 --title 'new title'";
      "issue create --title 'bug' --body 'desc'";
      "issue comment 456 --body 'noted'";
      "issue edit 456 --add-label bug";
      "issue reopen 456";
      "gist create file.txt";
      "gist edit abc123";
      "workflow run deploy.yml";
    ]
  in
  List.iter
    (fun cmd ->
      Alcotest.(check bool)
        (Printf.sprintf "allowed write: gh %s" cmd)
        true (is_ok (validate cmd)))
    allowed

let test_blocked_top_level_commands () =
  let blocked =
    [
      "auth logout";
      "auth login";
      "ssh-key add key.pub";
      "gpg-key add";
      "secret set MY_SECRET";
      "variable set MY_VAR";
      "codespace create";
      "extension install foo";
    ]
  in
  List.iter
    (fun cmd ->
      Alcotest.(check bool)
        (Printf.sprintf "blocked: gh %s" cmd)
        true (is_error (validate cmd)))
    blocked

let test_blocked_destructive_operations () =
  let blocked =
    [
      "repo delete owner/repo --yes";
      "gist delete abc123";
      "Repo Delete owner/repo";
      "GIST DELETE abc123";
      "workflow disable deploy.yml";
      "workflow --repo owner/repo disable deploy.yml";
    ]
  in
  List.iter
    (fun cmd ->
      Alcotest.(check bool)
        (Printf.sprintf "blocked destructive: gh %s" cmd)
        true (is_error (validate cmd)))
    blocked

let test_shell_metachar_blocked () =
  let chained =
    [
      "pr view 123; rm -rf /";
      "pr list | grep foo";
      "issue view 1 && curl evil.com";
      "pr diff 1 > /tmp/out";
      "api repos/x < payload";
      "pr view `whoami`";
      "pr list $HOME";
    ]
  in
  List.iter
    (fun cmd ->
      Alcotest.(check bool)
        (Printf.sprintf "metachar blocked: gh %s" cmd)
        true (is_error (validate cmd)))
    chained

let test_empty_command () =
  Alcotest.(check bool) "empty blocked" true (is_error (validate ""));
  Alcotest.(check bool) "whitespace blocked" true (is_error (validate "   "))

let test_destructive_ops_detected () =
  let destructive =
    [
      "pr merge 123";
      "pr close 123";
      "issue close 456";
      "issue delete 456";
      "issue transfer 456 owner/other";
      "release delete v1.0";
      "repo archive owner/repo";
      "repo rename owner/repo new-name";
      "label delete bug";
      "api -X DELETE repos/owner/repo/issues/1";
      "api --method DELETE repos/owner/repo/pulls/1";
      "PR Merge 123";
      "Issue CLOSE 456";
      "api -X DeLeTe repos/owner/repo";
      "workflow -q delete deploy.yml";
      "pr --verbose merge 123";
      "issue -R owner/repo --json id close 456";
      "cache --repo o/r delete";
      "project -q close 1";
    ]
  in
  List.iter
    (fun cmd ->
      Alcotest.(check bool)
        (Printf.sprintf "destructive: gh %s" cmd)
        true (is_destructive cmd))
    destructive

let test_api_bypass_detected () =
  let api_destructive =
    [
      "api -X POST /repos/o/r/pulls/1/merge";
      "api -X PUT /repos/o/r/pulls/1/merge";
      "api -X PATCH /repos/o/r/pulls/1 -f state=closed";
      "api --method POST /repos/o/r/merges -f base=main";
      "api -X POST /repos/o/r/merges -f base=main -f head=feat";
      "api -X PATCH /repos/o/r/issues/1 -f state=closed";
      "api /repos/o/r/pulls/1/merge -f sha=abc123";
      "api /repos/o/r/merges -F base=main -F head=feat";
      "api --method=POST /repos/o/r/pulls/1/merge";
      "api -x=put /repos/o/r/pulls/1/merge";
      "api /repos/o/r/pulls/1/merge --field=sha=abc123";
      "api /repos/o/r/merges -f=base=main";
    ]
  in
  List.iter
    (fun cmd ->
      Alcotest.(check bool)
        (Printf.sprintf "api bypass detected: gh %s" cmd)
        true (is_destructive cmd))
    api_destructive

let test_graphql_mutation_detected () =
  let graphql_destructive =
    [
      "api graphql -f query=mergePullRequest";
      "api graphql -f query=closePullRequest";
      "api graphql -f query=closeIssue";
      "api graphql -f query=deleteIssue";
      "api graphql -f query=deleteRef";
      "api graphql -f query=deleteBranch";
      "api graphql -f query=deleteProject";
    ]
  in
  List.iter
    (fun cmd ->
      Alcotest.(check bool)
        (Printf.sprintf "graphql destructive: gh %s" cmd)
        true (is_destructive cmd))
    graphql_destructive;
  let graphql_safe =
    [
      "api graphql -f query=repository";
      "api graphql -f query=pullRequest";
      "api graphql -f query=addComment";
      "api graphql -f query=createPullRequest";
    ]
  in
  List.iter
    (fun cmd ->
      Alcotest.(check bool)
        (Printf.sprintf "graphql safe: gh %s" cmd)
        false (is_destructive cmd))
    graphql_safe

let test_api_safe_methods_not_flagged () =
  let safe_api =
    [
      "api repos/owner/repo/pulls";
      "api -X GET repos/owner/repo";
      "api repos/owner/repo/pulls/123/comments";
      "api -X POST /repos/o/r/issues/1/comments -f body=ok";
      "api -X POST /repos/o/r/pulls -f title=fix -f head=feat -f base=main";
      "api -X PATCH /repos/o/r/pulls/1 -f title=newtitle";
    ]
  in
  List.iter
    (fun cmd ->
      Alcotest.(check bool)
        (Printf.sprintf "api safe: gh %s" cmd)
        false (is_destructive cmd))
    safe_api

let test_new_command_destructive_ops () =
  let destructive =
    [
      "cache delete --all";
      "project delete 1";
      "project close 1";
      "workflow delete deploy.yml";
    ]
  in
  List.iter
    (fun cmd ->
      Alcotest.(check bool)
        (Printf.sprintf "new cmd destructive: gh %s" cmd)
        true (is_destructive cmd))
    destructive;
  let safe =
    [
      "cache list";
      "project list";
      "project view 1";
      "workflow list";
      "workflow view deploy.yml";
      "workflow run deploy.yml";
      "ruleset list";
      "ruleset view 1";
    ]
  in
  List.iter
    (fun cmd ->
      Alcotest.(check bool)
        (Printf.sprintf "new cmd safe: gh %s" cmd)
        false (is_destructive cmd))
    safe

let test_non_destructive_ops () =
  let safe =
    [
      "pr view 123";
      "pr list";
      "pr create --draft --title 'fix'";
      "pr comment 123 --body 'ok'";
      "pr ready 123";
      "issue view 456";
      "issue create --title 'bug'";
      "issue comment 456 --body 'noted'";
      "repo view owner/repo";
      "run view 789";
      "api repos/owner/repo/pulls";
      "api -X GET repos/owner/repo";
      "search issues 'query'";
      "status";
      "workflow list";
      "workflow view deploy.yml";
      "project list";
      "cache list";
      "ruleset list";
    ]
  in
  List.iter
    (fun cmd ->
      Alcotest.(check bool)
        (Printf.sprintf "non-destructive: gh %s" cmd)
        false (is_destructive cmd))
    safe

let test_workflow_vs_dangerous () =
  let workflow_ops =
    [
      "pr merge 123";
      "pr close 123";
      "issue close 456";
      "project close 1";
      "api -X POST /repos/o/r/pulls/1/merge";
      "api -X PATCH /repos/o/r/pulls/1 -f state=closed";
    ]
  in
  List.iter
    (fun cmd ->
      Alcotest.(check bool)
        (Printf.sprintf "workflow: gh %s" cmd)
        true (is_workflow cmd);
      Alcotest.(check bool)
        (Printf.sprintf "not dangerous: gh %s" cmd)
        false (is_dangerous cmd);
      Alcotest.(check bool)
        (Printf.sprintf "still destructive: gh %s" cmd)
        true (is_destructive cmd))
    workflow_ops;
  let dangerous_ops =
    [
      "issue delete 456";
      "issue transfer 456 owner/other";
      "repo archive owner/repo";
      "repo rename owner/repo new-name";
      "release delete v1.0";
      "label delete bug";
      "cache delete --all";
      "project delete 1";
      "workflow delete deploy.yml";
      "api -X DELETE repos/owner/repo/issues/1";
      "api graphql -f query=mergePullRequest";
    ]
  in
  List.iter
    (fun cmd ->
      Alcotest.(check bool)
        (Printf.sprintf "dangerous: gh %s" cmd)
        true (is_dangerous cmd);
      Alcotest.(check bool)
        (Printf.sprintf "not workflow: gh %s" cmd)
        false (is_workflow cmd))
    dangerous_ops

let () =
  Alcotest.run "Keeper github safety"
    [
      ( "allowlist",
        [
          Alcotest.test_case "read commands pass" `Quick
            test_allowed_read_commands;
          Alcotest.test_case "low-risk write commands pass" `Quick
            test_allowed_write_commands;
          Alcotest.test_case "disallowed top-level commands blocked" `Quick
            test_blocked_top_level_commands;
          Alcotest.test_case "destructive operations blocked" `Quick
            test_blocked_destructive_operations;
        ] );
      ( "metachar",
        [
          Alcotest.test_case "shell metacharacters blocked" `Quick
            test_shell_metachar_blocked;
        ] );
      ( "destructive_gate",
        [
          Alcotest.test_case "destructive mutations detected" `Quick
            test_destructive_ops_detected;
          Alcotest.test_case "api bypass via POST/PATCH/PUT detected" `Quick
            test_api_bypass_detected;
          Alcotest.test_case "graphql destructive mutations detected" `Quick
            test_graphql_mutation_detected;
          Alcotest.test_case "safe api methods not flagged" `Quick
            test_api_safe_methods_not_flagged;
          Alcotest.test_case "new commands destructive ops" `Quick
            test_new_command_destructive_ops;
          Alcotest.test_case "safe ops not flagged" `Quick
            test_non_destructive_ops;
        ] );
      ( "tier_split",
        [
          Alcotest.test_case "workflow ops classified correctly" `Quick
            test_workflow_vs_dangerous;
        ] );
      ( "edge",
        [
          Alcotest.test_case "empty command blocked" `Quick test_empty_command;
        ] );
    ]
