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

val emit_tool_exec :
  config:Workspace_utils.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  tool_name:string ->
  success:bool ->
  duration_ms:int ->
  typed_outcome:Keeper_tool_outcome.t option ->
  provider:string ->
  keeper_turn_id:int option ->
  oas_turn:int ->
  task_id:string option ->
  unit ->
  unit
(** Appends one [keeper.tool_exec] event. [meta.agent_name] becomes the actor id
    (the same identity form [keeper.turn_completed] uses, so
    [Tool_agent_timeline.identity_matches] resolves both through one
    predicate); [meta.name] is carried for the payload-side identity fallback.
    [keeper_turn_id] is the absolute Keeper-lane turn and [oas_turn] is the
    model/tool-loop step inside it; task identity is carried separately and is
    never substituted for either turn id. Typed outcome JSON is preserved
    without reconstructing a string category. *)
