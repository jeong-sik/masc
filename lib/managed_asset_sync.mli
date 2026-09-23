(** Managed_asset_sync — converge one runtime config subtree onto the
    binary-embedded assets (#20929, generalized from the prompt-only sync for
    RFC prompts-and-tool-definitions-outside-ocaml).

    The binary embeds the repo's [config/] tree ([Embedded_config]); the
    runtime copies under [<config-root>/prompts], [<config-root>/tools] and
    [<config-root>/mcp] are derived distribution state. Prompt customization
    lives in [prompt_overrides.json], and tool definitions have no runtime
    edit layer at all. A runtime copy that differs from its embedded asset is
    stale when it still holds the bytes the previous pass wrote (the manifest
    records their SHA-256), and is overwritten. When it holds other bytes an
    operator edited it: the edit is moved into the domain's edit layer, or
    kept, or overwritten, and reported either way (see {!operator_edit}).
    A file in those directories that the distribution never shipped is the
    operator's and the sync leaves it alone: under [prompts/] the registry
    reads it like any other prompt file; under [tools/] and [mcp/] it is
    inert, since those definitions are read from the binary. The rest of the
    config root (runtime.toml, keeper manifests, …) is operator-edited in
    place and is never synced. *)

(** The closed set of embedded subtrees this sync may own. Each carries its
    asset prefix inside the embedded tree ([prompts/] / [tools/] / [mcp/])
    and the [schema] string written into the runtime directory's
    [managed-assets.json]. *)
type domain =
  | Prompts
  | Tools
  | Mcp

(** Where an operator's edit of a managed runtime file can go. The server
    passes [Prompt_overrides] for {!Prompts} and [No_edit_layer] for
    {!Tools} and {!Mcp}. *)
type edit_layer =
  | No_edit_layer
  | Prompt_overrides of
      (file:string -> embedded:string -> edited:string -> Prompt_registry.file_edit_promotion)
      (** Called with the runtime-relative path, the embedded copy and the
          edited bytes; typically {!Prompt_registry.promote_file_edit}. *)

type operator_edit_outcome =
  | Promoted_to_override of { key : string }
      (** The edit is saved as [key]'s prompt override and the file is reset
          to the embedded copy. *)
  | Kept_override_exists of { key : string }
      (** [key] already has a saved override, so the file is left as edited
          and the embedded copy is not installed. *)
  | Kept_not_promotable of { reason : string }
      (** The edit maps to no single override (or the override file could
          not be used); the file is left as edited. *)
  | Discarded
      (** No edit layer: the file is overwritten with the embedded copy. *)

type operator_edit =
  { path : string  (** Embedded asset path, e.g. [prompts/librarian.md]. *)
  ; outcome : operator_edit_outcome
  }
(** A runtime file whose bytes differ from both the embedded copy and the
    digest the previous pass recorded for it. A kept edit keeps its old
    digest, so it is reported again every pass until the file is deleted,
    reset, or its override removed. *)

type sync_result =
  { copied : string list
  ; overwritten : string list
  ; removed : string list
  ; operator_edits : operator_edit list
  ; failed : (string * string) list
  }
(** Outcome of one sync pass. Entries are embedded asset paths (e.g.
    [prompts/keeper.md], [tools/masc_board_vote.toml]); [overwritten] holds
    stale copies and files with no recorded digest; [removed] contains
    retired distribution assets deleted from the runtime directory;
    [operator_edits] the edits the recorded digests revealed; and [failed]
    pairs the path with the error message. *)

val sync
  :  domain:domain
  -> edit_layer:edit_layer
  -> read:(string -> string option)
  -> files:string list
  -> dest_dir:string
  -> unit
  -> sync_result
(** Converge [dest_dir] onto the embedded assets of [domain]. The managed
    set is every entry under the domain's prefix in [files]; nothing else
    declares it (#31283 removed the hand-written [managed-assets.json] that
    used to list the same files a second time and drifted from them). Each
    asset is written into [dest_dir] when missing or when its content
    differs from the embedded copy; identical files are left untouched.
    A differing file whose digest does not match the one recorded for it is
    an operator edit and goes to [edit_layer] instead.
    Deletion reaches only what masc owned: the runtime
    [managed-assets.json] the previous pass wrote lists the paths it placed
    there, and a listed path the embedded set no longer carries is removed.
    A file that was in no manifest is the operator's and stays. The
    manifest is then rewritten from the current set ([managed_by],
    [schema], sorted [paths], and [sha256] mapping each path to the digest
    of the bytes this pass left there) as the record of what this binary
    owns there. A [v1] manifest has paths and no digests: every differing
    file under it is overwritten as stale, and the rewrite records digests.
    Without a manifest a pass deletes nothing and writes one. A manifest
    that does not read, or that another domain wrote, is reported in
    [failed] and left as it is: the pass deletes nothing and writes no
    manifest, so the same report returns every boot until the operator
    repairs or removes the file, and what it recorded is not lost. One
    entry that is not a safe relative path refuses the whole manifest the
    same way.

    An empty embedded set is refused: every domain ships assets, so an empty
    set is a lost tree, and projecting it would retire every asset the
    previous manifest lists.

    [read]/[files] are typically [Embedded_config.read] /
    [Embedded_config.file_list], passed in by the server bootstrap so this
    module stays asset-source agnostic (and unit-testable).

    Every embedded relative path is validated before scanning or mutating
    the runtime tree. An unsafe path or empty embedded set records explicit
    [failed] entries and leaves runtime assets and the manifest untouched.
    An unreadable runtime tree also prevents deletion.
    [Eio.Cancel.Cancelled] propagates; per-file [Sys_error] is recorded in
    [failed] without aborting the pass. *)

val sample_budget : int
(** How many paths either report line names before it says how many more
    there were. Each line spends this separately. *)

val distribution_line : label:string -> sync_result -> string option
(** The copies this pass made, or [None] when it made none.

    Counts only — [copied] and [overwritten] are the distribution doing its
    job, and on a version bump there are hundreds of them. *)

val removed_line : label:string -> sync_result -> string option
(** The paths this pass deleted from the runtime directory, or [None] when
    it deleted none.

    Its own line and its own {!sample_budget}, because a removal is a
    different event from a copy. A copy is the distribution converging; a
    removal is a distribution asset retiring -- a path the previous manifest
    listed and this binary does not ship -- and the name is what tells the
    operator which one went.

    Sharing one budget with the copies hid exactly that: a version bump
    copies enough assets to fill the sample, and the deleted paths never
    reach the line at all. The operator reads a count with no names.

    The caller logs this above [info]. *)

val operator_edit_lines : label:string -> sync_result -> string list
(** One line per operator edit, naming the path and what the pass did with
    it. The caller logs each above [info]. *)
