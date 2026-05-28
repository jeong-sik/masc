(* RFC-0203 Phase 3 — masc_mcp glue for the [discord_send_message] tool.

   Pure logic (parse_input, builtin_enabled, failure_class_of_send_error,
   dispatch core, schema) lives in {!Discord_tool_helpers} inside the
   [masc_mcp.gate] sub-library so it is unit-testable without linking
   the full [masc_mcp] library — see discord_tool_helpers.mli for
   rationale. *)

let tool_name = "discord_send_message"

let handler : Tool_dispatch.handler =
  Discord_tool_helpers.dispatch
    ~send:Channel_gate_discord_state.send_message
    ~tool_name

let () =
  let spec =
    Tool_spec.create
      ~name:tool_name
      ~description:
        "RFC-0203 — post a message to a Discord channel \
         (guild text, DM, or thread, all addressed by the same \
         snowflake channel_id). Gated by MASC_DISCORD_BUILTIN."
      ~module_tag:Tool_dispatch.Mod_discord
      ~input_schema:Discord_tool_helpers.input_schema
      ~handler_binding:(Tool_spec.Direct handler)
      ~is_destructive:true (* outbound message is externally visible *)
      ()
  in
  Tool_spec.register spec
