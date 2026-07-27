(** Private current-schema Goal completion authority.

    This module is a private module of the main [masc] library.  Its abstract
    [seal] cannot be constructed through the public Goal domain surface. *)

type snapshot
type seal

type commit_error =
  | Snapshot_changed of string
  | Current_evidence_unavailable of string
  | Persistence_failed of string

val capture_snapshot :
  config:Workspace_utils.config ->
  goal:Goal_store.goal ->
  state_version:int ->
  completion_claim:string ->
  requesting_agent:string ->
  (snapshot, string) result

val snapshot_goal_id : snapshot -> string
val snapshot_goal_json : snapshot -> Yojson.Safe.t
val snapshot_linked_tasks_json : snapshot -> Yojson.Safe.t
val snapshot_linked_task_ids : snapshot -> string list
val snapshot_child_goals_json : snapshot -> Yojson.Safe.t
val snapshot_workspace_identity : snapshot -> string
val snapshot_state_version : snapshot -> int
val snapshot_completion_claim : snapshot -> string
val snapshot_requesting_agent : snapshot -> string

val seal_approved_review :
  snapshot:snapshot ->
  operation_id:string ->
  evaluator_runtime:string ->
  reviewed_at:string ->
  review_prompt_sha256:string ->
  seal

val commit_completed :
  config:Workspace_utils.config ->
  seal ->
  (Goal_store.goal, commit_error) result
