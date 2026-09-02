(** Keeper Agent.run result surface helpers. *)

type tool_call_detail =
  { tool_name : string
  ; provider : string
  ; execution_outcome : Tool_result.tool_call_outcome
      (** Typed [Tool_result.Ok]/[Error] truth captured at the AGENT_CORE hook boundary.
          Durable tool-call audit uses [Keeper_tool_call_log].

          [tool_call_detail_to_json] renders this into the receipt's ["outcome"]
          string via [Tool_result.string_of_tool_call_outcome]. That string used
          to be a second field derived from the same success bool, and it was
          the one every reader consulted. *)
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

(** Result of a single Agent.run() keeper turn. *)
type run_result =
  { response_text : string
  ; turn_outcome : Keeper_turn_outcome.t
  ; terminal_effect_receipt : Keeper_tool_execution.terminal_effect_receipt option
  ; model_used : string
  ; runtime_id : string
  ; max_context : int
  ; prompt_metrics : Keeper_agent_prompt_metrics.prompt_metrics
  ; ctx_composition : Keeper_agent_prompt_metrics.ctx_composition_metrics
  ; runtime_observation : Runtime_observation.runtime_observation option
  ; turn_count : int
  ; final_agent_core_turn_ordinal : int
  ; usage : Agent_core.Types.api_usage
  ; usage_reported : bool
  ; usage_scope : Runtime_usage_scope.t
  ; usage_basis : Keeper_usage_resolution.basis
  ; tool_calls : tool_call_detail list
  ; completion_contract_result : Keeper_execution_receipt.completion_contract_result
  ; operator_disposition : operator_disposition option
  ; checkpoint : Agent_core.Checkpoint.t option
  ; trace_ref : Agent_core.Raw_trace.run_ref option
  ; run_validation : Agent_core.Raw_trace.run_validation option
  ; stop_reason : Runtime_agent.stop_reason
  ; inference_telemetry : Agent_core.Types.inference_telemetry option
  ; tool_surface : Keeper_agent_tool_surface.tool_surface_metrics
  }

val tool_call_detail_to_json : tool_call_detail -> Yojson.Safe.t
(** Serialize a tool call detail to JSON. Reached via the
    [include Keeper_agent_result] chain in [Keeper_agent_run], where
    the public surface is exposed under [Keeper_agent_run.mli]. *)

val tool_names_of_calls : tool_call_detail list -> string list
val tool_names : run_result -> string list
val tool_call_count : run_result -> int

val runtime_lane_label : string
(** Boundary-redacted label used wherever MASC's keeper metrics surface
    exposes a model identity field. AGENT_CORE owns concrete provider/model
    identity; the keeper-side surface collapses to this single label
    via [Boundary_redaction]. *)
