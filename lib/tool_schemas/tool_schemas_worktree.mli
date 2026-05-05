(** Tool_schemas_worktree — SSOT for the three Git-worktree
    lifecycle tool schemas.

    Surface order:
    - [masc_worktree_create] — create an isolated Git worktree
      for a task. Required [task_id]; optional [agent_name],
      [base_branch] (default ["auto"]), [repo_name].
    - [masc_worktree_remove] — remove a worktree and its local
      branch after the work is merged. Required [task_id];
      optional [agent_name].
    - [masc_worktree_list] — list active worktrees in the
      project. No required parameters.

    The schemas are concatenated by four downstream surfaces
    ([tool_worktree], [tool_shard], [agent_tool_surfaces],
    [tools]); list length and per-tool [name] strings are part
    of the public contract because the agent SDK's tool-routing
    tables grep them at startup. *)

val schemas : Masc_domain.tool_schema list
(** The three worktree-lifecycle schemas in the surface order
    above. List length and [name] strings are pinned at the
    contract seam — a future rename of [masc_worktree_remove]
    must touch this file as part of an explicit migration.

    Note on [repo_name] validation: the schema [pattern]
    [^[A-Za-z0-9._-]+$] enforces the character class, but the
    special values ["."] and [".."] match it and are rejected
    at runtime in [Tool_worktree.handle_worktree_create] and
    [Coord_worktree.worktree_create_r]. JSON Schema Draft 7
    (used by most MCP clients) does not support negative
    lookahead, so the three layers (schema, tool dispatch,
    coord resolver) must keep the same rule by convention. *)
