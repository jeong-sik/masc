(** Pure Goal-completion evidence and receipt contract.

    This module has no runtime/provider authority.  It only parses the exact
    verdict wire shape and canonicalises current-schema JSON for durable
    evidence and target digests. *)

type verdict =
  | Approve
  | Reject of string

val verdict_constructor_name : verdict -> string
val parse_verdict_from_json : Yojson.Safe.t -> (verdict, string) result

val canonical_string : Yojson.Safe.t -> (string, string) result
val canonical_sha256 : Yojson.Safe.t -> (string, string) result

val review_evidence_sha256 :
  workspace_identity:string ->
  goal_json:Yojson.Safe.t ->
  completion_claim:string ->
  requesting_agent:string ->
  linked_tasks_json:Yojson.Safe.t ->
  linked_task_ids:string list ->
  child_goals_json:Yojson.Safe.t ->
  string

val completion_digest :
  workspace_identity:string ->
  goal_json:Yojson.Safe.t ->
  reviewed_goal_updated_at:string ->
  goal_id:string ->
  expected_version:int ->
  operation_id:string ->
  evaluator_runtime:string ->
  reviewed_at:string ->
  review_prompt_sha256:string ->
  review_evidence_sha256:string ->
  completion_claim:string ->
  requesting_agent:string ->
  linked_task_ids:string list ->
  string

module For_testing : sig
  val completion_digest :
    workspace_identity:string ->
    goal_json:Yojson.Safe.t ->
    reviewed_goal_updated_at:string ->
    goal_id:string ->
    expected_version:int ->
    operation_id:string ->
    evaluator_runtime:string ->
    reviewed_at:string ->
    review_prompt_sha256:string ->
    review_evidence_sha256:string ->
    completion_claim:string ->
    requesting_agent:string ->
    linked_task_ids:string list ->
    string

  val review_evidence_sha256 :
    workspace_identity:string ->
    goal_json:Yojson.Safe.t ->
    completion_claim:string ->
    requesting_agent:string ->
    linked_tasks_json:Yojson.Safe.t ->
    linked_task_ids:string list ->
    child_goals_json:Yojson.Safe.t ->
    string
end
