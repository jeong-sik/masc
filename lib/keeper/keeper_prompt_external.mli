(** Keeper_prompt_external — loader for behavior prompt blocks living
    outside the OCaml source.

    Each named block is read from
    [<Config_dir_resolver.prompts_dir ()>/behavior/<name>.md] on first
    access and cached for the remainder of the process lifetime.  The
    cache key is the block name. A leading YAML frontmatter block is
    stripped so callers receive only prompt body text.

    Missing files do not crash.  [get name] returns [None] and logs
    once per name so callers can render an explicit config-drift marker
    while operators restore the external file.

    This module is a thin sibling of [Prompt_registry]: that registry
    handles versioned, override-able, frontmatter-aware system prompts.
    [Keeper_prompt_external] is for the long tail of operator-facing
    *behavior* blocks that used to live as OCaml string literals in
    [keeper_prompt.ml] — content that operators want to tune without
    rebuilding the binary, but that does not need version management
    or runtime overrides. *)

val get : string -> string option
(** [get name] returns the contents of
    [<prompts_dir>/behavior/<name>.md] on success, or [None] if the
    file is missing/unreadable.  Cached after the first call so the
    file is read at most once per process per [name]. *)

val reset_cache : unit -> unit
(** Drop the cache so the next [get] re-reads from disk.  Intended for
    tests; no callers in production code. *)
