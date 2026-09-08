(** Managed_asset_sync — converge one runtime config subtree onto the
    binary-embedded assets (#20929, generalized from the prompt-only sync for
    RFC prompts-and-tool-definitions-outside-ocaml).

    The binary embeds the repo's [config/] tree ([Embedded_config]); the
    runtime copies under [<config-root>/prompts], [<config-root>/tools] and
    [<config-root>/mcp] are derived distribution state. A runtime copy of an
    embedded asset that differs from it is stale, not customized — prompt
    customization lives in [prompt_overrides.json], and tool definitions have
    no runtime edit layer at all — so overwriting is the correct convergence.
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

type sync_result =
  { copied : string list
  ; overwritten : string list
  ; removed : string list
  ; failed : (string * string) list
  }
(** Outcome of one sync pass. Entries are embedded asset paths (e.g.
    [prompts/keeper.md], [tools/masc_board_vote.toml]); [removed] contains
    retired distribution assets deleted from the runtime directory, and
    [failed] pairs the path with the error message. *)

val sync
  :  domain:domain
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
    Deletion reaches only what masc owned: the runtime
    [managed-assets.json] the previous pass wrote lists the paths it placed
    there, and a listed path the embedded set no longer carries is removed.
    A file that was in no manifest is the operator's and stays. The
    manifest is then rewritten from the current set ([managed_by],
    [schema], sorted [paths]) as the record of what this binary owns there.
    Without a readable manifest of this domain a pass deletes nothing; a
    manifest that fails to read is reported in [failed].

    An empty embedded set is refused: every domain ships assets, so an empty
    set is a lost tree, and projecting it would rewrite the manifest to
    nothing and retire every asset at the next boot.

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
