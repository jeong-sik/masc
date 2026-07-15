(** Core execution body for keeper tool OAS handler. *)

(** Execute a keeper tool call with full observability: telemetry,
    failure observation and exception handling. Called from
    [Keeper_tools_oas_handler] after input validation.

    All parameters that were previously captured from the outer
    [make_keeper_tool_handler] closure are passed explicitly. *)
val execute_with_observers
  :  name:string
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> publication_recovery_registry:Fs_compat.publication_recovery_registry
  -> publication_recovery_access:Fs_compat.publication_recovery_access
  -> ctx_snapshot:Keeper_types.working_context
  -> ?turn_sandbox_factory:Keeper_sandbox_factory.t
  -> exec_cache:Masc_exec.Exec_cache.t option
  -> ?search_fn:(unit -> Keeper_tool_execution.t)
  -> ?sw:Eio.Switch.t
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t
  -> ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> ?mcp_session_id:string
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> ?gate_context:(unit -> Keeper_gate.causal_context)
  -> ?gate_grant:Keeper_gate.cycle_grant
  -> input:Yojson.Safe.t
  -> unit
  -> Tool_result.result
