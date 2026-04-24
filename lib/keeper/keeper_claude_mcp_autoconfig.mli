(** Auto-construct [claude_mcp_config] JSON so CLI-backed keeper turns
    (claude_code, kimi_cli) can reach the local masc-mcp HTTP MCP
    endpoint with the keeper's own bearer token.

    See issue #10049 for background. Before this helper, the only way
    to give these CLI providers an MCP server was the
    [OAS_CLAUDE_MCP_CONFIG] env var. Without it, the CLI subprocess
    launched with an empty mcpServers block and every MCP tool
    (keeper_shell, keeper_bash, keeper_fs_*, …) was invisible to the
    model.

    Pure string-in / string-out. No logging of the bearer token. *)

val auto_construct :
  base_path:string -> agent_name:string -> string option
(** [auto_construct ~base_path ~agent_name] returns a JSON object,
    ready to pass as the [claude_mcp_config] field, that registers
    [masc] as an HTTP MCP server using the keeper agent's own bearer
    token. Returns [None] when any of:

    - the [MASC_MCP_URL] env variable is missing or empty (server did
      not publish it — e.g. running as a unit test)
    - the auth token file [<base_path>/.masc/auth/<agent_name>.token]
      is missing, unreadable, or empty
    - the bearer or URL contain characters that would break JSON
      quoting under [Yojson.Safe] (defensive; in practice tokens are
      hex-only and URLs are well-formed)

    Callers should treat [None] as "leave claude_mcp_config alone" —
    the existing [OAS_CLAUDE_MCP_CONFIG] fallback path is not changed. *)
