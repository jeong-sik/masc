(** Keeper Agent.run result surface helpers. *)

type tool_call_detail =
  { tool_name : string
  ; provider : string
  ; outcome : string
  ; typed_outcome : Keeper_tool_outcome.t option
  ; latency_ms : float
  ; task_id : string option
  ; route_evidence : Yojson.Safe.t option
  }

(** Result of a single Agent.run() keeper turn. *)
type run_result =
  { response_text : string
  ; model_used : string
  ; prompt_metrics : Keeper_agent_prompt_metrics.prompt_metrics
  ; ctx_composition : Keeper_agent_prompt_metrics.ctx_composition_metrics
  ; cascade_observation : Cascade_legacy_runner.cascade_observation option
  ; turn_count : int
  ; tool_calls_made : int
  ; usage : Agent_sdk.Types.api_usage
  ; usage_reported : bool
  ; tools_used : string list
  ; tool_calls : tool_call_detail list
  ; checkpoint : Agent_sdk.Checkpoint.t option
  ; proof : Masc_mcp_cdal_runtime.Cdal_proof.t option
  ; trace_ref : Agent_sdk.Raw_trace.run_ref option
  ; run_validation : Agent_sdk.Raw_trace.run_validation option
  ; stop_reason : Cascade_runner.stop_reason
  ; inference_telemetry : Agent_sdk.Types.inference_telemetry option
  ; tool_surface : Keeper_agent_tool_surface.tool_surface_metrics
  }

