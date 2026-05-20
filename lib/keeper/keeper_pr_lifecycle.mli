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

val stage_to_string : stage -> string
val stage_of_string : string -> stage option

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

val empty_lineage : lineage

type proof = {
  checks_green : bool;
  review_approved : bool;
  merged_at : string option;
  worktree_cleaned : bool;
  branch_deleted : bool;
}

val empty_proof : proof

type t = {
  stage : stage;
  lineage : lineage;
  proof : proof;
  updated_at_iso : string option;
}

val make : ?updated_at_iso:string -> lineage:lineage -> proof:proof -> stage -> t
val missing_requirements : t -> stage -> string list
val transition : ?updated_at_iso:string -> t -> stage -> (t, string) result
val validate : t -> (unit, string list) result
val to_json : t -> Yojson.Safe.t
