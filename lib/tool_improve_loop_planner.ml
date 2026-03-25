(** Tool_improve_loop_planner — candidate ranking and plan generation. *)

open Tool_improve_loop_types

(* ================================================================ *)
(* Label / PR classification                                        *)
(* ================================================================ *)

let normalize_label label =
  String.lowercase_ascii (String.trim label)

let has_priority_label labels =
  List.exists
    (fun label ->
      let normalized = normalize_label label in
      List.mem normalized [ "high"; "bug"; "safety"; "priority:high"; "type:bug" ])
    labels

let is_conflicting_pr (pr : pr_summary) =
  match (pr.mergeable, pr.merge_state_status) with
  | Some "CONFLICTING", _ -> true
  | _, Some "DIRTY" -> true
  | _ -> false

let is_loop_owned_branch branch_name =
  String.starts_with ~prefix:"loop/" branch_name

let is_merge_ready_pr ?(review_ok = false) (pr : pr_summary) =
  is_loop_owned_branch pr.head_ref_name
  && review_ok
  && not pr.is_draft
  && pr.failing_checks = []
  && pr.pending_checks = []
  &&
  match pr.mergeable with
  | Some "MERGEABLE" -> (
      match pr.base_ref_name with
      | Some ("main" | "master") -> true
      | _ -> false)
  | _ -> false

(* ================================================================ *)
(* Candidate construction and ranking                               *)
(* ================================================================ *)

let candidate_priority = function
  | Merge_ready_pr -> 0
  | Conflict_pr -> 1
  | Failing_pr -> 2
  | Priority_issue -> 3
  | Backlog_issue -> 4

let candidate_compare left right =
  let priority_cmp =
    compare (candidate_priority left.kind) (candidate_priority right.kind)
  in
  if priority_cmp <> 0 then priority_cmp else compare left.number right.number

let candidate_of_pr ?(review_ok = false) (pr : pr_summary) =
  let kind =
    if is_merge_ready_pr ~review_ok pr then Merge_ready_pr
    else if is_conflicting_pr pr then Conflict_pr
    else Failing_pr
  in
  {
    kind;
    number = pr.number;
    title = pr.title;
    url = pr.url;
    head_ref_name = Some pr.head_ref_name;
    base_ref_name = pr.base_ref_name;
    mergeable = pr.mergeable;
    merge_state_status = pr.merge_state_status;
    labels = [];
    failing_checks = pr.failing_checks;
    pending_checks = pr.pending_checks;
  }

let candidate_of_issue (issue : issue_summary) =
  {
    kind = if has_priority_label issue.labels then Priority_issue else Backlog_issue;
    number = issue.number;
    title = issue.title;
    url = issue.url;
    head_ref_name = None;
    base_ref_name = None;
    mergeable = None;
    merge_state_status = None;
    labels = issue.labels;
    failing_checks = [];
    pending_checks = [];
  }

let rank_candidates ?skip_candidate_id ?(review_ok = false)
    ~(prs : pr_summary list) ~(issues : issue_summary list) () =
  let candidates =
    (prs
    |> List.filter (fun pr -> is_conflicting_pr pr || pr.failing_checks <> [] || is_merge_ready_pr ~review_ok pr)
    |> List.map (candidate_of_pr ~review_ok))
    @ (issues |> List.map candidate_of_issue)
  in
  candidates
  |> List.filter (fun candidate ->
         match skip_candidate_id with
         | Some skip -> not (String.equal skip (candidate_id candidate))
         | None -> true)
  |> List.sort candidate_compare

(* ================================================================ *)
(* Worktree path helpers                                            *)
(* ================================================================ *)

let repo_root (config : Room.config) =
  match Autoresearch.git_top_level ~workdir:config.base_path with
  | Ok root -> root
  | Error _ -> config.base_path

let loop_worktree_path repo_root slug =
  Filename.concat (Filename.concat repo_root ".worktrees/loop") slug

let issue_branch_name candidate =
  Printf.sprintf "loop/issue-%d-%s" candidate.number (slugify candidate.title)

let issue_worktree_path repo_root candidate =
  loop_worktree_path repo_root
    (Printf.sprintf "issue-%d-%s" candidate.number (slugify candidate.title))

let pr_worktree_path repo_root candidate =
  loop_worktree_path repo_root
    (Printf.sprintf "pr-%d-%s" candidate.number (slugify candidate.title))

let ensure_parent_dir path =
  Fs_compat.mkdir_p (Filename.dirname path)

(* ================================================================ *)
(* Merge gate                                                       *)
(* ================================================================ *)

let merge_gate_reasons ~review_ok (candidate : candidate) =
  let owned =
    option_exists is_loop_owned_branch candidate.head_ref_name
  in
  let checks_green =
    candidate.failing_checks = [] && candidate.pending_checks = []
  in
  let target_main =
    match candidate.base_ref_name with
    | Some ("main" | "master") -> true
    | _ -> false
  in
  let mergeable =
    match candidate.mergeable with
    | Some "MERGEABLE" -> true
    | _ -> false
  in
  []
  |> fun acc -> if owned then acc else "branch_not_owned_by_loop" :: acc
  |> fun acc -> if checks_green then acc else "checks_not_green" :: acc
  |> fun acc -> if review_ok then acc else "review_gate_not_passed" :: acc
  |> fun acc -> if target_main then acc else "base_not_main" :: acc
  |> fun acc -> if mergeable then acc else "not_mergeable" :: acc
  |> List.rev

let merge_command_if_ready (state : state) ~review_ok (candidate : candidate) =
  if (not review_ok) || candidate.kind <> Merge_ready_pr then
    None
  else
    match merge_gate_reasons ~review_ok candidate with
    | [] ->
        Some
          (shell_join
             [
               "gh";
               "pr";
               "merge";
               string_of_int candidate.number;
               "--repo";
               state.repo;
               Printf.sprintf "--%s" state.merge_policy;
               "--delete-branch";
             ])
    | _ -> None

(* ================================================================ *)
(* Plan generation                                                  *)
(* ================================================================ *)

let issue_plan repo_root state (candidate : candidate) =
  let branch_name = issue_branch_name candidate in
  let worktree_path = issue_worktree_path repo_root candidate in
  let commands =
    [
      shell_join [ "gh"; "issue"; "view"; string_of_int candidate.number; "--repo"; state.repo ];
      shell_join [ "git"; "-C"; repo_root; "fetch"; "origin"; "--prune" ];
      shell_join
        [
          "git";
          "-C";
          repo_root;
          "worktree";
          "add";
          "-B";
          branch_name;
          worktree_path;
          "origin/main";
        ];
      shell_join [ "cd"; worktree_path ];
      shell_join [ "./scripts/review/local-review.sh"; "--base"; "origin/main"; "--head"; "HEAD"; "--format"; "markdown" ];
      shell_join [ "./scripts/pr-open.sh"; "--repo"; state.repo; "--no-watch" ];
    ]
  in
  {
    action_id = Printf.sprintf "issue-%d" candidate.number;
    phase = "issue_burn_down";
    summary = Printf.sprintf "Prepare issue #%d in an isolated worktree" candidate.number;
    candidate;
    worktree_path = Some worktree_path;
    branch_name = Some branch_name;
    commands;
    merge_command = None;
    requires_team_session = true;
    notes =
      [
        "Reproduce the issue before editing.";
        "Patch narrowly, then run targeted verification before opening the draft PR.";
      ];
  }

let failing_pr_plan repo_root state (candidate : candidate) =
  let branch_name =
    candidate.head_ref_name |> Option.value ~default:(Printf.sprintf "loop/pr-%d" candidate.number)
  in
  let worktree_path = pr_worktree_path repo_root candidate in
  {
    action_id = Printf.sprintf "pr-%d-failing" candidate.number;
    phase = "pr_failing_checks";
    summary =
      Printf.sprintf "Prepare PR #%d branch for local check/fix work" candidate.number;
    candidate;
    worktree_path = Some worktree_path;
    branch_name = Some branch_name;
    commands =
      [
        shell_join [ "gh"; "pr"; "checks"; string_of_int candidate.number; "--repo"; state.repo ];
        shell_join [ "git"; "-C"; repo_root; "fetch"; "origin"; "--prune" ];
        shell_join
          [
            "git";
            "-C";
            repo_root;
            "worktree";
            "add";
            "-B";
            branch_name;
            worktree_path;
            Printf.sprintf "origin/%s" branch_name;
          ];
        shell_join [ "cd"; worktree_path ];
        shell_join [ "./scripts/review/local-review.sh"; "--base"; "origin/main"; "--head"; "HEAD"; "--format"; "markdown" ];
      ];
    merge_command = None;
    requires_team_session = true;
    notes =
      List.map (fun check_name -> "Failing check: " ^ check_name) candidate.failing_checks;
  }

let conflict_pr_plan repo_root _state (candidate : candidate) =
  let branch_name =
    candidate.head_ref_name |> Option.value ~default:(Printf.sprintf "pr-%d-head" candidate.number)
  in
  let worktree_path = pr_worktree_path repo_root candidate in
  {
    action_id = Printf.sprintf "pr-%d-conflict" candidate.number;
    phase = "pr_conflict";
    summary =
      Printf.sprintf "Prepare PR #%d conflict-resolution worktree" candidate.number;
    candidate;
    worktree_path = Some worktree_path;
    branch_name = Some branch_name;
    commands =
      [
        shell_join [ "git"; "-C"; repo_root; "fetch"; "origin"; "--prune" ];
        shell_join
          [
            "git";
            "-C";
            repo_root;
            "worktree";
            "add";
            "-B";
            branch_name;
            worktree_path;
            Printf.sprintf "origin/%s" branch_name;
          ];
        shell_join [ "git"; "-C"; worktree_path; "merge"; "--no-edit"; "origin/main" ];
        shell_join [ "./scripts/review/local-review.sh"; "--base"; "origin/main"; "--head"; "HEAD"; "--format"; "markdown" ];
      ];
    merge_command = None;
    requires_team_session = false;
    notes =
      [
        "If merge exits non-zero with unmerged paths, keep the worktree and resolve conflicts there.";
      ];
  }

let merge_ready_plan state (candidate : candidate) =
  let merge_command = merge_command_if_ready state ~review_ok:true candidate in
  {
    action_id = Printf.sprintf "pr-%d-merge" candidate.number;
    phase = "merge_ready";
    summary = Printf.sprintf "Merge loop-owned PR #%d" candidate.number;
    candidate;
    worktree_path = None;
    branch_name = candidate.head_ref_name;
    commands = (match merge_command with Some cmd -> [ cmd ] | None -> []);
    merge_command;
    requires_team_session = false;
    notes = [ "Merge only after required checks and cross-model review are both green." ];
  }

let plan_for_candidate repo_root state ?review_ok:(_review_ok = false) candidate =
  match candidate.kind with
  | Merge_ready_pr -> merge_ready_plan state candidate
  | Conflict_pr -> conflict_pr_plan repo_root state candidate
  | Failing_pr -> failing_pr_plan repo_root state candidate
  | Priority_issue | Backlog_issue -> issue_plan repo_root state candidate
