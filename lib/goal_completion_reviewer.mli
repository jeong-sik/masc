(** Provider-neutral semantic review for Goal completion claims.

    The Goal lifecycle owns persistence; this module only obtains one typed
    structured verdict from the configured completion-review runtime. A missing
    runtime, provider failure, malformed tool call, or missing tool call is an
    explicit unavailable result and never authorizes completion. *)

type review_request =
  { goal : Goal_store.goal
  ; completion_claim : string
  ; agent_name : string
  ; linked_tasks : Masc_domain.task list
  ; child_goals : Goal_store.goal list
  }

type verdict =
  | Approve
  | Reject of string

val verdict_constructor_name : verdict -> string

type gate =
  | Structured_tool
  | Invalid_verdict
  | Evaluator_unavailable

type review_result =
  { verdict : verdict option
  ; evaluator_runtime : string
  ; review_prompt_sha256 : string option
  ; gate : gate
  ; fallback_reason : string option
  }

val review : review_request -> review_result

val build_prompt : review_request -> (string, string) result
val parse_verdict_from_json : Yojson.Safe.t -> (verdict, string) result

val run_llm_reviewer_fn :
  (?sw:Eio.Switch.t ->
   evaluator_runtime:string ->
   prompt:string ->
   report_tool_schema:Types_core.tool_schema ->
   unit ->
   (verdict option, Agent_sdk.Error.sdk_error) result)
    Atomic.t
