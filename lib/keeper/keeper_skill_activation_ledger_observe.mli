(** The observations a ledger records after an activation: a delivery, an
    async result delivery, an async action and an action.

    [observe_delivery] marks the exact Skill results that a later provider
    request carries, and returns the ids of the matching Skill invocations.
    [observe_async_result_delivery] compares every original activation with
    the expected frame and appends the physical handoff, and
    [observe_async_action] revalidates the stored delivery and original
    activation frame and appends the action. [observe_action] attaches a later
    tool invocation to every delivered Skill id it names, and returns the
    number of activations updated. Each runs under the session lock of the
    trace and appends nothing when it only re-observes what is stored.
    [Keeper_skill_activation_ledger] includes this module. *)

open Keeper_skill_activation_types
open Keeper_skill_activation_ledger_errors
open Keeper_skill_activation_ledger_model

val observe_delivery :
  config:Workspace.config ->
  keeper_name:string ->
  trace_id:Keeper_id.Trace_id.t ->
  turn_ref:Ids.Turn_ref.t ->
  tool_results:tool_result_receipt list ->
  boundary:delivery_boundary ->
  runtime_id:string ->
  delivered_at:string ->
  (t * string list, store_error) result

val observe_async_result_delivery :
  config:Workspace.config -> keeper_name:string -> trace_id:Keeper_id.Trace_id.t ->
  expected_activations:activation list -> Keeper_skill_async_delivery.t ->
  (t * Keeper_skill_async_delivery.t, store_error) result

val observe_async_action :
  config:Workspace.config -> keeper_name:string -> trace_id:Keeper_id.Trace_id.t ->
  Keeper_skill_async_action.t -> (t * Keeper_skill_async_action.t, store_error) result

val observe_action :
  config:Workspace.config ->
  keeper_name:string ->
  trace_id:Keeper_id.Trace_id.t ->
  turn_ref:Ids.Turn_ref.t ->
  active_skill_tool_use_ids:string list ->
  action_identity:action_identity ->
  tool_name:string ->
  runtime_id:string ->
  agent_core_turn:int ->
  observed_at:string ->
  (t * int, store_error) result
