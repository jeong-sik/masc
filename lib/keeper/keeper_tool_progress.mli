(** Keeper_tool_progress - tool progress classification and required-action
    contract helpers.

    This module owns whether a tool call is passive, claim/context binding,
    execution progress, or completion. It is deliberately separate from tool
    disclosure/selection so liveness and contract semantics do not live in the
    prompt-surface module. *)

(** Tool progress class shared by required-tool validation, runtime receipts,
    and liveness metrics. *)
type tool_progress_class =
  | Passive_status
  | Claim_context
  | Execution
  | Completion

val tool_progress_class_to_string : tool_progress_class -> string

(** [turn_effect] abstracts the 4 tool-progress classes into the 3 actual
    effects they have on the turn FSM.

    @since task-555 *)
type turn_effect =
  | Streak_increment
  | Streak_reset
  | Streak_reset_and_empty_queue_sleep of {
      reason : empty_queue_reason;
    }

and empty_queue_reason =
  | No_eligible_tasks of {
      scope_excluded_count : int;
      all_goals_excluded : bool;
    }
  | No_work_to_report

(** Map the legacy 4-class classification to its underlying [turn_effect].
    [Streak_reset_and_empty_queue_sleep] is produced only by typed-outcome
    classification. *)
val effect_of_progress_class : tool_progress_class -> turn_effect

(** Route a tool call through typed-outcome classification.

    When [outcome] is [Some (No_progress (No_eligible_tasks ...))], the result
    is [Streak_reset_and_empty_queue_sleep]. Other outcomes fall back to
    [effect_of_progress_class (classify_tool_progress name)]. *)
val classify_tool_progress_with_outcome
  : string -> Keeper_tool_outcome.t option -> turn_effect

(** Canonical names of claim-context tools (Task_claim, Claim_next). *)
val claim_context_tool_names : string list

(** Canonical names of completion tools (Task_done variants, Stay_silent,
    Deliver, etc.). *)
val completion_tool_names : string list

val is_claim_tool_name : string -> bool
val is_claim_context_tool_name : string -> bool
val is_completion_tool_name : string -> bool

(** [true] iff the tool name represents productive execution progress for a
    required-action gate. Completion tools are exempted even when read-only;
    passive keeper observation tools remain [false]. *)
val tool_name_can_satisfy_required_contract : string -> bool

(** Validate an observed generic [Require_tool_use] call. This accepts mutating
    tools and completion tools. Keeper-local observation/discovery tools and
    LLM-native read/search aliases remain passive. *)
val required_tool_satisfaction
  :  ?satisfying_tools:string list
  -> Agent_sdk.Completion_contract.tool_call
  -> (unit, string) result

(** Variant of [required_tool_satisfaction] for an explicit [required_tools]
    contract. A non-keeper read-only tool can satisfy the turn only when the
    operator/task contract named that exact tool. *)
val required_tool_satisfaction_for_required_names
  :  ?satisfying_tools:string list
  -> required_tool_names:string list
  -> Agent_sdk.Completion_contract.tool_call
  -> (unit, string) result

(** OAS-level satisfaction callback for keeper turns.

    Generic required-tool gates use OAS to enforce tool presence only; MASC
    classifies passive-only / no-execution-progress calls after the run.
    Explicit [required_tool_names] still require the named tool. *)
val required_tool_satisfaction_for_turn
  :  ?satisfying_tools:string list
  -> required_tool_names:string list
  -> Agent_sdk.Completion_contract.tool_call
  -> (unit, string) result

(** Extract OAS completion-contract satisfying-tool hints from an error reason.
    Returns [] when the reason has no hint or the hint is empty. *)
val satisfying_tools_from_contract_violation_reason : string -> string list

(** Project a tool name to its [tool_progress_class]. *)
val classify_tool_progress : string -> tool_progress_class

val is_passive_status_tool_name : string -> bool
val is_execution_progress_tool_name : string -> bool

(** Increment the [keeper_require_tool_use_violations] Prometheus counter with
    [keeper] / [has_current_task] / [contract_status] labels. *)
val record_require_tool_use_violation
  :  keeper_name:string
  -> has_current_task:bool
  -> contract_status:string
  -> unit

(** Build an actionable contract-violation reason describing why the keeper
    failed [Require_tool_use], or [None] when the actionable signal context does
    not apply. *)
val actionable_tool_contract_violation_reason
  :  claim_context_allowed:bool
  -> actionable_signal_context:Keeper_contract_classifier.actionable_signal_context
  -> tool_names:string list
  -> string option
