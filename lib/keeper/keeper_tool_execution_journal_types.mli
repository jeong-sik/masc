(** The types of an owned source and of a node's replay, and the journal's
    error type.

    [nested_origin] and [named_origin] say whether a named producer ran
    standalone or inside a parent attempt. [producer] and [source] identify the
    prepared run that owns the journal, and [source_observation] holds the
    trace, session and turn ids seen with it. [completed], [recheck] and
    [recheck_launch] (with its [launch_invocation]) are the evidence a node
    already has, and [replay] says what a retry does with it. [error] lists
    every refusal of the journal; [error_to_json] and [error_to_string] render
    it and [failure_class] gives its tool failure class.
    [Keeper_tool_execution_journal] includes this module. *)

type nested_origin =
  { parent_run_id : Keeper_tool_plan.Composition_run_id.t
  ; parent_node_id : Keeper_tool_plan.Node_id.t
  ; parent_execution_id : Ids.Execution_id.t
  ; parent_occurrence_tool_use_id : string
  ; result_node_id : Keeper_tool_plan.Node_id.t
  ; args : Yojson.Safe.t
  ; activation : Keeper_skill_activation_ledger.activation
  }

type named_origin = Standalone | Nested of nested_origin

type producer =
  | Prepared
  | Named of
      { tool_name : string
      ; skill_reference : Skill_reference.t
      ; activation : Keeper_skill_activation_recorder.bound_context option
      ; origin : named_origin
      }

type source =
  { keeper_name : string
  ; composition_run_id : Keeper_tool_plan.Composition_run_id.t
  ; draft_reference : Tool_output.artifact_ref
  ; run_reference : Tool_output.artifact_ref
  ; parent_tool_use_id : string
  ; source_turn : int
  ; source_task_id : string option
  ; producer : producer
  }

type source_observation = {
  trace_id : Keeper_id.Trace_id.t option;
  session_id : string option;
  keeper_turn_id : int option;
  answer_source_ids : string list;
}

type completed =
  { execution_id : Ids.Execution_id.t
  ; tool_use_id : string
  ; result : Tool_result.result
  ; result_bytes : int
  ; truncated_to : int option
  }

type recheck = { execution_id : Ids.Execution_id.t; tool_use_id : string }

type launch_invocation =
  { trace_id : string; turn_ref : Ids.Turn_ref.t; keeper_turn_id : int option }

type recheck_launch =
  { execution_id : Ids.Execution_id.t
  ; tool_use_id : string
  ; invocation : launch_invocation
  }

type replay =
  | Dispatch
  | Reuse_completed of completed
  | Recheck_result of recheck
  | Recheck_launch of recheck_launch
  | Recheck_child_submission of recheck

type error =
  | Invalid_source of string
  | Missing_journal
  | Unreadable_journal of string
  | Corrupt_journal of string
  | Source_conflict
  | Queued_request_rejected of string
  | Prior_owner_not_terminal of { request_id : string; reason : string }
  | Ownership_changed
  | Node_identity_conflict of Keeper_tool_plan.Node_id.t
  | Replay_not_proven of Keeper_tool_plan.Node_id.t
  | Attempt_conflict of Keeper_tool_plan.Node_id.t
  | Plan_identity_conflict
  | Draft_unavailable of string
  | Invalid_result of string
  | Invalid_continuation_marker of string
  | Persistence_failed of string

val error_to_json : error -> Yojson.Safe.t

val error_to_string : error -> string

val failure_class : error -> Tool_result.tool_failure_class
