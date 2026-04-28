(** Prompt_defaults — auto-discover prompt metadata from markdown
    frontmatter and register it with {!Prompt_registry}.

    [bootstrap_runtime] is called once during server startup; it
    resolves the prompt markdown directory, points
    {!Prompt_registry} at it, loads every markdown file with YAML
    frontmatter ([description] / [category] /
    [template_variables]), and replays any persisted operator
    overrides. The signature is memoised so a re-call with the
    same [(workspace_path, prompt_markdown_dir)] pair is a no-op
    — useful when the bootstrap is wired into multiple lifecycle
    points.

    Internal helpers (the [existing_dir] predicate, the
    [prompt_markdown_dir_candidates] list, and the
    [bootstrapped_signature] memo ref) are hidden — callers
    consume only the three entry points below. *)

val init : unit -> unit
(** Re-scan the currently-configured markdown directory and
    register all prompts that have YAML frontmatter. Used by
    tests after a manual [Prompt_registry.set_markdown_dir] call;
    no-op when no directory is configured. *)

val resolve_prompt_markdown_dir :
  workspace_path:string ->
  base_path:string ->
  string
(** Pick the prompt markdown directory for a given workspace.
    Currently always returns [Config_dir_resolver.prompts_dir ()]
    (both for the resolved candidate and the fallback) — the
    parameters are accepted for forward compatibility with
    workspace-scoped overrides and exercised directly by the
    [test_server_runtime_bootstrap] suite. *)

val bootstrap_runtime :
  workspace_path:string ->
  base_path:string ->
  string
(** Resolve the markdown directory, point {!Prompt_registry} at
    it, load every prompt file, and restore persisted operator
    overrides. Returns the resolved directory path.

    Idempotent on the [(workspace_path, prompt_markdown_dir)]
    pair — repeated calls with the same arguments skip the
    registry mutation and override replay. [Eio.Cancel.Cancelled]
    is propagated; any other exception during override restore
    is logged via [Log.Misc.error] and swallowed so a corrupt
    override file cannot bring the boot path down. *)
