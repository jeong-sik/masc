(** Playground path SSOT.

    Canonical layout for a keeper's playground bundle, relative to the
    server [base_path]:

    - [.masc/playground/<keeper>/]        — bundle root
    - [.masc/playground/<keeper>/mind/]   — notes, drafts, scratch
    - [.masc/playground/<keeper>/repos/]  — git clones (one dir per repo)

    These helpers are the single source of truth. Both [masc_room]
    (worktree resolver) and the keeper modules
    ([Keeper_alerting_path.playground_*]) delegate here so the literal
    [".masc/playground"] and sanitization rules exist in one place. *)

(** Shared prefix for all keeper playgrounds, relative to the
    server's [base_path]. *)
let all_playgrounds_prefix : string = ".masc/playground"

(** Sanitize a keeper name into a filesystem-safe component. Allows
    [A-Za-z0-9._-] and replaces everything else with [_]. *)
let sanitize_keeper_name (name : string) : string =
  String.map (fun c ->
    if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
       || (c >= '0' && c <= '9') || c = '-' || c = '_' || c = '.'
    then c else '_') name

(** Relative path [".masc/playground/<safe_name>/"] (trailing slash). *)
let bundle_root (name : string) : string =
  Printf.sprintf "%s/%s/" all_playgrounds_prefix (sanitize_keeper_name name)

(** Relative path [".masc/playground/<safe_name>/mind/"]. *)
let mind_path (name : string) : string =
  Printf.sprintf "%s/%s/mind/" all_playgrounds_prefix (sanitize_keeper_name name)

(** Relative path [".masc/playground/<safe_name>/repos/"]. *)
let repos_path (name : string) : string =
  Printf.sprintf "%s/%s/repos/" all_playgrounds_prefix (sanitize_keeper_name name)

(** All three bundle subdirs in canonical order. *)
let bundle_paths (name : string) : string list =
  [ bundle_root name; mind_path name; repos_path name ]
