(** Provider-neutral semantic review and opaque authority for Goal completion. *)

type review_request =
  { workspace_identity : string
  ; goal_id : string
  ; goal_version : int
  ; operation_id : string
  ; goal_json : Yojson.Safe.t
  ; goal_updated_at : string
  ; completion_claim : string
  ; requesting_agent : string
  ; linked_tasks_json : Yojson.Safe.t
  ; linked_task_ids : string list
  ; child_goals_json : Yojson.Safe.t
  }

type verdict =
  | Approve
  | Reject of string

val verdict_constructor_name : verdict -> string

type gate =
  | Structured_tool
  | Invalid_verdict
  | Evaluator_unavailable

type approval
(** Operation-bound authority minted only after one exact structured APPROVE.
    There is intentionally no constructor, decoder, or testing mint. *)

type approval_metadata = private
  { workspace_identity : string
  ; goal_id : string
  ; expected_version : int
  ; operation_id : string
  ; completion_digest : string
  ; evaluator_runtime : string
  ; reviewed_at : string
  ; reviewed_goal_updated_at : string
  ; review_prompt_sha256 : string
  ; review_evidence_sha256 : string
  ; completion_claim : string
  ; requesting_agent : string
  ; linked_task_ids : string list
  }

type review_result =
  { verdict : verdict option
  ; approval : approval option
  ; evaluator_runtime : string
  ; review_prompt_sha256 : string option
  ; gate : gate
  ; fallback_reason : string option
  }

val review : review_request -> review_result
val build_prompt : review_request -> (string, string) result
val parse_verdict_from_json : Yojson.Safe.t -> (verdict, string) result

val approval_authorizes :
  approval ->
  workspace_identity:string ->
  goal_json:Yojson.Safe.t ->
  reviewed_goal_updated_at:string ->
  goal_id:string ->
  expected_version:int ->
  operation_id:string ->
  linked_tasks_json:Yojson.Safe.t ->
  linked_task_ids:string list ->
  child_goals_json:Yojson.Safe.t ->
  bool

val approval_metadata : approval -> approval_metadata

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
