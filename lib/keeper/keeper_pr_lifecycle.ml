(** Typed PR lifecycle state for keeper-owned implementation work. *)

type stage =
  | Claimed
  | Worktree_ready
  | Drafting
  | Draft_pr_open
  | Review
  | Checks_pending
  | Checks_green
  | Approved
  | Merged
  | Cleaned
  | Blocked
  | Abandoned

let stage_to_string = function
  | Claimed -> "claimed"
  | Worktree_ready -> "worktree_ready"
  | Drafting -> "drafting"
  | Draft_pr_open -> "draft_pr_open"
  | Review -> "review"
  | Checks_pending -> "checks_pending"
  | Checks_green -> "checks_green"
  | Approved -> "approved"
  | Merged -> "merged"
  | Cleaned -> "cleaned"
  | Blocked -> "blocked"
  | Abandoned -> "abandoned"

let stage_of_string = function
  | "claimed" -> Some Claimed
  | "worktree_ready" -> Some Worktree_ready
  | "drafting" -> Some Drafting
  | "draft_pr_open" -> Some Draft_pr_open
  | "review" -> Some Review
  | "checks_pending" -> Some Checks_pending
  | "checks_green" -> Some Checks_green
  | "approved" -> Some Approved
  | "merged" -> Some Merged
  | "cleaned" -> Some Cleaned
  | "blocked" -> Some Blocked
  | "abandoned" -> Some Abandoned
  | _ -> None

type lineage = {
  goal_id : string option;
  task_id : string option;
  keeper_name : string option;
  repo : string option;
  worktree_path : string option;
  branch : string option;
  base_branch : string option;
  pr_number : int option;
  pr_url : string option;
  head_sha : string option;
}

let empty_lineage =
  { goal_id = None
  ; task_id = None
  ; keeper_name = None
  ; repo = None
  ; worktree_path = None
  ; branch = None
  ; base_branch = None
  ; pr_number = None
  ; pr_url = None
  ; head_sha = None
  }

type proof = {
  checks_green : bool;
  review_approved : bool;
  merged_at : string option;
  worktree_cleaned : bool;
  branch_deleted : bool;
}

let empty_proof =
  { checks_green = false
  ; review_approved = false
  ; merged_at = None
  ; worktree_cleaned = false
  ; branch_deleted = false
  }

type t = {
  stage : stage;
  lineage : lineage;
  proof : proof;
  updated_at_iso : string option;
}

let make ?updated_at_iso ~lineage ~proof stage =
  { stage; lineage; proof; updated_at_iso }

let is_blank_opt = function
  | None -> true
  | Some value -> String.trim value = ""

let require_string label value =
  if is_blank_opt value then [ label ] else []

let require_int label = function
  | Some value when value > 0 -> []
  | _ -> [ label ]

let require_bool label value = if value then [] else [ label ]

let base_identity_requirements lifecycle =
  require_string "goal_id" lifecycle.lineage.goal_id
  @ require_string "task_id" lifecycle.lineage.task_id
  @ require_string "keeper_name" lifecycle.lineage.keeper_name
  @ require_string "repo" lifecycle.lineage.repo

let worktree_requirements lifecycle =
  base_identity_requirements lifecycle
  @ require_string "worktree_path" lifecycle.lineage.worktree_path

let branch_requirements lifecycle =
  worktree_requirements lifecycle
  @ require_string "branch" lifecycle.lineage.branch

let pr_requirements lifecycle =
  branch_requirements lifecycle
  @ require_int "pr_number" lifecycle.lineage.pr_number
  @ require_string "pr_url" lifecycle.lineage.pr_url

let missing_requirements lifecycle target =
  match target with
  | Claimed -> base_identity_requirements lifecycle
  | Worktree_ready -> worktree_requirements lifecycle
  | Drafting -> branch_requirements lifecycle
  | Draft_pr_open | Review | Checks_pending -> pr_requirements lifecycle
  | Checks_green ->
    pr_requirements lifecycle
    @ require_bool "checks_green" lifecycle.proof.checks_green
  | Approved ->
    pr_requirements lifecycle
    @ require_bool "checks_green" lifecycle.proof.checks_green
    @ require_bool "review_approved" lifecycle.proof.review_approved
  | Merged ->
    pr_requirements lifecycle
    @ require_bool "checks_green" lifecycle.proof.checks_green
    @ require_bool "review_approved" lifecycle.proof.review_approved
    @ require_string "merged_at" lifecycle.proof.merged_at
  | Cleaned ->
    pr_requirements lifecycle
    @ require_string "merged_at" lifecycle.proof.merged_at
    @ require_bool "worktree_cleaned" lifecycle.proof.worktree_cleaned
    @ require_bool "branch_deleted" lifecycle.proof.branch_deleted
  | Blocked | Abandoned -> base_identity_requirements lifecycle

let allowed_transition from_ to_ =
  match from_, to_ with
  | Cleaned, _ | Abandoned, _ -> false
  | Blocked, _ -> false
  | _, Blocked | _, Abandoned -> true
  | Claimed, Worktree_ready -> true
  | Worktree_ready, Drafting -> true
  | Drafting, Draft_pr_open -> true
  | Draft_pr_open, Review -> true
  | Draft_pr_open, Checks_pending -> true
  | Review, Checks_pending -> true
  | Review, Checks_green -> true
  | Checks_pending, Checks_green -> true
  | Checks_green, Approved -> true
  | Approved, Merged -> true
  | Merged, Cleaned -> true
  | _ -> false

let transition ?updated_at_iso lifecycle target =
  if not (allowed_transition lifecycle.stage target) then
    Error
      (Printf.sprintf "invalid PR lifecycle transition: %s -> %s"
         (stage_to_string lifecycle.stage)
         (stage_to_string target))
  else
    match missing_requirements lifecycle target with
    | [] -> Ok { lifecycle with stage = target; updated_at_iso }
    | missing ->
      Error
        (Printf.sprintf "missing PR lifecycle requirements for %s: %s"
           (stage_to_string target)
           (String.concat ", " missing))

let validate lifecycle =
  match missing_requirements lifecycle lifecycle.stage with
  | [] -> Ok ()
  | missing -> Error missing

let json_string_opt = function
  | Some value when String.trim value <> "" -> `String value
  | _ -> `Null

let json_int_opt = function
  | Some value -> `Int value
  | None -> `Null

let lineage_to_json lineage =
  `Assoc
    [ ("goal_id", json_string_opt lineage.goal_id)
    ; ("task_id", json_string_opt lineage.task_id)
    ; ("keeper_name", json_string_opt lineage.keeper_name)
    ; ("repo", json_string_opt lineage.repo)
    ; ("worktree_path", json_string_opt lineage.worktree_path)
    ; ("branch", json_string_opt lineage.branch)
    ; ("base_branch", json_string_opt lineage.base_branch)
    ; ("pr_number", json_int_opt lineage.pr_number)
    ; ("pr_url", json_string_opt lineage.pr_url)
    ; ("head_sha", json_string_opt lineage.head_sha)
    ]

let proof_to_json proof =
  `Assoc
    [ ("checks_green", `Bool proof.checks_green)
    ; ("review_approved", `Bool proof.review_approved)
    ; ("merged_at", json_string_opt proof.merged_at)
    ; ("worktree_cleaned", `Bool proof.worktree_cleaned)
    ; ("branch_deleted", `Bool proof.branch_deleted)
    ]

let to_json lifecycle =
  `Assoc
    [ ("stage", `String (stage_to_string lifecycle.stage))
    ; ("lineage", lineage_to_json lifecycle.lineage)
    ; ("proof", proof_to_json lifecycle.proof)
    ; ("updated_at_iso", json_string_opt lifecycle.updated_at_iso)
    ; ( "missing_requirements",
        `List
          (List.map
             (fun value -> `String value)
             (missing_requirements lifecycle lifecycle.stage)) )
    ]
