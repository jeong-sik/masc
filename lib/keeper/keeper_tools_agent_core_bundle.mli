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
  -> ?task_instruction_skills:(Skill_reference.t * string * string) list
       (** Exact Task-selected Skill bodies resolved from this turn's frozen
           snapshot. These may include shadowed or disable-model-invocation
           entries without changing global Skill discovery. *)
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
  -> ?task_instruction_skills:(Skill_reference.t * string * string) list
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
