(** Tests for the keeper_github hallucination gate.

    Covers:
    1. [extract_gh_target_number]: pure parser correctness for the
       commands that should/shouldn't trigger pre-validation.
    2. [gh_mutates_entity]: pure classifier covering the cache
       invalidation triggers.
    3. [Keeper_gh_shared.validate_number]: fast-path returns ([`Unknown]
       on empty repo_slug, zero number) that don't require subprocess. *)

open Alcotest

module Room = Masc_mcp.Room

let extract = Masc_mcp.Keeper_gh_shared.extract_gh_target_number
let mutates = Masc_mcp.Keeper_gh_shared.gh_mutates_entity

(* The entity_kind variants need a testable for Alcotest option checks.
   Pretty-print and equality are trivial. *)
let entity_kind_testable =
  let pp fmt = function
    | Masc_mcp.Keeper_gh_shared.PR -> Format.fprintf fmt "PR"
    | Masc_mcp.Keeper_gh_shared.Issue -> Format.fprintf fmt "Issue"
  in
  testable pp ( = )

let target_testable = option (pair entity_kind_testable int)

(* ====================================================================== *)
(* extract_gh_target_number                                                  *)
(* ====================================================================== *)

let test_extract_pr_view_number () =
  check target_testable "pr view 123"
    (Some (Masc_mcp.Keeper_gh_shared.PR, 123))
    (extract "pr view 123")

let test_extract_pr_view_with_flags () =
  check target_testable "pr view 456 --json title,body"
    (Some (Masc_mcp.Keeper_gh_shared.PR, 456))
    (extract "pr view 456 --json title,body")

let test_extract_pr_merge_number () =
  check target_testable "pr merge 789 --squash"
    (Some (Masc_mcp.Keeper_gh_shared.PR, 789))
    (extract "pr merge 789 --squash")

let test_extract_pr_comment_number () =
  check target_testable "pr comment 42 --body 'hi'"
    (Some (Masc_mcp.Keeper_gh_shared.PR, 42))
    (extract "pr comment 42 --body hi")

let test_extract_issue_view_number () =
  check target_testable "issue view 100"
    (Some (Masc_mcp.Keeper_gh_shared.Issue, 100))
    (extract "issue view 100")

let test_extract_issue_close_number () =
  check target_testable "issue close 17 --reason completed"
    (Some (Masc_mcp.Keeper_gh_shared.Issue, 17))
    (extract "issue close 17 --reason completed")

let test_extract_pr_list_returns_none () =
  (* List commands don't target a specific number — must not trigger validation. *)
  check target_testable "pr list --state open" None (extract "pr list --state open")

let test_extract_pr_create_returns_none () =
  (* Creation is a mutation, not a reference to an existing number. *)
  check target_testable "pr create --title foo --body bar"
    None
    (extract "pr create --title foo --body bar")

let test_extract_issue_list_returns_none () =
  check target_testable "issue list" None (extract "issue list")

let test_extract_issue_create_returns_none () =
  check target_testable "issue create --title foo"
    None
    (extract "issue create --title foo")

let test_extract_pr_view_branch_returns_none () =
  (* [gh pr view my-branch] is valid; first positional is not an integer. *)
  check target_testable "pr view my-feature-branch"
    None
    (extract "pr view my-feature-branch")

let test_extract_unknown_command_returns_none () =
  check target_testable "repo view" None (extract "repo view");
  check target_testable "workflow list" None (extract "workflow list");
  check target_testable "" None (extract "")

let test_extract_extra_whitespace () =
  check target_testable "multiple spaces around 'pr view 55'"
    (Some (Masc_mcp.Keeper_gh_shared.PR, 55))
    (extract "   pr   view    55   ")

let test_extract_zero_is_none () =
  (* 0 is not a valid PR/issue number. *)
  check target_testable "pr view 0" None (extract "pr view 0")

let test_extract_negative_is_none () =
  (* Negative ints fail parsing (leading - looks like a flag and is skipped). *)
  check target_testable "pr view -5" None (extract "pr view -5")

let test_extract_flag_before_number_is_none () =
  (* The parser is strict: it only recognizes `<kind> <sub> <N>` with
     the integer as the immediate third token. If the caller puts a
     flag between [sub] and [N] we fallthrough (Unknown), letting gh
     process the command normally. This keeps the parser sound without
     a gh-flag-table heuristic. *)
  check target_testable "pr view --web 42 (flag precedes number)"
    None
    (extract "pr view --web 42");
  check target_testable "issue view --json title 7"
    None
    (extract "issue view --json title 7")

(* ====================================================================== *)
(* gh_mutates_entity                                                        *)
(* ====================================================================== *)

let test_mutates_pr_create () =
  check (option entity_kind_testable) "pr create"
    (Some Masc_mcp.Keeper_gh_shared.PR)
    (mutates "pr create --title foo")

let test_mutates_pr_close () =
  check (option entity_kind_testable) "pr close"
    (Some Masc_mcp.Keeper_gh_shared.PR)
    (mutates "pr close 123")

let test_mutates_pr_merge () =
  check (option entity_kind_testable) "pr merge"
    (Some Masc_mcp.Keeper_gh_shared.PR)
    (mutates "pr merge 456 --squash")

let test_mutates_issue_create () =
  check (option entity_kind_testable) "issue create"
    (Some Masc_mcp.Keeper_gh_shared.Issue)
    (mutates "issue create --title bug")

let test_mutates_issue_close () =
  check (option entity_kind_testable) "issue close"
    (Some Masc_mcp.Keeper_gh_shared.Issue)
    (mutates "issue close 17")

let test_mutates_pr_list_returns_none () =
  (* Read commands must NOT trigger invalidation. *)
  check (option entity_kind_testable) "pr list" None (mutates "pr list")

let test_mutates_pr_view_returns_none () =
  check (option entity_kind_testable) "pr view" None (mutates "pr view 100")

let test_mutates_issue_list_returns_none () =
  check (option entity_kind_testable) "issue list"
    None
    (mutates "issue list")

let test_mutates_unknown_command_returns_none () =
  check (option entity_kind_testable) "repo view" None (mutates "repo view");
  check (option entity_kind_testable) "workflow list" None (mutates "workflow list")

(* ====================================================================== *)
(* Keeper_gh_shared.validate_number fast-path                                *)
(* ====================================================================== *)

(* These tests only exercise the guard clauses that short-circuit before
   any subprocess. Full cache behavior requires a real [gh api] call,
   which is integration-level rather than unit-level. *)

let dummy_config () : Room.config =
  let tmp = Printf.sprintf "/tmp/test-gh-cache-%d" (Random.bits ()) in
  (try Unix.mkdir tmp 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  (try Unix.mkdir (Filename.concat tmp ".masc") 0o755
   with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Room.default_config tmp

let test_validate_empty_slug_returns_unknown () =
  let config = dummy_config () in
  let result =
    Masc_mcp.Keeper_gh_shared.validate_number
      ~config ~repo_slug:"" ~kind:Masc_mcp.Keeper_gh_shared.PR ~number:42
  in
  check bool "empty slug -> Unknown" true
    (match result with `Unknown -> true | _ -> false)

let test_validate_zero_number_returns_unknown () =
  let config = dummy_config () in
  let result =
    Masc_mcp.Keeper_gh_shared.validate_number
      ~config ~repo_slug:"owner/repo" ~kind:Masc_mcp.Keeper_gh_shared.PR ~number:0
  in
  check bool "zero number -> Unknown" true
    (match result with `Unknown -> true | _ -> false)

let test_validate_negative_number_returns_unknown () =
  let config = dummy_config () in
  let result =
    Masc_mcp.Keeper_gh_shared.validate_number
      ~config ~repo_slug:"owner/repo" ~kind:Masc_mcp.Keeper_gh_shared.Issue ~number:(-1)
  in
  check bool "negative number -> Unknown" true
    (match result with `Unknown -> true | _ -> false)

let test_metrics_initial () =
  let m = Masc_mcp.Keeper_gh_shared.cache_metrics () in
  (* Keys must exist even before any call. *)
  check bool "has hits" true (List.mem_assoc "hits" m);
  check bool "has misses" true (List.mem_assoc "misses" m);
  check bool "has bypasses" true (List.mem_assoc "bypasses" m);
  check bool "has fetch_errors" true (List.mem_assoc "fetch_errors" m)

(* record_rejection lives in keeper_exec_github (private_module) and
   cannot be exposed in its .mli without triggering dune interface-mismatch.
   The logic is a trivial Hashtbl increment — tested indirectly via
   integration tests (server + keeper_github calls with hallucinated numbers).
   If record_rejection is extracted to its own non-private module in the
   future, unit tests should be added here. *)

(* ====================================================================== *)
(* Test runner                                                              *)
(* ====================================================================== *)

let () =
  run "keeper_gh_hallucination_gate"
    [ "extract_gh_target_number",
      [ test_case "pr view 123" `Quick test_extract_pr_view_number
      ; test_case "pr view 456 --json" `Quick test_extract_pr_view_with_flags
      ; test_case "pr merge 789" `Quick test_extract_pr_merge_number
      ; test_case "pr comment 42" `Quick test_extract_pr_comment_number
      ; test_case "issue view 100" `Quick test_extract_issue_view_number
      ; test_case "issue close 17" `Quick test_extract_issue_close_number
      ; test_case "pr list -> None" `Quick test_extract_pr_list_returns_none
      ; test_case "pr create -> None" `Quick test_extract_pr_create_returns_none
      ; test_case "issue list -> None" `Quick test_extract_issue_list_returns_none
      ; test_case "issue create -> None" `Quick test_extract_issue_create_returns_none
      ; test_case "pr view branch -> None" `Quick test_extract_pr_view_branch_returns_none
      ; test_case "unknown command -> None" `Quick test_extract_unknown_command_returns_none
      ; test_case "extra whitespace" `Quick test_extract_extra_whitespace
      ; test_case "number 0 -> None" `Quick test_extract_zero_is_none
      ; test_case "negative number -> None" `Quick test_extract_negative_is_none
      ; test_case "flag before number -> None (strict)" `Quick
          test_extract_flag_before_number_is_none
      ]
    ; "gh_mutates_entity",
      [ test_case "pr create" `Quick test_mutates_pr_create
      ; test_case "pr close" `Quick test_mutates_pr_close
      ; test_case "pr merge" `Quick test_mutates_pr_merge
      ; test_case "issue create" `Quick test_mutates_issue_create
      ; test_case "issue close" `Quick test_mutates_issue_close
      ; test_case "pr list -> None" `Quick test_mutates_pr_list_returns_none
      ; test_case "pr view -> None" `Quick test_mutates_pr_view_returns_none
      ; test_case "issue list -> None" `Quick test_mutates_issue_list_returns_none
      ; test_case "unknown command -> None" `Quick test_mutates_unknown_command_returns_none
      ]
    ; "cache_validate_fast_paths",
      [ test_case "empty slug -> Unknown" `Quick test_validate_empty_slug_returns_unknown
      ; test_case "zero number -> Unknown" `Quick test_validate_zero_number_returns_unknown
      ; test_case "negative number -> Unknown" `Quick test_validate_negative_number_returns_unknown
      ; test_case "metrics keys present" `Quick test_metrics_initial
      ]
    ]
