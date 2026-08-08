(** Runtime_oas_checkpoint — checkpoint and
    idle-detail helpers extracted from {!Runtime_agent}.

    Keeps side-effecting run helpers separate from the main
    build / resume / run orchestration so the orchestration
    module stays focused on Eio fiber composition.

    No internal helpers are hidden; the .mli pins each entry
    point's contract so a future refactor of the OAS Agent
    surface (Provider / Checkpoint / Types renames) fails here
    instead of at every call site in {!Runtime_agent}. *)

val build_checkpoint :
  session_id:string ->
  ?checkpoint_sidecar:Yojson.Safe.t ->
  Agent_sdk.Agent.t ->
  Agent_sdk.Checkpoint.t
(** Build an [Agent_sdk.Checkpoint.t] for [agent].

    When [checkpoint_sidecar] is omitted, delegates to
    [Agent_sdk.Agent.checkpoint ~session_id agent] (the SDK's own
    checkpoint capture).

    When [checkpoint_sidecar] is supplied, builds the checkpoint
    via [Agent_sdk.Agent_checkpoint.build_checkpoint] threading the
    sidecar JSON through as the [working_context]; this path is
    used when masc wants to attach extra worker-side state
    that the SDK's default capture does not include. *)

val partial_response_of_stop :
  session_id:string ->
  text:string ->
  Agent_sdk.Types.api_response
(** Synthesise an [Agent_sdk.Types.api_response] for the early-stop
    case (e.g. operator-side cancel before the model finishes).
    [stop_reason = EndTurn], single [Text] content block, no
    usage / telemetry. The emitted response model is the neutral [runtime]
    lane; OAS owns concrete provider/model identity. *)
