(** D14: gh `|| echo` (and other piped/redirected gh-pr) typed-redirect arm.

    Validates that:
    1. [gh pr view 123 --json title || echo "{}"] is rewritten to
       [keeper_pr_status] (gh pr view → Gh_pr_status), reason=
       [gh_pipe_typed_redirect].
    2. [gh pr list --json number || echo "[]"] is rewritten to
       [keeper_pr_list].
    3. [gh pr checks 123 || echo "{}"] still hits the existing
       [Gh_pr_checks] arm (reason=[native_pr_status_tool_required]) —
       no double-classification.
    4. A non-gh pipeline (e.g. [echo hello | grep test || echo none]) still
       falls through to the plain [Pipe_or_redirect] catch-all
       (reason=[pipe_or_redirect_blocked]). *)

module Shape = Masc_mcp.Keeper_shell_bash_shape_messages
module Classifier = Masc_mcp.Keeper_shell_bash_shape_classifier

let classify cmd = Classifier.shell_ir_parse_failure_shape_block cmd

let plan_exn cmd block =
  match Shape.bash_shape_block_recovery_plan ~cmd block with
  | Some plan -> plan
  | None -> Alcotest.fail ("expected recovery plan for " ^ cmd)

let next_arg_string plan key =
  match List.assoc_opt key plan.Shape.next_args with
  | Some (`String value) -> value
  | Some other ->
    Alcotest.fail
      (Printf.sprintf
         "next_args.%s expected string, got %s"
         key
         (Yojson.Safe.to_string other))
  | None -> Alcotest.fail ("missing next_args." ^ key)

let test_gh_pr_view_pipe_echo_routes_to_pr_status () =
  let cmd = {|gh pr view 123 --json title || echo "{}"|} in
  (match classify cmd with
   | Some Shape.Pipe_or_redirect -> ()
   | Some other ->
     Alcotest.fail
       ("expected Pipe_or_redirect classification, got "
       ^ Shape.bash_shape_block_tag other)
   | None -> Alcotest.fail "expected Pipe_or_redirect classification");
  let plan = plan_exn cmd Shape.Pipe_or_redirect in
  Alcotest.(check string) "next_tool" "keeper_pr_status" plan.Shape.next_tool;
  Alcotest.(check string) "reason" "gh_pipe_typed_redirect" plan.Shape.reason;
  Alcotest.(check string) "confidence" "high" plan.Shape.confidence;
  Alcotest.(check string)
    "pr arg placeholder"
    "NUMBER_FROM_COMMAND"
    (next_arg_string plan "pr");
  Alcotest.(check string)
    "repo arg placeholder"
    "OWNER/REPO_FROM_COMMAND"
    (next_arg_string plan "repo")

let test_gh_pr_list_pipe_echo_routes_to_pr_list () =
  let cmd = {|gh pr list --json number || echo "[]"|} in
  let plan = plan_exn cmd Shape.Pipe_or_redirect in
  Alcotest.(check string) "next_tool" "keeper_pr_list" plan.Shape.next_tool;
  Alcotest.(check string) "reason" "gh_pipe_typed_redirect" plan.Shape.reason;
  Alcotest.(check string) "confidence" "high" plan.Shape.confidence

let test_gh_pr_checks_still_wins_gh_pr_checks_arm () =
  (* The classifier should still return Gh_pr_checks (substring match fires
     before the [|] check), so the existing native_pr_status_tool_required
     recovery plan applies — no double-classification into the new arm. *)
  let cmd = {|gh pr checks 123 || echo "{}"|} in
  (match classify cmd with
   | Some Shape.Gh_pr_checks -> ()
   | Some other ->
     Alcotest.fail
       ("expected Gh_pr_checks classification, got "
       ^ Shape.bash_shape_block_tag other)
   | None -> Alcotest.fail "expected Gh_pr_checks classification");
  let plan = plan_exn cmd Shape.Gh_pr_checks in
  Alcotest.(check string) "next_tool" "keeper_pr_status" plan.Shape.next_tool;
  Alcotest.(check string)
    "reason"
    "native_pr_status_tool_required"
    plan.Shape.reason

let test_non_gh_pipeline_falls_through_to_plain_pipe_or_redirect () =
  let cmd = {|echo "hello" | grep test || echo none|} in
  let plan = plan_exn cmd Shape.Pipe_or_redirect in
  Alcotest.(check string) "next_tool" "Bash" plan.Shape.next_tool;
  Alcotest.(check string)
    "reason"
    "pipe_or_redirect_blocked"
    plan.Shape.reason

let () =
  Alcotest.run
    "d14_gh_pipe_typed_redirect"
    [ ( "gh_pipe_typed_redirect"
      , [ Alcotest.test_case
            "gh pr view || echo routes to keeper_pr_status"
            `Quick
            test_gh_pr_view_pipe_echo_routes_to_pr_status
        ; Alcotest.test_case
            "gh pr list || echo routes to keeper_pr_list"
            `Quick
            test_gh_pr_list_pipe_echo_routes_to_pr_list
        ; Alcotest.test_case
            "gh pr checks || echo still hits Gh_pr_checks arm"
            `Quick
            test_gh_pr_checks_still_wins_gh_pr_checks_arm
        ; Alcotest.test_case
            "non-gh pipe falls through to plain Pipe_or_redirect"
            `Quick
            test_non_gh_pipeline_falls_through_to_plain_pipe_or_redirect
        ] )
    ]
