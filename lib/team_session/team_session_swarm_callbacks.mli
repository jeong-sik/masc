(** Team_session_swarm_callbacks — MASC supervision logic as OAS Swarm callbacks.

    Phase C-2b: Maps MASC's checkpoint/event/SSE broadcast operations
    to OAS Swarm lifecycle callbacks.

    @since 2.125.0 *)

(** Create swarm callbacks that bridge MASC supervision into OAS lifecycle.

    - [on_iteration_start] → checkpoint write
    - [on_agent_done] → event journal + SSE broadcast
    - [on_converged] → session finalization
    - [on_error] → policy violation recording

    @param config Room configuration
    @param session_id Session being supervised *)
val make_callbacks :
  config:Room.config ->
  session_id:string ->
  Swarm.Swarm_types.swarm_callbacks
