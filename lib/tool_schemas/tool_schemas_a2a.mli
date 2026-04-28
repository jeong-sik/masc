(** Tool schemas for [Tool_a2a] — separated to break the Config
    dependency cycle.

    All A2A tool schemas have been pruned (poll_events,
    heartbeat_result removed); the value remains as an empty
    registration slot. *)

val schemas : Types.tool_schema list
