(** Response, usage-trust, and inference metric helpers for [Keeper_hooks_oas]. *)

val tool_use_failure_metric : string

val record_tool_use_failure : keeper_name:string -> tool_name:string -> unit

val resolve_after_turn_model
  :  keeper_name:string
  -> response:Masc_agent_core.Types.api_response
  -> string

val record_response_content_quality_metric
  :  keeper_name:string
  -> Masc_agent_core.Types.api_response
  -> unit

val classify_usage_trust
  :  ?usage:Masc_agent_core.Types.api_usage
  -> unit
  -> Keeper_usage_trust.t

val record_usage_anomaly_metrics
  :  keeper_name:string -> Keeper_usage_trust.t -> unit

val record_keeper_tool_duration_metric
  :  keeper_name:string
  -> Keeper_hooks_oas_types.tool_execution_summary
  -> unit

val record_llm_tok_s_metrics
  :  telemetry:Masc_agent_core.Types.inference_telemetry option
  -> unit

val record_llm_inference_latency_metric
  :  telemetry:Masc_agent_core.Types.inference_telemetry option
  -> unit

val wall_tokens_per_second
  :  usage_missing:bool
  -> output_tokens:int
  -> telemetry:Masc_agent_core.Types.inference_telemetry option
  -> float option
