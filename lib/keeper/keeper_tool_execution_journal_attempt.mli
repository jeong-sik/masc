(** What a worker does with the nodes of its plan: look a node up, attempt it,
    settle it, and submit and accept the child runs it starts.

    [validate_source_plan] checks a plan against the one the source froze.
    [validate_plan] checks a plan for a worker, and
    [validate_refusal_completion] adds the checks of the journal's artifacts,
    nested producer and child links. [lookup] decides what a retry of a node
    does and [launch_recheck] returns the launch to look for again.
    [begin_attempt] records an [attempt] of a node and [settle_attempt]
    records its result. [worker_child_admission] says whether the children of
    some nodes were admitted. [child_origin] gives the origin and the bound
    plan of a child run, [record_child_submission] records the child source an
    attempt submits, [accept_child_submission] records the request that
    accepted it, and [accepted_child_submission] reads the composition it was
    accepted with. [child_result_binding] gives the composition whose result a
    child result node reads.
    [Keeper_tool_execution_journal] includes this module. *)

open Keeper_tool_execution_journal_types
open Keeper_tool_execution_journal_model
open Keeper_tool_execution_journal_continuation

val worker_child_admission : worker -> node_ids:Keeper_tool_plan.Node_id.t list ->
  (child_admission_history, error) result

val validate_source_plan : t -> plan:Keeper_tool_plan.t -> (unit, error) result

val validate_plan : worker -> plan:Keeper_tool_plan.t -> (unit, error) result

val validate_refusal_completion : worker -> plan:Keeper_tool_plan.t -> (unit, error) result

val child_origin : attempt -> plan:Keeper_tool_plan.t ->
  activation:Keeper_skill_activation_ledger.activation ->
  (named_origin * Keeper_tool_plan.t, error) result

val record_child_submission : attempt -> plan:Keeper_tool_plan.t ->
  child_source:source -> (child_submission, error) result

val accept_child_submission : child_submission -> request_id:string -> (unit, error) result

val accepted_child_submission : child_submission ->
  (Keeper_composition_dependency.composition, error) result

val child_result_binding : attempt -> plan:Keeper_tool_plan.t ->
  (Keeper_composition_dependency.composition, error) result

val lookup :
  worker ->
  node_id:Keeper_tool_plan.Node_id.t ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  (replay,
   error)
  result

val launch_recheck :
  worker ->
  node_id:Keeper_tool_plan.Node_id.t ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  execution_id:Ids.Execution_id.t ->
  tool_use_id:string ->
  (recheck_launch option,
   error)
  result

val begin_attempt :
  worker ->
  node_id:Keeper_tool_plan.Node_id.t ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  execution_id:Ids.Execution_id.t ->
  tool_use_id:string ->
  readonly:bool ->
  ?launch_invocation:launch_invocation ->
  unit ->
  (attempt,
   error)
  result

val settle_attempt :
  ?failure_effect_disposition:Tool_result.failure_effect_disposition ->
  ?deferred_kind:Keeper_tool_execution.deferred_kind ->
  attempt ->
  result:Tool_result.result ->
  result_bytes:int ->
  truncated_to:int option ->
  (unit, error) result
