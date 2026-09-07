(** Managed_asset_sync — converge one runtime config subtree onto the
    binary-embedded assets (#20929, generalized from the prompt-only sync for
    RFC prompts-and-tool-definitions-outside-ocaml).

    The binary embeds the repo's [config/] tree ([Embedded_config]); the
    runtime copies under [<config-root>/prompts], [<config-root>/tools] and
    [<config-root>/mcp] are derived distribution state. A runtime file that
    differs from the embedded asset is stale, not customized — prompt
    customization lives in [prompt_overrides.json], and tool definitions have
    no runtime edit layer at all — so overwriting is the correct convergence.
    The rest of the config root (runtime.toml, keeper manifests, …) is
    operator-edited in place and is never synced. *)

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
    distribution assets deleted from the runtime directory, and [failed]
    pairs the path with the error message. *)

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
    differs from the embedded copy; identical files are left untouched. The
    runtime directory is an exact distribution-owned projection: paths
    absent from the embedded set are removed, then the runtime
    [managed-assets.json] is rewritten from that set ([managed_by],
    [schema], sorted [paths]) as the record of what this binary owns there.

    An empty embedded set is refused: every domain ships assets, so an empty
    set is a lost tree, and projecting it would delete the whole runtime
    directory.

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
    removal is a file that was in the runtime tree and is not in the
    embedded set, which for [Tools] is the only way an operator's own definition
    can end — tool definitions have no runtime edit layer, so a file placed
    there is deleted at the next boot.

    Sharing one budget with the copies hid exactly that: a version bump
    copies enough assets to fill the sample, and the deleted paths never
    reach the line at all. The operator reads a count with no names.

    The caller logs this above [info]. *)
