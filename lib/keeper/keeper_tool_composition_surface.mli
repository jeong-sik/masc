(** Materialize validated catalog entries as first-class Agent-Core tools,
    plus the always-present [keeper_plan_execute] tool that runs one
    model-defined inline plan through the same executor. *)

(** Model-visible name of the model-defined plan tool. Registered even when no
    composition catalog exists. *)
val plan_execute_tool_name : string

val plan_execute_input_schema : Yojson.Safe.t
(** The plan's input schema, beside its name because it is the same kind of
    fact: what the tool publishes, not how it is built.

    The four input template shapes are stated here as well as in the
    description. That tells the model the shape; it does not hold it to one --
    [Tool_input_validation.validate_args] reads [oneOf] and [properties] off
    the top-level schema only, and these sit inside [nodes.items]. The refusal
    still comes from [Keeper_tool_plan]. *)

(** Execution-semantics kind (RFC-0386) of the model-defined plan tool:
    [Keeper_tool_descriptor.Batch_plan_tool]. *)
val plan_execute_tool_kind : Keeper_tool_descriptor.tool_kind

val make_tools
  :  ?catalog:Keeper_tool_composition_catalog.t
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> publication_recovery:
       Keeper_publication_recovery_availability.turn_context
  -> ctx_snapshot:Keeper_types.working_context
  -> ?turn_sandbox_factory:Keeper_sandbox_factory.t
  -> ?turn_ctx_cell:Keeper_tool_call_log.turn_ctx_cell
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

module For_testing : sig
  val status_result :
    config:Workspace.config ->
    meta:Keeper_meta_contract.keeper_meta ->
    request_id:string ->
    Tool_result.result

  val cancel_result :
    config:Workspace.config ->
    meta:Keeper_meta_contract.keeper_meta ->
    request_id:string ->
    Tool_result.result
end
