(** Unit tests for [Keeper_tool_pr_review] error-shape helpers.

    Focused on the [pr_not_found] detection that turns an opaque
    [HTTP 404] string into a structured error keepers can act on
    without retry loops.  Background:
    [memory/feedback_tool-error-messages-teach-llm.md]. *)

open Alcotest

module KTPR = Masc_mcp.Keeper_tool_pr_review

let test_research_preset_can_mutate_pr_reviews () =
  check bool "research can comment/approve through review tool" true
    (KTPR.pr_review_mutation_preset_ok
       (Some Masc_mcp.Keeper_types.Research))

let test_social_preset_cannot_mutate_pr_reviews () =
  check bool "social cannot mutate PR reviews" false
    (KTPR.pr_review_mutation_preset_ok
       (Some Masc_mcp.Keeper_types.Social))

let test_detects_rest_404 () =
  let sample =
    "failed to run git: HTTP 404: Not Found \
     (https://api.github.com/repos/jeong-sik/masc-mcp/pulls/8116)" in
  check bool "REST 404 detected" true
    (KTPR.pr_not_found_in_output sample)

let test_detects_graphql_could_not_resolve () =
  let sample =
    "GraphQL: Could not resolve to a PullRequest with the number of 9999." in
  check bool "GraphQL resolution failure detected" true
    (KTPR.pr_not_found_in_output sample)

let test_detects_no_pull_requests_found () =
  check bool "gh pr list empty wording detected" true
    (KTPR.pr_not_found_in_output "no pull requests found in this repo")

let test_passes_through_unrelated_errors () =
  check bool "rate limit not flagged" false
    (KTPR.pr_not_found_in_output
       "API rate limit exceeded for user (60 / 5000)");
  check bool "auth error not flagged" false
    (KTPR.pr_not_found_in_output
       "HTTP 401: Unauthorized");
  check bool "empty output not flagged" false
    (KTPR.pr_not_found_in_output "")

let () =
  Alcotest.run "Keeper PR review error UX" [
    "preset_gate", [
      test_case "research preset can mutate PR reviews" `Quick
        test_research_preset_can_mutate_pr_reviews;
      test_case "social preset cannot mutate PR reviews" `Quick
        test_social_preset_cannot_mutate_pr_reviews;
    ];
    "pr_not_found_in_output", [
      test_case "REST 404 (HTTP 404: Not Found)" `Quick test_detects_rest_404;
      test_case "GraphQL Could not resolve" `Quick
        test_detects_graphql_could_not_resolve;
      test_case "no pull requests found wording" `Quick
        test_detects_no_pull_requests_found;
      test_case "unrelated errors are not false positives" `Quick
        test_passes_through_unrelated_errors;
    ]
  ]
