(** Relation Materializer — agent relationship recording.
    Second Brain GraphQL integration has been retired; callbacks are retained as no-op.
*)

(** Retired: no external GraphQL mutation on session end. *)
let on_agent_session_ended ~leaving_agent:_ ~active_agents:_ = ()

(** Retired: no external GraphQL mutation on task completion. *)
let on_task_done ~assignee:_ ~active_agents:_ = ()
