(** Playground path SSOT.

    Canonical layout for a keeper's playground bundle, relative to the
    server [base_path]:

    - [.masc/playground/<keeper>/]        — bundle root
    - [.masc/playground/<keeper>/mind/]   — notes, drafts, scratch
    - [.masc/playground/<keeper>/repos/]  — git clones (one dir per repo)

    Both [masc_room] (worktree resolver) and the keeper modules
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

val mind_path : string -> string
(** Relative path [".masc/playground/<safe_name>/mind/"]. *)

val repos_path : string -> string
(** Relative path [".masc/playground/<safe_name>/repos/"]. *)

val bundle_paths : string -> string list
(** All three bundle subdirs in canonical order:
    [\[bundle_root; mind_path; repos_path\]]. *)

(** {1 Worktree Naming}

    Worktree directory names and git branch names for keeper task
    isolation. [room_worktree.ml] and [worktree_remove_r] delegate
    here so the naming convention exists in one place. *)

val worktree_dir_name : string -> string -> string
(** [worktree_dir_name agent task_id] -> ["<agent>-<task_id>"]. The
    caller is responsible for passing either a raw or sanitized agent
    name — this function formats only. *)

val worktree_branch_name : string -> string -> string
(** [worktree_branch_name agent task_id] -> ["<agent>/<task_id>"]. *)
