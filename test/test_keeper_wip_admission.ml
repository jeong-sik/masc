open Alcotest

module Admission = Masc_mcp.Keeper_wip_admission

let scope ?goal_id ?(category = Admission.Fix) repo =
  { Admission.repo; goal_id; category }

let item ?goal_id ?(category = Admission.Fix) repo id =
  { Admission.id; scope = scope ?goal_id ~category repo }

let task ?worktree ?goal_id ?(status = Masc_domain.Todo) ?(title = "fix: task") id =
  { Masc_domain.id
  ; title
  ; description = ""
  ; task_status = status
  ; priority = 3
  ; files = []
  ; created_at = "2026-05-21T00:00:00Z"
  ; created_by = None
  ; worktree
  ; goal_id
  ; stage = None
  ; contract = None
  ; handoff_context = None
  ; cycle_count = 0
  ; reclaim_policy = None
  ; do_not_reclaim_reason = None
  }

let worktree repo_name =
  { Masc_domain.branch = "branch"
  ; path = "/tmp/worktree"
  ; git_root = "/tmp/repo"
  ; repo_name
  }

let caps =
  { Admission.max_global = Some 10
  ; max_per_repo = Some 2
  ; max_per_goal = Some 1
  ; max_per_category = Some 3
  }

let test_admits_below_caps () =
  let active = [ item ~goal_id:"goal-a" "repo-a" "one" ] in
  match Admission.decide ~caps active ~scope:(scope ~goal_id:"goal-b" "repo-a") with
  | Admission.Admit { active_count_after_admit } ->
    check int "active after admit" 2 active_count_after_admit
  | Reject rejection ->
    fail
      (Printf.sprintf "unexpected reject: %s"
         (Admission.reject_reason_to_string rejection.reason))

let test_rejects_repo_cap_before_goal_cap () =
  let active =
    [ item ~goal_id:"goal-a" "repo-a" "one"
    ; item ~goal_id:"goal-b" "repo-a" "two"
    ]
  in
  match Admission.decide ~caps active ~scope:(scope ~goal_id:"goal-c" "repo-a") with
  | Admission.Admit _ -> fail "expected repo cap rejection"
  | Reject rejection ->
    check string "reason" "repo_cap"
      (Admission.reject_reason_to_string rejection.reason);
    check int "current" 2 rejection.current;
    check int "limit" 2 rejection.limit;
    check string "scope key" "repo:repo-a" rejection.scope_key

let test_rejects_goal_cap () =
  let active = [ item ~goal_id:"goal-a" "repo-a" "one" ] in
  match Admission.decide ~caps active ~scope:(scope ~goal_id:"goal-a" "repo-b") with
  | Admission.Admit _ -> fail "expected goal cap rejection"
  | Reject rejection ->
    check string "reason" "goal_cap"
      (Admission.reject_reason_to_string rejection.reason);
    check string "scope key" "goal:goal-a" rejection.scope_key

let test_rejects_category_cap_across_repos () =
  let active =
    [ item ~goal_id:"goal-a" ~category:Admission.Refactor "repo-a" "one"
    ; item ~goal_id:"goal-b" ~category:Admission.Refactor "repo-b" "two"
    ; item ~goal_id:"goal-c" ~category:Admission.Refactor "repo-c" "three"
    ]
  in
  match
    Admission.decide ~caps active
      ~scope:(scope ~goal_id:"goal-d" ~category:Admission.Refactor "repo-d")
  with
  | Admission.Admit _ -> fail "expected category cap rejection"
  | Reject rejection ->
    check string "reason" "category_cap"
      (Admission.reject_reason_to_string rejection.reason);
    check string "scope key" "category:refactor" rejection.scope_key

let test_active_counts_surface_all_axes () =
  let active =
    [ item ~goal_id:"goal-a" ~category:Admission.Fix "repo-a" "one"
    ; item ~goal_id:"goal-b" ~category:Admission.Docs "repo-a" "two"
    ; item ~goal_id:"goal-a" ~category:Admission.Fix "repo-b" "three"
    ]
  in
  let counts = Admission.active_counts ~scope:(scope ~goal_id:"goal-a" "repo-a") active in
  check (list (pair string int)) "counts"
    [ "global", 3; "repo:repo-a", 2; "goal:goal-a", 2; "category:fix", 2 ]
    counts

let test_decision_json_rejects_with_scope_key () =
  let decision =
    Admission.decide
      ~caps:{ caps with max_global = Some 0 }
      [] ~scope:(scope "repo-a")
  in
  let json = Admission.decision_to_json decision in
  check string "reason" "global_cap"
    Yojson.Safe.Util.(json |> member "reason" |> to_string);
  check string "scope key" "global"
    Yojson.Safe.Util.(json |> member "scope_key" |> to_string)

let test_scope_of_task_uses_repo_goal_and_title_category () =
  let scope =
    Admission.scope_of_task
      ~default_repo:"fallback"
      (task
         ~worktree:(worktree "masc-mcp")
         ~goal_id:"goal-a"
         ~title:"refactor(keeper): split claim gate"
         "task-001")
  in
  check string "repo" "masc-mcp" scope.repo;
  check (option string) "goal" (Some "goal-a") scope.goal_id;
  check string "category" "refactor" (Admission.category_to_string scope.category)

let test_active_items_only_include_claimed_or_in_progress () =
  let tasks =
    [ task
        ~status:(Masc_domain.Claimed { assignee = "a"; claimed_at = "now" })
        ~goal_id:"goal-a"
        "task-001"
    ; task
        ~status:(Masc_domain.InProgress { assignee = "b"; started_at = "now" })
        ~title:"docs: update runbook"
        "task-002"
    ; task ~title:"fix: still todo" "task-003"
    ]
  in
  let active = Admission.active_items_of_tasks ~default_repo:"fallback" tasks in
  check (list string) "active ids" [ "task-001"; "task-002" ]
    (List.map (fun item -> item.Admission.id) active);
  check (list string) "categories" [ "fix"; "docs" ]
    (List.map
       (fun item -> Admission.category_to_string item.Admission.scope.category)
       active)

let () =
  run "Keeper_wip_admission"
    [ ( "caps"
      , [ test_case "admits below caps" `Quick test_admits_below_caps
        ; test_case "rejects repo cap before goal cap" `Quick
            test_rejects_repo_cap_before_goal_cap
        ; test_case "rejects goal cap" `Quick test_rejects_goal_cap
        ; test_case "rejects category cap across repos" `Quick
            test_rejects_category_cap_across_repos
        ; test_case "active counts surface all axes" `Quick
            test_active_counts_surface_all_axes
        ; test_case "decision JSON rejects with scope key" `Quick
            test_decision_json_rejects_with_scope_key
        ; test_case "task scope uses repo goal and title category" `Quick
            test_scope_of_task_uses_repo_goal_and_title_category
        ; test_case "active items include active WIP only" `Quick
            test_active_items_only_include_claimed_or_in_progress
        ] )
    ]
