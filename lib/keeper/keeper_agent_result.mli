(** Keeper Agent.run result surface helpers. *)

type tool_call_detail =
  { tool_name : string
  ; provider : string
  ; outcome : string
      (** Progress-classification label retained for receipt compatibility. *)
  ; execution_outcome : Tool_result.tool_call_outcome
      (** Typed [Tool_result.Ok]/[Error] truth captured at the OAS hook boundary.
          This turn-local delivery signal is intentionally not part of
          [tool_call_detail_to_json]; durable tool-call audit uses
          [Keeper_tool_call_log]. *)
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

type post_turn_memory_job =
  { durable_job : Keeper_memory_job_store.job
  ; tool_results_to_restore : Yojson.Safe.t list
  }
(** Turn-local ownership for a staged durable job. The immutable tool snapshot
    is restored to the Keeper accumulator only when the owning execution
    receipt fails and the non-runnable outbox is aborted. *)

(** Result of a single Agent.run() keeper turn. *)
type run_result =
  { response_text : string
  ; model_used : string
  ; prompt_metrics : Keeper_agent_prompt_metrics.prompt_metrics
  ; ctx_composition : Keeper_agent_prompt_metrics.ctx_composition_metrics
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
  ; post_turn_memory_job : post_turn_memory_job option
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

val tool_names_of_calls : tool_call_detail list -> string list
val tool_names : run_result -> string list
val tool_call_count : run_result -> int

val runtime_lane_label : string
(** Boundary-redacted label used wherever MASC's keeper metrics surface
    exposes a model identity field. OAS owns concrete provider/model
    identity; the keeper-side surface collapses to this single label
    via [Boundary_redaction]. *)
