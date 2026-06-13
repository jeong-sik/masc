(** Keeper_tool_progress - tool progress classification helpers.

    This module owns whether a tool call is passive, claim/context binding,
    execution progress, or completion. It is deliberately separate from tool
    disclosure/selection so liveness and contract semantics do not live in the
    prompt-surface module. *)

(** Tool progress class shared by runtime receipts and liveness metrics. *)
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

(** Canonical names of claim-context tools (Task_claim). *)
val claim_context_tool_names : string list

(** Canonical names of completion tools (Task_done variants, Stay_silent,
    Deliver, etc.). *)
val completion_tool_names : string list

val is_claim_tool_name : string -> bool
val is_claim_context_tool_name : string -> bool
val is_completion_tool_name : string -> bool

(** [true] iff the canonicalized name is keeper_stay_silent. *)
val is_stay_silent_tool_name : string -> bool

(** Extract OAS completion-contract satisfying-tool hints from an error reason.
    Returns [] when the reason has no hint or the hint is empty. *)
val satisfying_tools_from_contract_violation_reason : string -> string list

(** Project a tool name to its [tool_progress_class]. *)
val classify_tool_progress : string -> tool_progress_class

val is_passive_status_tool_name : string -> bool
val is_execution_progress_tool_name : string -> bool
val is_owned_task_progress_tool_name : string -> bool

val tool_result_has_material_progress
  :  tool_name:string
  -> output_text:string
  -> bool
