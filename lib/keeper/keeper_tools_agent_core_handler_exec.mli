(** Core execution body for keeper tool AGENT_CORE handler. *)

type execution_result =
  { tool_result : Tool_result.result
  ; failure_effect_disposition : Tool_result.failure_effect_disposition option
  ; deferred_kind : Keeper_tool_execution.deferred_kind option
  ; terminal_effect_receipt : Keeper_tool_execution.terminal_effect_receipt option
  }

(** Execute a keeper tool call with full observability: telemetry,
    failure observation and exception handling. Called from
    [Keeper_tools_agent_core_handler] after input validation.

    All parameters that were previously captured from the outer
    [make_keeper_tool_handler] closure are passed explicitly. *)
val execute_with_observers
  :  capability_surface:Keeper_capability_surface.t
  -> name:string
  -> ?descriptor:Keeper_tool_descriptor.t
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> publication_recovery:
       Keeper_publication_recovery_availability.turn_context
  -> ctx_snapshot:Keeper_types.working_context
  -> ?turn_sandbox_factory:Keeper_sandbox_factory.t
  -> ?sw:Eio.Switch.t
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t
  -> ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> ?mcp_session_id:string
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> ?gate_context:(unit -> Keeper_gate.causal_context)
  -> ?gate_grant:Keeper_gate.cycle_grant
  -> ?agent_core_invocation:Agent_core.Tool_contract.Invocation.t
  -> input:Yojson.Safe.t
  -> unit
  -> execution_result

val execute_with_observers_from_meta
  :  name:string
  -> ?descriptor:Keeper_tool_descriptor.t
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> publication_recovery:
       Keeper_publication_recovery_availability.turn_context
  -> ctx_snapshot:Keeper_types.working_context
  -> ?turn_sandbox_factory:Keeper_sandbox_factory.t
  -> ?sw:Eio.Switch.t
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t
  -> ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> ?mcp_session_id:string
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> ?gate_context:(unit -> Keeper_gate.causal_context)
  -> ?gate_grant:Keeper_gate.cycle_grant
  -> ?agent_core_invocation:Agent_core.Tool_contract.Invocation.t
  -> input:Yojson.Safe.t
  -> unit
  -> execution_result
(** Explicit compatibility path for direct handler tests without a Keeper
    turn. Production bundles never call this function. *)
