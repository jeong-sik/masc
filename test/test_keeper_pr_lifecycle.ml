open Alcotest

module Lifecycle = Masc_mcp.Keeper_pr_lifecycle

let lineage =
  { Lifecycle.empty_lineage with
    goal_id = Some "goal-1"
  ; task_id = Some "task-1"
  ; keeper_name = Some "keeper-a"
  ; repo = Some "jeong-sik/masc-mcp"
  ; worktree_path = Some "/repo/.worktrees/task-1"
  ; branch = Some "codex/task-1"
  ; base_branch = Some "main"
  ; pr_number = Some 123
  ; pr_url = Some "https://github.com/jeong-sik/masc-mcp/pull/123"
  ; head_sha = Some "abc123"
  }

let transition_exn lifecycle target =
  match Lifecycle.transition lifecycle target with
  | Ok lifecycle -> lifecycle
  | Error error -> fail error

let test_happy_path_reaches_cleaned () =
  let proof_pending = Lifecycle.empty_proof in
  let lifecycle = Lifecycle.make ~lineage ~proof:proof_pending Lifecycle.Claimed in
  let lifecycle = transition_exn lifecycle Lifecycle.Worktree_ready in
  let lifecycle = transition_exn lifecycle Lifecycle.Drafting in
  let lifecycle = transition_exn lifecycle Lifecycle.Draft_pr_open in
  let lifecycle = transition_exn lifecycle Lifecycle.Review in
  let lifecycle = transition_exn lifecycle Lifecycle.Checks_pending in
  let lifecycle =
    { lifecycle with
      proof = { lifecycle.proof with checks_green = true; review_approved = true }
    }
    |> fun lifecycle -> transition_exn lifecycle Lifecycle.Checks_green
    |> fun lifecycle -> transition_exn lifecycle Lifecycle.Approved
  in
  let lifecycle =
    { lifecycle with proof = { lifecycle.proof with merged_at = Some "2026-05-21T00:00:00Z" } }
    |> fun lifecycle -> transition_exn lifecycle Lifecycle.Merged
  in
  let lifecycle =
    { lifecycle with
      proof = { lifecycle.proof with worktree_cleaned = true; branch_deleted = true }
    }
    |> fun lifecycle -> transition_exn lifecycle Lifecycle.Cleaned
  in
  check string "terminal stage" "cleaned" (Lifecycle.stage_to_string lifecycle.stage);
  check bool "valid terminal" true (Result.is_ok (Lifecycle.validate lifecycle))

let test_pr_open_requires_pr_identity () =
  let lineage = { lineage with pr_number = None; pr_url = None } in
  let lifecycle = Lifecycle.make ~lineage ~proof:Lifecycle.empty_proof Lifecycle.Drafting in
  match Lifecycle.transition lifecycle Lifecycle.Draft_pr_open with
  | Ok _ -> fail "expected missing PR identity rejection"
  | Error error ->
    check bool "mentions pr_number" true (String.contains error 'p');
    check bool "mentions pr_url" true (String.contains error 'u')

let test_merge_requires_green_checks_and_review () =
  let lifecycle = Lifecycle.make ~lineage ~proof:Lifecycle.empty_proof Lifecycle.Approved in
  match Lifecycle.transition lifecycle Lifecycle.Merged with
  | Ok _ -> fail "expected merge preflight rejection"
  | Error error ->
    check bool "mentions checks" true (String.contains error 'c');
    check bool "mentions review" true (String.contains error 'r')

let test_cannot_skip_from_drafting_to_merged () =
  let proof =
    { Lifecycle.empty_proof with
      checks_green = true
    ; review_approved = true
    ; merged_at = Some "2026-05-21T00:00:00Z"
    }
  in
  let lifecycle = Lifecycle.make ~lineage ~proof Lifecycle.Drafting in
  match Lifecycle.transition lifecycle Lifecycle.Merged with
  | Ok _ -> fail "expected invalid transition rejection"
  | Error error ->
    check bool "mentions invalid transition" true (String.contains error 'i')

let test_terminal_stage_does_not_resume () =
  let lifecycle =
    Lifecycle.make ~lineage
      ~proof:
        { Lifecycle.empty_proof with
          checks_green = true
        ; review_approved = true
        ; merged_at = Some "2026-05-21T00:00:00Z"
        ; worktree_cleaned = true
        ; branch_deleted = true
        }
      Lifecycle.Cleaned
  in
  match Lifecycle.transition lifecycle Lifecycle.Worktree_ready with
  | Ok _ -> fail "expected terminal transition rejection"
  | Error error ->
    check bool "mentions invalid transition" true (String.contains error 'i')

let () =
  run "Keeper_pr_lifecycle"
    [ ( "fsm"
      , [ test_case "happy path reaches cleaned" `Quick test_happy_path_reaches_cleaned
        ; test_case "PR open requires PR identity" `Quick
            test_pr_open_requires_pr_identity
        ; test_case "merge requires checks and review" `Quick
            test_merge_requires_green_checks_and_review
        ; test_case "cannot skip from drafting to merged" `Quick
            test_cannot_skip_from_drafting_to_merged
        ; test_case "terminal stage does not resume" `Quick
            test_terminal_stage_does_not_resume
        ] )
    ]
