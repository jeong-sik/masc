(** The tool list a [kimi acp] host offers a [none] Keeper.

    [kimi acp] (Kimi Code 2.7.3) takes no option that limits its tools. Its
    default agent profile offers about 30 native tools, and most of them run
    without a permission request: on 2026-11-26/27 its [none] Keepers made
    1,837 native calls, of which only 76 asked and were refused. The host
    reads agent profiles from [<work dir>/.kimi-code/agents/*.md], and a
    profile named [agent] with [override: true] replaces the default one.
    Its [tools] frontmatter is an allowlist; [select_tools], the host's tool
    search, stays because the host checks it against [disallowedTools] only.

    The host records the profile when it creates a session, and a session
    loaded later keeps that record. A session created without this profile
    keeps the default tools for its whole life. *)

val file_relative_path : string
(** [.kimi-code/agents/agent.md], under the host's work directory. *)

val masc_only : mcp_server_name:string option -> string
(** The profile that allows the tools of the MCP server named
    [mcp_server_name] ([mcp__<name>__*]) and nothing else, and keeps the
    host's default system prompt ([${base_prompt}]). With no server it allows
    no tool. *)

val write_masc_only : cwd:string -> mcp_server_name:string option -> (unit, string) result
(** Write {!masc_only} at {!file_relative_path} under [cwd]. The file is only
    ever created: a [none] host's [cwd] is an empty folder MASC made for it
    ([Runtime_acp_client.create_isolated_workspace]), so a file already there
    means [cwd] is someone else's folder, and that is an [Error]. *)
