(** Cascade config construction and CLI prompt preflight.

    This module intentionally depends on {!Cascade_runner}; keep it out of
    {!Cascade_error_classify} so structured error conversion stays below the
    runner boundary and does not participate in runner/classifier cycles. *)

val config_for_label :
  name:string ->
  model_label:string ->
  system_prompt:string ->
  tools:Agent_sdk.Tool.t list ->
  max_turns:int ->
  max_tokens:int ->
  ?max_input_tokens:int ->
  ?max_cost_usd:float ->
  temperature:float ->
  ?max_idle_turns:int ->
  ?stream_idle_timeout_s:float ->
  ?guardrails:Agent_sdk.Guardrails.t ->
  ?hooks:Agent_sdk.Hooks.hooks ->
  ?context_reducer:Agent_sdk.Context_reducer.t ->
  ?memory:Agent_sdk.Memory.t ->
  ?tool_retry_policy:Agent_sdk.Tool_retry_policy.t ->
  ?enable_thinking:bool ->
  ?compact_ratio:float ->
  ?contract:Masc_mcp_cdal_runtime.Risk_contract.t ->
  ?approval:Agent_sdk.Hooks.approval_callback ->
  description:string option ->
  unit ->
  (Cascade_runner.config, Agent_sdk.Error.sdk_error) result
(** Build a {!Cascade_runner.config} from a model label string.  Resolves
    the provider config and fills in defaults. *)

type cli_prompt_preflight = {
  prompt_bytes : int;
  prompt_tokens : int;
  context_window_tokens : int;
  retry_limit_tokens : int;
  hits_argv_limit : bool;
  hits_context_window : bool;
}
(** RFC-0058 §2.4 — preflight metadata for argv-limited transports. *)

val cli_prompt_preflight :
  config:Cascade_runner.config ->
  goal:string ->
  cli_prompt_preflight option
(** Compute preflight metadata for an argv-limited CLI transport.
    Returns [None] when the provider does not require argv preflight. *)

val with_cli_preflight :  scope:string ->
  config:Cascade_runner.config ->
  goal:string ->
  (unit -> ('a, Agent_sdk.Error.sdk_error) result) ->
  ('a, Agent_sdk.Error.sdk_error) result
(** Wrap an execution with a CLI preflight check. *)
