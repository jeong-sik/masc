(** Worker_oas — OAS-backed worker execution.

    Builds OAS agents, runs workers via OAS Agent.run, handles checkpoints,
    tool tracking hooks, and execution scope gating.

    @since 0.1.0 *)

(** {1 Agent Construction} *)

val build_agent :
  net:([ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t) ->
  meta:Worker_container_types.worker_container_meta ->
  provider:Agent_sdk.Provider.config ->
  system_prompt:string ->
  tools:Agent_sdk.Tool.t list ->
  hooks:Agent_sdk.Hooks.hooks ->
  raw_trace:Agent_sdk.Raw_trace.t ->
  heartbeat_callbacks:Agent_sdk.Agent.periodic_callback list ->
  ?gate_config:Eval_gate.gate_config ->
  ?context_injector:Agent_sdk.Hooks.context_injector ->
  ?context:Agent_sdk.Context.t ->
  ?approval:Agent_sdk.Hooks.approval_callback ->
  unit ->
  (Agent_sdk.Agent.t, string) result

(** {1 Tool Tracking} *)

val make_tool_tracking_hooks :
  ?gate_config:Eval_gate.gate_config ->
  ?context:Agent_sdk.Context.t ->
  unit ->
  string list ref * Agent_sdk.Hooks.hooks

(** {1 Gate Configuration} *)

val default_gate_config :
  unit -> Eval_gate.gate_config

(** {1 Worker Execution} *)

val run_worker_via_oas :
  sw:Eio.Switch.t ->
  net:([ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t) ->
  base_path:string ->
  auth_token:string option ->
  meta:Worker_container_types.worker_container_meta ->
  provider:Agent_sdk.Provider.config ->
  system_prompt:string ->
  prompt:string ->
  tools:Agent_sdk.Tool.t list ->
  raw_trace:Agent_sdk.Raw_trace.t ->
  ?gate_config:Eval_gate.gate_config ->
  ?contract:Masc_mcp_cdal_runtime.Risk_contract.t ->
  ?worker_run_id:string ->
  unit ->
  (Worker_container_types.run_result, string) result

val resume_worker_via_oas :
  sw:Eio.Switch.t ->
  net:([ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t) ->
  base_path:string ->
  auth_token:string option ->
  meta:Worker_container_types.worker_container_meta ->
  checkpoint:Agent_sdk.Checkpoint.t ->
  prompt:string ->
  tools:Agent_sdk.Tool.t list ->
  raw_trace:Agent_sdk.Raw_trace.t ->
  ?contract:Masc_mcp_cdal_runtime.Risk_contract.t ->
  ?worker_run_id:string ->
  ?approval:Agent_sdk.Hooks.approval_callback ->
  unit ->
  (Worker_container_types.run_result, string) result

(** {1 Checkpoint Helpers} *)

val resume_model_id_of_checkpoint :
  Worker_container_types.worker_container_meta ->
  Agent_sdk.Checkpoint.t ->
  string
