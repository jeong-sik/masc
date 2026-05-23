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
    consume only the entry point below. *)

val resolve_prompt_markdown_dir :
  workspace_path:string -> base_path:string -> string
(** Return the first existing prompt markdown directory from the
    candidate list, falling back to {!Config_dir_resolver.prompts_dir}
    when none exist yet. *)

val init : unit -> unit
(** Initialise prompt defaults from the environment.
    Idempotent — safe to call multiple times. *)

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
