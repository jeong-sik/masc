(** Provider-neutral semantic review for Goal completion claims.

    The Goal lifecycle owns persistence; this module only obtains one typed
    structured verdict from the configured completion-review runtime. A missing
    runtime, provider failure, malformed tool call, or missing tool call is an
    explicit unavailable result and never authorizes completion. *)

type review_request =
  { goal_id : string
  ; goal_version : int
  ; operation_id : string
  ; goal_json : Yojson.Safe.t
  ; completion_claim : string
  ; agent_name : string
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
(** Opaque, operation-bound authority minted only after the configured semantic
    reviewer returns one exact structured APPROVE verdict. *)

type approval_metadata = private
  { evaluator_runtime : string
  ; reviewed_at : string
  ; review_prompt_sha256 : string
  ; completion_claim : string
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
  goal_id:string ->
  goal_version:int ->
  operation_id:string ->
  completion_digest:string ->
  bool

val approval_metadata : approval -> approval_metadata
