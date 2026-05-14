(** Keeper Agent.run result surface helpers. *)

open Keeper_agent_prompt_metrics
open Keeper_agent_tool_surface

type tool_call_detail =
  { tool_name : string
  ; provider : string
  ; outcome : string
  ; latency_ms : float
  ; route_evidence : Yojson.Safe.t option
  }

let tool_call_detail_to_json (detail : tool_call_detail) =
  let route_evidence_field =
    match detail.route_evidence with
    | Some evidence -> [ ("route_evidence", evidence) ]
    | None -> []
  in
  `Assoc
    ([
       ("tool_name", `String detail.tool_name);
       ("provider", `String detail.provider);
       ("outcome", `String detail.outcome);
       ("latency_ms", `Float detail.latency_ms);
     ]
     @ route_evidence_field)

(** Result of a single Agent.run() keeper turn. *)
type run_result =
  { response_text : string
  ; model_used : string
  ; prompt_metrics : prompt_metrics
  ; ctx_composition : ctx_composition_metrics
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
  ; tool_surface : tool_surface_metrics
  }

let nonempty_trimmed raw =
  let trimmed = String.trim raw in
  if trimmed = "" then None else Some trimmed

let runtime_lane_label = "runtime"

let surface_model_used (_result : run_result) : string = runtime_lane_label

let surface_resolved_model_id (_result : run_result) : string =
  runtime_lane_label
