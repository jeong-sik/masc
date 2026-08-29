(** Tool bundle assembly for keeper Agent Core execution. *)

(** Build the keeper's full [tool_bundle]: internal tools +
    alias-registered (public name) tools that translate input to
    internal payloads. The cleanup thunk releases per-turn sandbox
    runtimes (Docker case). *)
val make_tool_bundle_for_capability_surface
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> publication_recovery:
       Keeper_publication_recovery_availability.turn_context
  -> ctx_snapshot:Keeper_types.working_context
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> ?gate_context:Keeper_gate_causal_context.t
  -> ?hitl_resolution:Keeper_event_queue.hitl_resolution
  -> ?identity_surface:Keeper_identity_tool_search.surface
  -> ?composition_plan_index:Keeper_tool_composition_plan_index.t
  -> ?skill_activation_context:Keeper_skill_activation_recorder.t
  -> ?turn_ctx_cell:Keeper_tool_call_log.turn_ctx_cell
  -> capability_surface:Keeper_capability_surface.t
  -> unit
  -> Keeper_tools_agent_core.tool_bundle
(** Build a bundle from the immutable Tool and Skill authority frozen by the
    turn caller. Named compositions receive its exact descriptor list, so they
    cannot widen the configured Tool Group surface. *)

module For_testing : sig
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
    -> ?skill_catalog:Keeper_skill_catalog.t
    -> ?turn_ctx_cell:Keeper_tool_call_log.turn_ctx_cell
    -> unit
    -> Keeper_tools_agent_core.tool_bundle

  val make_tools
    :  config:Workspace.config
    -> meta:Keeper_meta_contract.keeper_meta
    -> publication_recovery:
         Keeper_publication_recovery_availability.turn_context
    -> ctx_snapshot:Keeper_types.working_context
    -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
    -> ?skill_catalog:Keeper_skill_catalog.t
    -> ?turn_ctx_cell:Keeper_tool_call_log.turn_ctx_cell
    -> unit
    -> Agent_core.Tool.t list

  val make_tools_for_descriptors
    :  config:Workspace.config
    -> meta:Keeper_meta_contract.keeper_meta
    -> publication_recovery:
         Keeper_publication_recovery_availability.turn_context
    -> ctx_snapshot:Keeper_types.working_context
    -> descriptors:Keeper_tool_descriptor.t list
    -> ?skill_catalog:Keeper_skill_catalog.t
    -> unit
    -> Agent_core.Tool.t list
  (** Test seam for a closed per-turn descriptor set. Production obtains the
*)

  val initial_terminal_effect_state :
    Keeper_tools_agent_core.gate_replay_delivery option ->
    Keeper_tools_agent_core.terminal_effect_state

  val terminal_externalization_failure :
    Keeper_tools_agent_core.terminal_effect_state ->
    Tool_bridge.externalization_error ->
    Keeper_tools_agent_core.terminal_effect_failure option
end
