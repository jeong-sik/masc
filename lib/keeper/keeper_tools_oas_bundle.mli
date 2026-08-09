(** Tool bundle assembly for keeper OAS execution. *)

val make_tool_bundle_for_descriptors
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> publication_recovery:
       Keeper_publication_recovery_availability.turn_context
  -> ctx_snapshot:Keeper_types.working_context
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> ?gate_context:Keeper_gate_causal_context.t
  -> ?hitl_resolution:Keeper_event_queue.hitl_resolution
  -> descriptors:Keeper_tool_descriptor.t list
  -> unit
  -> Keeper_tools_oas.tool_bundle
(** Materialize an already-authorized typed descriptor set through the same
    validation, Gate, dispatch, receipt, and cleanup path as a Keeper turn.
    The caller owns the closed authority policy that selected [descriptors]. *)

(** Build the keeper's full [tool_bundle]: internal tools +
    alias-registered (public name) tools that translate input to
    internal payloads. The cleanup thunk releases per-turn sandbox
    runtimes (Docker case). *)
val make_tool_bundle
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> publication_recovery:
       Keeper_publication_recovery_availability.turn_context
  -> ctx_snapshot:Keeper_types.working_context
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> ?gate_context:Keeper_gate_causal_context.t
  -> ?hitl_resolution:Keeper_event_queue.hitl_resolution
  -> unit
  -> Keeper_tools_oas.tool_bundle

(** Convenience over [make_tool_bundle] returning only [.tools]. *)
val make_tools
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> publication_recovery:
       Keeper_publication_recovery_availability.turn_context
  -> ctx_snapshot:Keeper_types.working_context
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> unit
  -> Agent_sdk.Tool.t list

module For_testing : sig
  val is_terminal_effect_handler : Keeper_tool_descriptor.runtime_handler -> bool

  val terminal_externalization_failure :
    Keeper_tools_oas.terminal_effect_state ->
    Tool_bridge.externalization_error ->
    Keeper_tools_oas.terminal_effect_failure option
end
