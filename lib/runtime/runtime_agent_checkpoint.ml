(** Runtime_agent_checkpoint — checkpoint and idle-detail helpers.

    Keeps side-effecting run helpers separate from the main build/resume/run
    orchestration in {!Runtime_agent}. *)

let build_checkpoint ~session_id ?checkpoint_sidecar (agent : Agent_core.Agent.t) =
  Agent_core.Agent.checkpoint ~session_id ?working_context:checkpoint_sidecar agent

let partial_response_of_stop
    ~(session_id : string)
    ~(text : string)
  : Agent_core.Types.api_response =
  (* The response model crosses an external boundary and uses the neutral runtime label. *)
  {
    id = session_id;
    model = Boundary_redaction.to_string Boundary_redaction.runtime_model_label;
    stop_reason = Agent_core.Types.EndTurn;
    content = [ Agent_core.Types.Text text ];
    usage = None;
    telemetry = None;
  }
