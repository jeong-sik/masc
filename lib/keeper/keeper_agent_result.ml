(** Keeper Agent.run result surface helpers. *)

open Keeper_agent_prompt_metrics
open Keeper_agent_tool_surface

type tool_call_detail =
  { tool_name : string
  ; provider : string
  ; outcome : string
      (** Progress-classification label retained for receipt compatibility. *)
  ; execution_outcome : Tool_result.tool_call_outcome
      (** Typed [Tool_result.Ok]/[Error] truth captured at the OAS hook boundary.
          Turn-local only; durable audit is written by [Keeper_tool_call_log]. *)
  ; typed_outcome : Keeper_tool_outcome.t option
  ; latency_ms : float
  ; task_id : string option
  ; route_evidence : Yojson.Safe.t option
  ; input_fingerprint : string option
  ; output_fingerprint : string option
  }

type operator_disposition =
  { disposition : Keeper_execution_receipt.operator_disposition_kind
  ; reason : Keeper_execution_receipt.operator_disposition_reason
  }

let tool_call_detail_to_json (detail : tool_call_detail) =
  let route_evidence_field =
    match detail.route_evidence with
    | Some evidence -> [ ("route_evidence", evidence) ]
    | None -> []
  in
  let task_id_field =
    match detail.task_id with
    | Some task_id -> [ ("task_id", `String task_id) ]
    | None -> []
  in
  let typed_outcome_field =
    match detail.typed_outcome with
    | Some outcome -> [ ("typed_outcome", Keeper_tool_outcome.to_json outcome) ]
    | None -> []
  in
  let input_fingerprint_field =
    match detail.input_fingerprint with
    | Some fingerprint -> [ ("input_fingerprint", `String fingerprint) ]
    | None -> []
  in
  let output_fingerprint_field =
    match detail.output_fingerprint with
    | Some fingerprint -> [ ("output_fingerprint", `String fingerprint) ]
    | None -> []
  in
  `Assoc
    ([
       ("tool_name", `String detail.tool_name);
       ("provider", `String detail.provider);
       ("outcome", `String detail.outcome);
       ("latency_ms", `Float detail.latency_ms);
     ]
     @ typed_outcome_field
     @ task_id_field
     @ input_fingerprint_field
     @ output_fingerprint_field
     @ route_evidence_field)

let tool_names_of_calls (tool_calls : tool_call_detail list) : string list =
  tool_calls
  |> List.map (fun detail -> Keeper_tool_resolution.canonical_tool_name detail.tool_name)
;;

(** Result of a single Agent.run() keeper turn. *)
type run_result =
  { response_text : string
  ; model_used : string
  ; prompt_metrics : prompt_metrics
  ; ctx_composition : ctx_composition_metrics
  ; runtime_observation : Runtime_observation.runtime_observation option
  ; turn_count : int
  ; usage : Agent_sdk.Types.api_usage
  ; usage_reported : bool
  ; tool_calls : tool_call_detail list
  ; completion_contract_result : Keeper_execution_receipt.completion_contract_result
  ; operator_disposition : operator_disposition option
  ; checkpoint : Agent_sdk.Checkpoint.t option
  ; trace_ref : Agent_sdk.Raw_trace.run_ref option
  ; run_validation : Agent_sdk.Raw_trace.run_validation option
  ; stop_reason : Runtime_agent.stop_reason
  ; inference_telemetry : Agent_sdk.Types.inference_telemetry option
  ; tool_surface : tool_surface_metrics
  ; pre_dispatch_compacted : bool
  ; pre_dispatch_compaction_trigger : string option
  ; pre_dispatch_compaction_before_tokens : int option
  ; pre_dispatch_compaction_after_tokens : int option
  }

let tool_names (result : run_result) = tool_names_of_calls result.tool_calls
let tool_call_count (result : run_result) = List.length result.tool_calls

(* RFC-0132 PR-2: agent-result surface label = external boundary; redact via SSOT. *)
let runtime_lane_label = Boundary_redaction.to_string Boundary_redaction.runtime_lane_label
