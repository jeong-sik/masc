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
  ; final_agent_core_turn_ordinal : int option
      (** The provider turn whose response this process collected last (the
          [AfterTurn] ordinal). [None] when the run succeeded without
          collecting one here: a durable resume that replays an already-settled
          turn, a pre-first-token preemption (RFC-0441), or a first turn that
          stopped at [InputRequired] before the provider call. Such a run is
          not a failure; it has no provider response of its own to cost. *)
  ; usage : Agent_core.Types.api_usage
  ; usage_reported : bool
  ; usage_scope : Runtime_usage_scope.t
  ; usage_basis : Keeper_usage_resolution.basis
  ; tool_calls : tool_call_detail list
  ; completion_contract_result : Keeper_execution_receipt.completion_contract_result
  ; operator_disposition : operator_disposition option
  ; official_client_settlement : Keeper_official_client_session_store.t option
  ; checkpoint : Agent_core.Checkpoint.t option
  ; cooperative_boundary : Agent_core.Agent.Advanced.tool_boundary option
      (** Exact SDK yield witness retained through finalization. This can be
          present when [checkpoint] is absent (for example a stale save no-op);
          it does not claim that finalization published checkpoint bytes. *)
  ; trace_ref : Agent_core.Raw_trace.run_ref option
  ; run_validation : Agent_core.Raw_trace.run_validation option
  ; stop_reason : Runtime_agent.stop_reason
  ; inference_telemetry : Agent_core.Types.inference_telemetry option
  ; tool_surface : Keeper_agent_tool_surface.tool_surface_metrics
  }

(** What a turn settled: its result, and the two degraded-retry lanes that
    describe it.

    The lanes sit beside the result rather than inside it so an errored turn
    carries them too. That is not symmetry for its own sake — after #37375 gave
    the receipt two typed lanes, the failure path was where the old reading
    ("a lane is pending, so a retry ran") still lived, because a verdict on a
    success value never reaches a turn that failed.

    Both are decided once, in [Keeper_agent_run_receipt.finalize], beside the
    runtime observation that says whether a provider answered. A caller reports
    them; it does not compute them. *)
type turn_settlement =
  { result : (run_result, Agent_core.Error.t) result
  ; degraded_retry_applied : Keeper_error_classify.degraded_retry option
        (** The lane an earlier turn deferred to, when this turn ran it. *)
  ; degraded_retry_deferred : Keeper_error_classify.degraded_retry option
        (** The lane this turn leaves for a later one. *)
  }

(** The settlement of a turn that ended before
    [Keeper_agent_run_receipt.finalize] ran: it wrote no receipt, so it took up
    no deferred lane and left none behind. Both lanes empty here means nothing
    happened, not that the answer is unknown — the distinction the receipt's own
    [unreadable] marker draws on the other side. *)
val not_dispatched : Agent_core.Error.t -> turn_settlement

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
