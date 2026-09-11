(** Relation Materializer — agent relationship lifecycle hooks. *)

let on_agent_session_ended ~leaving_agent:_ ~active_agents:_ = ()

let on_task_done ~assignee:_ ~active_agents:_ = ()
