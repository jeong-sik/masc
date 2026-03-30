(** Team_session_swarm_runner — OAS Swarm-based team session execution.

    Phase C-2a: Run team sessions through OAS Swarm Runner instead of the
    legacy 15-second polling engine. The session is converted to a
    {!Agent_sdk_swarm.Swarm_types.swarm_config} via the bridge, executed
    through {!Agent_sdk_swarm.Runner.run}, and the result is applied back.

    Only activated when [orchestration_mode = Auto]. Manual/Assist modes
    continue to use the existing engine.

    @since 2.125.0 *)

module Swarm = Agent_sdk_swarm

(** Run a team session through OAS Swarm Runner.

    Converts the session to swarm config, executes via [Runner.run],
    and applies the result back to the session. Writes checkpoint and
    event journal entries via callbacks.

    @param sw Eio switch for fiber management
    @param clock Eio clock for timeouts
    @param config Room configuration
    @param session_id Session to execute
    @param masc_tools Available MCP tools for agents
    @param dispatch MCP tool dispatch function
    @return Updated session or error message *)
val run_swarm :
  sw:Eio.Switch.t ->
  env:< clock : _ Eio.Time.clock ; process_mgr : _ Eio.Process.mgr ; net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ; .. > ->
  config:Room.config ->
  session_id:string ->
  masc_tools:Types.tool_schema list ->
  dispatch:(name:string -> args:Yojson.Safe.t -> bool * string) ->
  (Team_session_types.session, string) result
