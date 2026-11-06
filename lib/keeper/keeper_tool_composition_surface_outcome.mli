(** What the outcome of a composition run decides.

    [failure_returns_to_model] says whether a failed composition goes back to
    the model, and [bind_prepared_result] adds the composition run id and the
    references of the run and draft artifacts to a result.
    [continuation_recovery] says whether a continued node completes the
    original result or holds the original authority;
    [continuation_recovery_of_result] and [node_continuation_recovery] read it
    from a result and from a node, and [combine_recovery] joins two of them.
    [named_admission] says whether a named asynchronous submission is fresh or
    a child of an original attempt.
    [Keeper_tool_composition_surface] includes this module. *)
val failure_returns_to_model :
  plan:Keeper_tool_plan.t ->
  committed:Ids.Execution_id.t list -> Keeper_tool_plan_executor.failure -> bool

val bind_prepared_result :
  composition_run_id:Keeper_tool_plan.Composition_run_id.t ->
  run_reference:Tool_output.artifact_ref ->
  draft_reference:Tool_output.artifact_ref ->
  Tool_result.result -> Tool_result.result

type named_admission =
  | Fresh_named of Keeper_skill_activation_recorder.t option
  | Original_child of
      { attempt : Keeper_tool_execution_journal.attempt
      ; parent_plan : Keeper_tool_plan.t
      ; origin : Keeper_tool_execution_journal.named_origin
      ; context : Keeper_skill_activation_recorder.bound_context
      }

type continuation_recovery =
  | Complete_original_result
  | Hold_original_authority of string

val continuation_recovery_of_result :
  effect_disposition:Tool_result.failure_effect_disposition option ->
  Tool_result.result -> continuation_recovery

val node_continuation_recovery :
  Keeper_tool_plan_executor.node_result -> continuation_recovery

val combine_recovery :
  continuation_recovery -> continuation_recovery -> continuation_recovery
