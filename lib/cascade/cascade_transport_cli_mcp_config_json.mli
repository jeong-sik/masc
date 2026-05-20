(** CLI MCP config JSON serializer.

    Builds the [{"mcpServers": {name: {...}}}] document that CLI
    providers (codex, claude_code, gemini variants) expect as
    [--mcp-config] argv. Returns [None] when the runtime mcp policy's
    allowed_server_names whitelist removes every server. *)

val json_of_string_pairs : (string * string) list -> Yojson.Safe.t

val json_of_cli_mcp_server
  :  Llm_provider.Llm_transport.runtime_mcp_server
  -> Yojson.Safe.t

val cli_mcp_config_json_of_policy
  :  Llm_provider.Llm_transport.runtime_mcp_policy
  -> string option
