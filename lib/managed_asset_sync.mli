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
    and the manifest [schema] string its [managed-assets.json] must
    declare. *)
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
(** Converge [dest_dir] onto the embedded assets of [domain]. Only entries
    under the domain's prefix in [files] are considered. After all sync
    preconditions validate, each is written into [dest_dir] when missing or
    when its content differs from the embedded copy; identical files are
    left untouched. The embedded managed-assets manifest must exactly equal
    the current embedded asset set (an empty manifest with an empty set is
    valid — the state of a domain before its first migrated asset). The
    runtime directory is an exact distribution-owned projection: paths
    absent from the current manifest are removed, then the runtime manifest
    is replaced with the current one.

    [read]/[files] are typically [Embedded_config.read] /
    [Embedded_config.file_list], passed in by the server bootstrap so this
    module stays asset-source agnostic (and unit-testable).

    Deletion is fail-closed: a malformed, incomplete, or unsafe manifest or
    an unreadable runtime tree records an explicit [failed] entry and no
    path is removed. [Eio.Cancel.Cancelled] propagates; per-file
    [Sys_error] is recorded in [failed] without aborting the pass. *)

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
    manifest, which for [Tools] is the only way an operator's own definition
    can end — tool definitions have no runtime edit layer, so a file placed
    there is deleted at the next boot.

    Sharing one budget with the copies hid exactly that: a version bump
    copies enough assets to fill the sample, and the deleted paths never
    reach the line at all. The operator reads a count with no names.

    The caller logs this above [info]. *)
