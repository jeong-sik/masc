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
  ; pre_dispatch_compacted : bool
  ; pre_dispatch_compaction_trigger : string option
  ; pre_dispatch_compaction_before_tokens : int option
  ; pre_dispatch_compaction_after_tokens : int option
  }

val tool_call_detail_to_json : tool_call_detail -> Yojson.Safe.t
(** Serialize a tool call detail to JSON. Reached via the
    [include Keeper_agent_result] chain in [Keeper_agent_run], where
    the public surface is exposed under [Keeper_agent_run.mli]. *)

val surface_model_used : run_result -> string
(** Legacy MASC-facing model label helper. Returns the neutral runtime
    lane label; OAS owns concrete provider/model identity. Reached via
    [Keeper_agent_run.surface_model_used] through the include chain;
    live callers: keeper_unified_metrics_snapshot,
    keeper_unified_metrics_result, keeper_unified_turn_success. *)

val surface_resolved_model_id : run_result -> string
(** Legacy MASC-facing resolved model helper. Returns the neutral
    runtime lane label; OAS owns concrete provider/model identity.
    Reached via [Keeper_agent_run.surface_resolved_model_id]. *)

