(** Keeper_tools_agent_core_handler — Tool handler factory for Agent.run().

    Skeleton module: validation and dispatch. The heavy execution body lives
    in [Keeper_tools_agent_core_handler_exec]; telemetry helpers live in
    [Keeper_tools_agent_core_handler_telemetry].  Bundle assembly lives in
    [Keeper_tools_agent_core_bundle].

    @since P1 extraction *)

(** Build the per-tool handler closure used by both internal and
    alias tool entries. The closure dispatches via
    [execute_keeper_tool_call_with_outcome] using [~name] as the
    INTERNAL tool name (telemetry SSOT). [~input_schema] is the
    internal tool schema used for pre-execution validation. Descriptor-backed
    callers pass [?prepare_input] so validation and translation follow the
    descriptor's typed policy before dispatch. *)
val make_keeper_tool_handler
  :  name:string
  -> ?descriptor:Keeper_tool_descriptor.t
  -> ?model_name:string
  -> input_schema:Yojson.Safe.t
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
  -> ?observe_execution_evidence:
       (failure_effect_disposition:Tool_result.failure_effect_disposition option
        -> deferred_kind:Keeper_tool_execution.deferred_kind option
        -> unit)
  -> ?on_completed:
       (Keeper_tool_execution.terminal_effect_receipt option -> unit)
  -> ?on_deferred:(unit -> unit)
  -> ?on_external_effect_deferred:(unit -> unit)
  -> ?on_failed:(Keeper_tools_agent_core.terminal_effect_failure -> unit)
  -> ?prepare_input:
       (Yojson.Safe.t -> (Yojson.Safe.t, Tool_result.result) result)
  -> unit
  -> ?agent_core_invocation:Agent_core.Tool_contract.Invocation.t
  -> Yojson.Safe.t
  -> Tool_result.result
