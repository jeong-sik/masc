(** Runtime_agent_checkpoint — checkpoint and idle-detail helpers.

    Keeps side-effecting run helpers separate from the main build/resume/run
    orchestration in {!Runtime_agent}. *)

let build_checkpoint ~session_id ?checkpoint_sidecar (agent : Agent_sdk.Agent.t) =
  match checkpoint_sidecar with
  | None -> Agent_sdk.Agent.checkpoint ~session_id agent
  | Some json ->
      Agent_sdk.Agent_checkpoint.build_checkpoint
        ~session_id ~working_context:json
        ~state:(Agent_sdk.Agent.state agent)
        ~tools:(Agent_sdk.Agent.tools agent)
        ~context:(Agent_sdk.Agent.context agent)
        ~mcp_clients:(Agent_sdk.Agent.options agent).mcp_clients
        ()

let partial_response_of_stop
    ~(session_id : string)
    ~(text : string)
  : Agent_sdk.Types.api_response =
  (* The response model crosses an external boundary and uses the neutral runtime label. *)
  {
    id = session_id;
    model = Boundary_redaction.to_string Boundary_redaction.runtime_model_label;
    stop_reason = Agent_sdk.Types.EndTurn;
    content = [ Agent_sdk.Types.Text text ];
    usage = None;
    telemetry = None;
  }
