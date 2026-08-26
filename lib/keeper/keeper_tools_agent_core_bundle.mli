(** Tool bundle assembly for keeper Agent Core execution. *)

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
  -> ?skill_catalog:Keeper_skill_catalog.t
       (** Skills loaded for this turn. Composition skills materialize as
           [keeper_compose_<name>] tools beside the catalog's own entries;
           an absent or empty catalog adds nothing. *)
  -> ?identity_tools:Agent_core.Tool.t list
       (** What the work services this Keeper is attached to offer, from
           {!Keeper_identity_tools.for_turn}. Passed in rather than read
           here: the caller is the part that also has to tell the tool-name
           projection about them, and computing them in two places is how
           the two would come to disagree. Absent or empty adds nothing. *)
  -> ?composition_plan_index:Keeper_tool_composition_plan_index.t
       (** Turn-local approval state. Composition plans are recorded here
           while their tools are materialized. *)
  -> ?turn_ctx_cell:Keeper_tool_call_log.turn_ctx_cell
  -> unit
  -> Keeper_tools_agent_core.tool_bundle

(** Convenience over [make_tool_bundle] returning only [.tools]. *)
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

module For_testing : sig
  val initial_terminal_effect_state :
    Keeper_tools_agent_core.gate_replay_delivery option ->
    Keeper_tools_agent_core.terminal_effect_state

  val terminal_externalization_failure :
    Keeper_tools_agent_core.terminal_effect_state ->
    Tool_bridge.externalization_error ->
    Keeper_tools_agent_core.terminal_effect_failure option
end
