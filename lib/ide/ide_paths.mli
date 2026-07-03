(** IDE store path SSOT.

    Centralises the [.masc-ide/] subdirectory name and store path
    construction used by the IDE annotation, region tracker, meta sync,
    and HTTP query modules.

    Replaces the previously scattered [Filename.concat _ ".masc-ide"]
    literal flagged in RFC-0084 §1.7 (Scattered hardcoded default).

    RFC-0128 §4.1, §4.2 extend this module with canonical-URL slug
    derivation and partitioned store paths ([by-url/<slug>/],
    [_orphan/]) so keeper writes from a sandbox clone and IDE reads
    against the user's working tree can join on the same codebase
    identity. The slug helpers are pure additions in PR-1a and have
    zero callers until PR-1b/c wire them. *)

val store_subdir : string
(** The literal subdirectory name [".masc-ide"]. *)

val store_path : base_dir:string -> string
(** [store_path ~base_dir] returns [base_dir/.masc-ide]. *)

val by_url_path : base_dir:string -> canonical_url:string -> string
(** [by_url_path ~base_dir ~canonical_url] returns
    [base_dir/.masc-ide/by-url/<canonical_url>]. The caller is
    responsible for ensuring [canonical_url] is a slug returned from
    [canonical_url_of_remote]. *)

val orphan_path : base_dir:string -> string
(** [orphan_path ~base_dir] returns [base_dir/.masc-ide/_orphan].
    Records whose canonical URL cannot be resolved land here so silent
    loss is impossible. *)

type partition =
  Agent_observation.codebase_partition =
  | By_url of string
  | No_canonical_url
  | Unmatched
  | Base_unresolved
  | Legacy_default
(** RFC-0128 §4.2 store partition selector (IDE Observation Plane v2 §7
    typed reasons).

    [By_url slug] selects [base_dir/.masc-ide/by-url/<slug>/]. The
    caller must obtain [slug] from {!canonical_url_of_remote}.

    The four non-By_url variants ([No_canonical_url], [Unmatched],
    [Base_unresolved], [Legacy_default]) all map to
    [base_dir/.masc-ide/_orphan/] on disk (layout unchanged) but carry
    distinct typed reasons. Silent loss is avoided by routing failures
    here instead of dropping them; the reason distinguishes {v2 §7}
    empty-repo / unmatched-repo_id / base-loss / structural-default. *)

val partition_store_dir : base_dir:string -> partition -> string
(** [partition_store_dir ~base_dir partition] returns the directory
    that holds [annotations.jsonl] / [regions.jsonl] for the chosen
    partition. Total. *)

val canonical_url_of_remote : string -> string option
(** [canonical_url_of_remote remote] normalises a git remote string
    into a host_path slug, e.g.
    [https://github.com/jeong-sik/masc(.git)?] and
    [git@github.com:jeong-sik/masc(.git)?] both produce
    [Some "github.com_jeong-sik_masc"].

    Returns [None] when:
    - the input is empty
    - it lacks a host
    - it lacks a path
    - any segment contains a character outside [a-z0-9._-]
    - any segment begins with [..] (path traversal guard)

    The function is total (never raises) and deterministic. The same
    upstream resolves to the same slug regardless of which transport
    the remote was registered with. *)
