(** The resumption of an interrupted asynchronous composition.

    [resume_continuation_with] checks that a continuation still belongs to the
    Keeper and to an admitted producer, defers while the results of its
    original dependencies are not ready, and submits the run again. When the
    original admissions call for a refusal it submits that refusal instead.
    [on_refusal_accepted] and [observe_refusal_settlement] observe the request
    that carries a refusal. [resume_continuation] is [resume_continuation_with]
    without those two observers.
    [Keeper_tool_composition_surface] includes this module. *)
open Keeper_tool_composition_surface_schema

val resume_continuation_with :
  ?on_recovery_held:(request_id:string -> reason:string -> unit) ->
  ?owner_metadata_refusal:owner_metadata_refusal ->
  ?on_refusal_accepted:(string -> (unit, string) result) ->
  ?observe_refusal_settlement:(Keeper_msg_async.worker_settlement ->
                               unit) ->
  capability_surface:Keeper_capability_surface.t ->
  continuation:Keeper_tool_execution_journal.continuation ->
  config:Workspace_utils_backend_setup.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  publication_recovery:Keeper_publication_recovery_availability.turn_context ->
  ctx_snapshot:Keeper_types.working_context ->
  turn_context:Keeper_tool_call_log_context.turn_context ->
  invocation:Agent_core_base.Tool_contract.Invocation.t ->
  ?clock:float Eio.Time.clock_ty Eio.Time.clock_base ->
  unit -> Tool_result.result

val resume_continuation :
  ?on_recovery_held:(request_id:string -> reason:string -> unit) ->
  ?owner_metadata_refusal:owner_metadata_refusal ->
  capability_surface:Keeper_capability_surface.t ->
  continuation:Keeper_tool_execution_journal.continuation ->
  config:Workspace_utils_backend_setup.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  publication_recovery:Keeper_publication_recovery_availability.turn_context ->
  ctx_snapshot:Keeper_types.working_context ->
  turn_context:Keeper_tool_call_log_context.turn_context ->
  invocation:Agent_core_base.Tool_contract.Invocation.t ->
  ?clock:float Eio.Time.clock_ty Eio.Time.clock_base ->
  unit -> Tool_result.result
