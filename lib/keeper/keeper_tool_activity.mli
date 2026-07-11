(** Activity-graph producer for keeper in-turn tool executions.

    The agent timeline's tool source ([tool.called]) is emitted only by the
    external MCP dispatch path, so tools a keeper runs inside its own turn
    never reached the activity log and the dashboard timeline reported
    [tool_calls = 0] for busy keepers (#23540). This module emits the
    keeper-side counterpart under its own kind, [keeper.tool_exec], instead
    of reusing [tool.called]: the two producers carry different actor
    identities and payload provenance, and folding them into one kind would
    make the actor back-reference ambiguous.

    Emission is fire-and-forget: a failed append must never change the tool
    call's result. [Eio.Cancel.Cancelled] is re-raised (never absorbed). *)

val tool_exec_kind : string
(** ["keeper.tool_exec"] — matched by the agent-timeline read model and the
    activity-graph reducer. *)

val emit_tool_exec :
  config:Workspace_utils.config ->
  agent_name:string ->
  keeper_name:string ->
  tool_name:string ->
  success:bool ->
  duration_ms:int ->
  outcome:string ->
  provider:string ->
  turn_id:string ->
  unit ->
  unit
(** Appends one [keeper.tool_exec] event. [agent_name] becomes the actor id
    (the same identity form [keeper.turn_completed] uses, so
    [Tool_agent_timeline.identity_matches] resolves both through one
    predicate); [keeper_name] is carried in the payload for the payload-side
    identity fallback. [tool_name]/[success]/[duration_ms] follow the
    [tool.called] payload contract the timeline detail projection reads. *)
