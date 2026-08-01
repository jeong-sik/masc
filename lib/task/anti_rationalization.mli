(** Configured-LLM task-completion review. Only the structured
    [report_review_verdict] tool call can produce [Approve] or [Reject]. Missing
    configuration, provider failure, prompt-render failure, and missing or
    malformed tool calls remain typed non-verdict outcomes. *)

type review_request =
  { task_title : string
  ; task_description : string
  ; completion_notes : string
  ; agent_name : string
  ; task_id : string
  ; evidence_refs : string list
  }

type verdict =
  | Approve
  | Reject of string

val verdict_constructor_name : verdict -> string
val valid_verdict_strings : string list

type gate =
  | Structured_tool
  | Invalid_verdict
  | Evaluator_unavailable

val gate_to_string : gate -> string

type review_result =
  { verdict : verdict option
  ; evaluator_runtime : string
  ; generator_runtime : string option
  ; gate : gate
  ; fallback_reason : string option
  }

val review
  :  ?evaluator_runtime:string
  -> ?generator_runtime:string
  -> ?completion_contract:string list
  -> ?required_evidence:string list
  -> ?verify_gate_evidence:string list
  -> ?on_verdict:(review_result -> unit)
  -> ?few_shot_block:string
  -> ?sw:Eio.Switch.t option
  -> base_path:string
  -> review_request
  -> review_result
(** [base_path] is the workspace BasePath selected by the caller. The review
    must not rediscover it from process-global environment state. *)

(** Render the single prompt-registry SSOT. There is no inline fallback prompt;
    an error keeps the Task nonterminal. *)
val build_prompt
  :  ?few_shot_block:string
  -> ?completion_contract:string list
  -> ?required_evidence:string list
  -> ?verify_gate_evidence:string list
  -> review_request
  -> (string, string) result

val parse_review_verdict_from_json : Yojson.Safe.t -> (verdict, string) result

val outcome_observer_fn : (outcome:string -> runtime:string -> unit) Atomic.t

val run_llm_reviewer_fn
  :  (base_path:string
      -> ?sw:Eio.Switch.t
      -> evaluator_runtime:string
      -> prompt:string
      -> report_tool_schema:Types_core.tool_schema
      -> unit
      -> (verdict option, Agent_sdk.Error.sdk_error) result)
       Atomic.t
(** The system agent supplies its owning workspace BasePath explicitly; this
    callback must not substitute a process-global BasePath. *)
