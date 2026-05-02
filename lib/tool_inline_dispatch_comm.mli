
(** Tool_inline_dispatch_comm — communication tool handlers.

    Handles: masc_broadcast, masc_messages, masc_who.

    @since 0.1.0 *)

type tool_result = Tool_inline_dispatch_types.tool_result

type context = Tool_inline_dispatch_types.context

(** {1 Handlers} *)

val handle_broadcast : context -> tool_result option
val handle_messages : context -> tool_result option
val handle_who : context -> tool_result option
