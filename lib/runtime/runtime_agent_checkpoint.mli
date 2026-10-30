(** Runtime_agent_checkpoint — checkpoint and idle-detail helpers used by
    {!Runtime_agent}.

    Keeps side-effecting run helpers separate from the main
    build / resume / run orchestration so the orchestration
    module stays focused on Eio fiber composition.

    The interface pins the Agent Core checkpoint and response contracts at the
    MASC runtime boundary. *)

val build_checkpoint :
  session_id:string ->
  ?checkpoint_sidecar:Yojson.Safe.t ->
  Agent_core.Agent.t ->
  Agent_core.Checkpoint.t
(** Build an [Agent_core.Checkpoint.t] for [agent].

    Uses the Agent's own checkpoint capture, including its pending input
    ownership. A supplied [checkpoint_sidecar] becomes [working_context]
    without rebuilding or dropping the Agent's current request proof. *)

val partial_response_of_stop :
  session_id:string ->
  text:string ->
  Agent_core.Types.api_response
(** Synthesise an [Agent_core.Types.api_response] for the early-stop
    case (e.g. operator-side cancel before the model finishes).
    [stop_reason = EndTurn], single [Text] content block, no
    usage / telemetry. The emitted response model is the neutral [runtime]
    lane; Agent Core owns concrete provider/model identity. *)
