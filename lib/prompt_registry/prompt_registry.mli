(** Prompt_registry — versioned prompt template store
    with file overrides and runtime resolution.

    Three resolution sources, in priority order:
    - {b Override}: in-memory key→string set via
      {!set_override} (validated against [meta_tbl]).
    - {b File}: markdown file at
      [<markdown_dir>/<key>.md] (frontmatter stripped via
      [parse_frontmatter]).
    - {b Default}: registered template registered through
      {!register_default} during plugin init.

    Persistence: {!persist_overrides} writes a versioned,
    contract-bound envelope to [.masc/prompt_overrides.json];
    {!restore_overrides} reapplies it through the same
    validation as {!set_override} — including the
    [{{ident}}] placeholder check, which applies even to
    prompts with no declared [template_variables] (see
    [unexpected_template_variables]) — so manually-edited
    or stale entries are dropped with an error log and a
    fallback to the file/default value instead of silently
    accepted.

    Concurrency: override and prompt-contract mutations first take the
    dedicated mutation mutex, then use [with_mutex] around
    {!Prompt_registry_store.t.mutex} for the in-memory commit.  Persistence I/O
    holds only the mutation mutex, so readers keep observing the previous
    complete table until commit.  Other file reads
    ({!resolve_prompt}, {!list_prompts},
    {!validate_prompt_templates}) snapshot under the lock,
    release it, then read disk so concurrent readers do
    not serialize on I/O.

    Internal helpers stay private at this boundary
    ([parse_frontmatter], [parse_list_value],
    [extract_variables], [store],
    [version_index], [meta_tbl], [prompts_dir],
    [markdown_dir], [make_key], [is_valid_prompt_key],
    [prompt_markdown_path], [read_file_if_exists],
    [get_versions], [list_all], [list_ids], [exists],
    [unregister], [deprecate], [update_metrics],
    [replace_substring_all], [render_template], [stats], [count], [count_unique],
    [to_json], [of_json], [default_prompt_value_unlocked],
    [build_resolved_from_snapshot], [resolved_of_snapshot],
    [unexpected_template_variables],
    [prompt_item_json_of_resolved], [compare_prompt_items],
    [register_prompt], [register_prompt_unlocked], [register_default],
    [validated_override], [prompt_snapshot] type,
    [register], [init], [render]). *)

(** {1 Type re-exports} *)

module Types = Prompt_registry_types
(** Re-export of the type-only sub-module so callers reach
    record / variant types via [Prompt_registry.Types.X]
    after [open Masc].
    [test/test_prompt_registry_pbt.ml] uses this alias. *)

type prompt_metrics = Prompt_registry_types.prompt_metrics = {
  usage_count : int;
  avg_score : float;
  last_used : float;
}

val prompt_metrics_to_yojson : prompt_metrics -> Yojson.Safe.t
val prompt_metrics_of_yojson :
  Yojson.Safe.t -> (prompt_metrics, string) result

type prompt_entry = Prompt_registry_types.prompt_entry = {
  id : string;
  template : string;
  version : string;
  variables : string list;
  metrics : prompt_metrics option;
  created_at : float;
  deprecated : bool;
}

val prompt_entry_to_yojson : prompt_entry -> Yojson.Safe.t
val prompt_entry_of_yojson :
  Yojson.Safe.t -> (prompt_entry, string) result

type registry_stats = Prompt_registry_types.registry_stats = {
  total_prompts : int;
  active_prompts : int;
  deprecated_prompts : int;
  most_used : string option;
  avg_usage : float;
}

type prompt_meta = Prompt_registry_types.prompt_meta = {
  description : string;
  category : string;
  required_file : bool;
  template_variables : string list;
}

type prompt_resolution = Prompt_registry_types.prompt_resolution = {
  effective : string;
  source : string;
  file_value : string option;
  override_value : string option;
  default_value : string option;
  file_path : string option;
  file_exists : bool;
  has_override : bool;
}

type persisted_mutation_error =
  | Validation_error of string
  | Persistence_error of string

(** {1 Markdown parsing} *)

val markdown_body : string -> string
(** Return the body of a markdown asset after removing one leading YAML-style
    frontmatter block. Content without frontmatter is returned unchanged. *)


(** {1 Markdown directory} *)

val set_markdown_dir : string -> unit
(** Pins the directory the file-based resolution path
    looks under for [<key>.md]. *)

val get_markdown_dir : unit -> string option
(** Returns the currently-pinned markdown dir, [None] if
    {!set_markdown_dir} was never called. *)

val load_prompts_from_directory : string -> unit
(** Auto-discovers [*.md] files under [dir], parses YAML
    frontmatter, and registers each as a known prompt
    via the internal [register_prompt] helper.  Files
    without frontmatter (or without a [description]) are
    skipped — those require explicit registration. *)

(** {1 Resolution} *)

val resolve_prompt : string -> prompt_resolution
(** Reads the markdown file (outside the mutex) then
    looks up override / default under the lock and
    returns the full {!prompt_resolution} record.  Used
    by the dashboard HTTP route to surface every source's
    contribution side-by-side. *)

val get_prompt : string -> string
(** Convenience accessor for [(resolve_prompt key).effective].
    Returns the empty string when [key] is missing from
    every source. *)

val prompt_source : string -> string
(** [(resolve_prompt key).source]: ["override"] /
    ["file"] / ["default"] / ["missing"]. *)

(** {1 Rendering} *)

val render_prompt_template :
  string -> (string * string) list -> (string, string) result
(** Renders the prompt at [key] with the variable
    substitutions from the assoc list.  Errors when the
    prompt is missing (empty after trim) or when the
    template references an unresolved variable not in the
    assoc list. *)

(** {1 Override lifecycle} *)

val set_override : string -> string -> (unit, string) result
(** Validates and installs an override.  Rejects invalid
    keys, empty / oversized (>10000 chars) values, and
    unexpected template variables (a variable in the
    template that the registered [meta_tbl] entry does
    not declare). *)

val clear_prompt_override : string -> unit
(** Removes the override for [key] (no-op when absent).
    Falls back to file → default on next resolution. *)

val persist_overrides : string -> (unit, string) result
(** Writes the current override table to
    [<base_path>/.masc/prompt_overrides.json] through an atomic replacement.
    Returns an explicit error when the persistence boundary fails. *)

val set_override_persisted :
  base_path:string ->
  string ->
  string ->
  (unit, persisted_mutation_error) result
(** Validate an override, atomically persist the complete candidate table,
    then commit it to memory.  A persistence failure leaves the live table
    unchanged. *)

val clear_prompt_override_persisted :
  base_path:string -> string -> (unit, string) result
(** Atomically persist the candidate table without [key], then commit it to
    memory.  A persistence failure leaves the live table unchanged. *)

val restore_overrides : string -> unit
(** Reads
    [<base_path>/.masc/prompt_overrides.json] and reapplies
    every entry through {!set_override}'s validation after verifying its
    contract revision.  The validated candidate set replaces the live table
    in one mutex transaction, so rejected entries cannot leave stale live
    overrides behind.  Legacy envelopes, malformed entries, and stale or
    manually-edited entries are rejected with an observable error and fallback
    to file/default content. *)

val set_restore_failure_observer : (unit -> unit) -> unit
(** Installs the process-local observer called whenever override
    restore rejects an entry or cannot parse the persisted override
    file. The default observer is a no-op so this sub-library stays
    independent of the runtime metrics implementation. *)

(** {1 Listing + JSON export} *)

val list_prompts : unit -> Yojson.Safe.t list
(** Returns one JSON entry per registered prompt.
    Snapshots key / meta / override / default under the
    mutex, releases the lock, then reads the markdown
    files and builds the [resolved] record outside the
    lock so concurrent callers no longer serialize on
    disk I/O.  Sorted by [(category, key)]. *)

val prompts_json : unit -> Yojson.Safe.t
(** [`Assoc [("prompts", `List (list_prompts ()))]] —
    canonical envelope for the dashboard prompt route. *)

(** {1 Validation} *)

val validate_required_prompt_files : unit -> (string * string) list
(** Returns [(key, path)] for every prompt whose meta
    declares [required_file = true] but whose markdown
    file is missing or unreadable.  [path] is the
    expected location, or ["<invalid-key>"] when the
    markdown dir is unset. *)

val validate_prompt_templates : unit -> (string * string) list
(** Returns [(key, variable)] pairs for every template
    that references a variable not declared in the
    registered [meta_tbl] entry's [template_variables]
    list.  Empty / missing prompts are skipped (only
    rendered prompts can have unexpected variables). *)

(** {1 Test isolation} *)

val clear : unit -> unit
(** Drops every entry from the registry / version index /
    override table / meta table and unsets the persisted
    directory.  Pinned at this boundary because
    [test/test_prompt_registry_defaults.ml] calls it
    between cases for isolation; production code paths
    do not need it. *)
