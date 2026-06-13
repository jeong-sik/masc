(** Mcp_tool_runtime_comm — communication tool handlers.

    Handles: masc_broadcast, masc_messages.

    RFC-0062 Phase 4c-2: handlers now accept [~tool_name ~start_time]
    and return structured [Tool_result.result] instead of [(bool * string)].

    @since 0.1.0 *)

type context = Mcp_tool_runtime_types.context

(** {1 Handlers} *)

val handle_broadcast : tool_name:string -> start_time:float -> context -> Tool_result.result option
val handle_messages : tool_name:string -> start_time:float -> context -> Tool_result.result option
