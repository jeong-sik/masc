module Plan = Keeper_tool_plan

type nested_origin =
  { parent_run_id : Plan.Composition_run_id.t
  ; parent_node_id : Plan.Node_id.t
  ; parent_execution_id : Ids.Execution_id.t
  ; parent_occurrence_tool_use_id : string
  ; result_node_id : Plan.Node_id.t
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
  ; composition_run_id : Plan.Composition_run_id.t
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
  | Node_identity_conflict of Plan.Node_id.t
  | Replay_not_proven of Plan.Node_id.t
  | Attempt_conflict of Plan.Node_id.t
  | Plan_identity_conflict
  | Draft_unavailable of string
  | Invalid_result of string
  | Invalid_continuation_marker of string
  | Persistence_failed of string

let error_to_json error =
  let kind, details = match error with
    | Invalid_source detail -> "invalid_source", ["detail", `String detail]
    | Missing_journal -> "missing_journal", []
    | Unreadable_journal detail -> "unreadable_journal", ["detail", `String detail]
    | Corrupt_journal detail -> "corrupt_journal", ["detail", `String detail]
    | Source_conflict -> "source_conflict", []
    | Queued_request_rejected detail -> "queued_request_rejected", ["detail", `String detail]
    | Prior_owner_not_terminal {request_id; reason} ->
      "prior_owner_not_terminal", ["request_id", `String request_id; "detail", `String reason]
    | Ownership_changed -> "ownership_changed", []
    | Node_identity_conflict node -> "node_identity_conflict", ["node_id", `String (Plan.Node_id.to_string node)]
    | Replay_not_proven node -> "replay_not_proven", ["node_id", `String (Plan.Node_id.to_string node)]
    | Attempt_conflict node -> "attempt_conflict", ["node_id", `String (Plan.Node_id.to_string node)]
    | Plan_identity_conflict -> "plan_identity_conflict", []
    | Draft_unavailable detail -> "draft_unavailable", ["detail", `String detail]
    | Invalid_result detail -> "invalid_result", ["detail", `String detail]
    | Invalid_continuation_marker detail -> "invalid_continuation_marker", ["detail", `String detail]
    | Persistence_failed detail -> "persistence_failed", ["detail", `String detail]
  in
  `Assoc (("kind", `String kind) :: details)

let error_to_string error = Yojson.Safe.to_string (error_to_json error)

let failure_class = function
  | Invalid_source _ | Source_conflict | Queued_request_rejected _
  | Prior_owner_not_terminal _ | Ownership_changed | Node_identity_conflict _
  | Replay_not_proven _ | Attempt_conflict _ | Plan_identity_conflict -> Tool_result.Workflow_rejection
  | Missing_journal | Unreadable_journal _ | Corrupt_journal _
  | Invalid_result _ | Persistence_failed _ | Draft_unavailable _ -> Tool_result.Runtime_failure
  | Invalid_continuation_marker _ -> Tool_result.Runtime_failure
