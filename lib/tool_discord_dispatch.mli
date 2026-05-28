(** Tool_discord_dispatch — MCP tool surface glue for the in-process
    Discord connector (RFC-0203 Phase 3).

    Thin wrapper around {!Discord_tool_helpers} (which holds the pure
    parse / flag / dispatch logic in [masc_mcp.gate]). This module's
    only job in [masc_mcp] is to:

    - bind the pure dispatcher to the real
      {!Channel_gate_discord_state.send_message}, and
    - register the resulting handler via [Tool_spec.register] at
      module load time.

    The tool ships off by default behind [MASC_DISCORD_BUILTIN] per
    RFC-0203 §Phases bullet 1.

    No [masc_] prefix on the tool name — Discord is one of several
    future outbound channels (Telegram, Slack, ...), each with its
    own typed dispatcher.

    @since RFC-0203 Phase 3 *)

val tool_name : string
(** ["discord_send_message"]. *)

val handler : Tool_dispatch.handler
(** Exposed so the module's [let () = register] side-effect has a
    public symbol to anchor on (the linker may otherwise prune the
    module — see the [let () = ignore Tool_discord_dispatch.tool_name]
    in [mcp_server_eio.ml]). *)
