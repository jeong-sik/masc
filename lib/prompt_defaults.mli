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

type sync_result = {
  copied : string list;
  overwritten : string list;
  removed : string list;
  failed : (string * string) list;
}
(** Outcome of one prompt asset sync pass. Entries are embedded asset
    paths (e.g. [prompts/keeper.world.md]); [removed] contains retired
    distribution assets deleted from the runtime directory, and [failed]
    pairs the path with the error message. *)

val sync_prompt_assets :
  read:(string -> string option) ->
  files:string list ->
  prompts_dir:string ->
  unit ->
  sync_result
(** Converge the runtime prompt markdown dir onto the binary-embedded
    assets (#20929). Only entries under [prompts/] in [files] are
    considered; each is written into [prompts_dir] when missing or when
    its content differs from the embedded copy. Identical files are left
    untouched. The embedded cumulative managed-assets manifest identifies
    distribution-owned paths; a managed path absent from the current embedded
    assets is removed. Runtime-only paths absent from that manifest are
    operator-owned and preserved.

    Overwrite-on-differ is safe by design: operator prompt customization
    lives in prompt_overrides.json (replayed after directory load), so a
    divergent markdown file is a stale distribution copy, not an edit.
    The rest of .masc/config is operator-edited in place and is out of
    scope here.

    [read]/[files] are typically [Embedded_config.read] /
    [Embedded_config.file_list], passed in by the server bootstrap so
    this module stays asset-source agnostic (and unit-testable).
    Deletion is fail-closed: an absent, malformed, incomplete, or unsafe
    manifest records an explicit [failed] entry and no retired path is removed.
    [Eio.Cancel.Cancelled] propagates; per-file [Sys_error] is recorded in
    [failed] without aborting the pass. *)

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

val init : unit -> unit
(** Install prompt-registry observers and re-scan the currently
    configured markdown directory.  Used by [bootstrap_runtime]
    internally; also exposed for tests that have already set the
    markdown dir via [Prompt_registry.set_markdown_dir] and just
    need to (re)load prompts.  No-op when no markdown dir is
    configured. *)
