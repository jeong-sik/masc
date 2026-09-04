(** Playground path SSOT.

    Canonical layout for a keeper's playground bundle, relative to the
    server [base_path]:

    - [.masc/playground/<keeper>/]        — bundle root
    - [.masc/playground/<keeper>/repos/]  — git clones (one dir per repo)

    Both [masc_workspace] (worktree resolver) and the keeper modules
    ([Keeper_alerting_path.playground_*]) delegate here, so the
    literal [".masc/playground"] and the sanitization rules live in
    one place. *)

val all_playgrounds_prefix : string
(** Shared prefix for all keeper playgrounds, relative to the server's
    [base_path]. Built from {!Common.masc_dirname} so the literal
    [".masc"] lives in a single place; this module remains the SSOT
    for the [<.masc>/playground] sub-tree. *)

val sanitize_keeper_name : string -> string
(** Sanitize a keeper name into a filesystem-safe component.

    First strips the [keeper-...-agent] canonical wrapper so that both
    ["keeper-X-agent"] and ["X"] resolve to the same directory. Allows
    [A-Za-z0-9._-] and replaces everything else with [_]. Empty input
    and the special path components [.] / [..] are mapped to [_] /
    [__] so traversal segments can never appear as directory names. *)

val bundle_root : string -> string
(** Relative path [".masc/playground/<safe_name>/"] (trailing slash). *)

type playground_file_path =
  { keeper_name : string
  ; relative_path : string
  }

val parse_playground_file_path
  :  base_path:string
  -> abs_path:string
  -> playground_file_path option
(** Parse an absolute path below a local or Docker keeper playground.

    Accepted layouts:
    - [.masc/playground/<keeper>/<relative_path>]
    - [.masc/playground/docker/<keeper>/<relative_path>]

    Empty relative paths and [.] / [..] segments are rejected. This is a
    structural parser only; callers enforcing an I/O boundary must pass
    realpath-resolved inputs and separately check the filesystem kind. *)

val parse_bundle_relative_repo_path : string -> (string * string) option
(** [parse_bundle_relative_repo_path rel] parses [repos/<repo_id>/<rel>], a
    path relative to one keeper's bundle root, into [(repo_id, rel)].

    This is the anchor {!parse_playground_repo_path} looks for once it has
    stripped the playground prefix, exposed for callers that already hold the
    bundle-relative form and know whose bundle it is — a tool call's
    [action_radius.target_path] is written that way. Local and Docker keepers
    differ in where the bundle sits, not in the path inside it, so a caller
    reaching this needs no sandbox knowledge and should not manufacture an
    absolute path to get here.

    Paths that do not start at [repos/], name an empty repository, or stop
    before naming a file inside it, return [None]. Structural only: this does
    not reject [.] or [..] segments, and callers turning the result into an
    I/O path must resolve it themselves. *)

val bundle_repos_dirname : string
(** The literal [repos] segment inside a keeper's bundle. Spelled once, here.

    The repo tree has a second, unrelated [repos]: the server-side
    registration store under [.masc/repos/<id>] owned by
    [Config_dir_resolver]. Same spelling, different concept — one names
    the clone directory inside one keeper's bundle, the other a store
    under the server base path. They are two constants. *)

val bundle_relative_repo_path : repo_id:string -> string -> string
(** [bundle_relative_repo_path ~repo_id rel] is the bundle-relative path of
    [rel] inside [repo_id]'s clone — the inverse of
    {!parse_bundle_relative_repo_path}. Building it here keeps the [repos]
    segment spelled in one place. *)

val parse_playground_repo_path
  :  base_path:string
  -> abs_path:string
  -> (string * string) option
(** RFC-0128 §4.5. Parse a sandbox playground absolute file path back
    into [(repo_id, rel_path)].

    Layouts accepted (relative to [base_path]):
    - [.masc/playground/<keeper>/repos/<repo_id>/<rel>]          (Local)
    - [.masc/playground/docker/<keeper>/repos/<repo_id>/<rel>]   (Docker)

    Used by the keeper write path so files keepers edit inside their
    per-keeper repo clones map to the same canonical-URL bucket as
    files in the user's working tree. Returns [None] when [abs_path]
    is not absolute, not under [base_path], not anchored at the
    base-relative [.masc/playground/] root, or does not match one of
    the accepted structural layouts. *)
