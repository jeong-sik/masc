(** Worker_oas — OAS-backed worker execution.

    Builds OAS agents, runs workers via OAS Agent.run, handles checkpoints,
    tool tracking hooks, and execution scope gating.

    @since 0.1.0 *)

(** {1 Agent Construction} *)

val build_agent :
  net:([ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t) ->
  meta:Worker_container_types.worker_container_meta ->
  provider:Oas.Provider.config ->
  system_prompt:string ->
  tools:Oas.Tool.t list ->
  hooks:Oas.Hooks.hooks ->
  raw_trace:Oas.Raw_trace.t ->
  heartbeat_callbacks:Oas.Agent.periodic_callback list ->
  ?gate_config:Eval_gate.gate_config ->
  ?context_injector:Oas.Hooks.context_injector ->
  ?context:Oas.Context.t ->
  ?approval:Oas.Hooks.approval_callback ->
  unit ->
  (Oas.Agent.t, string) result

(** {1 Tool Tracking} *)

val make_tool_tracking_hooks :
  ?gate_config:Eval_gate.gate_config ->
  ?context:Oas.Context.t ->
  unit ->
  string list ref * Oas.Hooks.hooks

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
  provider:Oas.Provider.config ->
  system_prompt:string ->
  prompt:string ->
  tools:Oas.Tool.t list ->
  raw_trace:Oas.Raw_trace.t ->
  ?gate_config:Eval_gate.gate_config ->
  ?contract:Oas.Risk_contract.t ->
  ?worker_run_id:string ->
  unit ->
  (Worker_container_types.run_result, string) result

val resume_worker_via_oas :
  sw:Eio.Switch.t ->
  net:([ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t) ->
  base_path:string ->
  auth_token:string option ->
  meta:Worker_container_types.worker_container_meta ->
  checkpoint:Oas.Checkpoint.t ->
  prompt:string ->
  tools:Oas.Tool.t list ->
  raw_trace:Oas.Raw_trace.t ->
  ?contract:Oas.Risk_contract.t ->
  ?worker_run_id:string ->
  ?approval:Oas.Hooks.approval_callback ->
  unit ->
  (Worker_container_types.run_result, string) result

(** {1 Checkpoint Helpers} *)

val resume_model_id_of_checkpoint :
  Worker_container_types.worker_container_meta ->
  Oas.Checkpoint.t ->
  string
