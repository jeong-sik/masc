(** Materialize validated catalog entries as first-class Agent-Core tools. *)

val make_tools
  :  catalog:Keeper_tool_composition_catalog.t
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> publication_recovery:
       Keeper_publication_recovery_availability.turn_context
  -> ctx_snapshot:Keeper_types.working_context
  -> ?turn_sandbox_factory:Keeper_sandbox_factory.t
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> ?gate_context:(unit -> Keeper_gate.causal_context)
  -> ?gate_grant:Keeper_gate.cycle_grant
  -> ?record_gate_result:
       (operation:string -> input:Yojson.Safe.t -> Tool_result.result -> unit)
  -> ?on_completed:(Keeper_tool_execution.terminal_effect_receipt option -> unit)
  -> ?on_deferred:(unit -> unit)
  -> ?on_external_effect_deferred:(unit -> unit)
  -> ?on_failed:(Keeper_tools_agent_core.terminal_effect_failure -> unit)
  -> ?on_externalization_error:(Tool_bridge.externalization_error -> unit)
  -> unit
  -> Agent_core.Tool.t list
