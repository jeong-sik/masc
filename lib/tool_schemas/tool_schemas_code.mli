(** Tool_schemas_code — SSOT for code-inspection tool schemas.

    Three MCP tool schemas, in surface order:
    - [masc_code_search] — ripgrep search with regex support;
      returns file path / line number / matched content.
      Required: [query]. Optional: [path], [file_pattern],
      [case_insensitive], [max_results].
    - [masc_code_symbols] — extract symbols (functions, types,
      classes) from a single file via heuristics. Required:
      [path].
    - [masc_code_read] — read a file with [offset] / [limit]
      pagination for large files. Required: [path].

    The schemas are exposed as a [Masc_domain.tool_schema list] so the
    discovery wiring in [agent_tool_surfaces] can concatenate
    them with the rest of the surface; consumers must not depend
    on the in-list order beyond the documented surface order
    above. *)

val schemas : Masc_domain.tool_schema list
(** The three code-inspection schemas. List length and per-tool
    [name] strings are part of the public contract — the agent
    SDK's tool-routing tables grep them at startup. *)
