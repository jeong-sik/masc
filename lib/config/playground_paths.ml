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
    server's [base_path].  Built from {!Common.masc_dirname} so the
    literal ["".masc""] lives in a single place
    ([Common.masc_dirname]); this module remains the SSOT for the
    [<.masc>/playground] sub-tree. *)
let all_playgrounds_prefix : string =
  Filename.concat Common.masc_dirname "playground"

(** Strip the [keeper-...-agent] canonical wrapper when present,
    returning the inner short name.  E.g.
    ["keeper-masc-improver-agent"] -> ["masc-improver"].

    The MCP session resolver generates canonical names via
    [keeper_agent_name] in [keeper_types_profile.ml], but playground
    directories on disk use the short form ([meta.name]).  Without
    stripping, path lookups produce
    [.masc/playground/keeper-X-agent/repos/] which does not exist;
    the actual directory is [.masc/playground/X/repos/].

    A name that does not match the wrapper pattern is returned
    unchanged.  The function is idempotent:
    [strip (strip x) = strip x].

    The length guard [nlen > plen + slen] (i.e., > 13) ensures we
    never produce an empty string from stripping — ["keeper-agent"]
    (12 chars) passes through unchanged because its inner part would
    be empty. *)
let strip_keeper_agent_wrapper (name : string) : string =
  let prefix = "keeper-" and suffix = "-agent" in
  let plen = String.length prefix and slen = String.length suffix in
  let nlen = String.length name in
  if nlen > plen + slen
     && String.starts_with ~prefix name
     && String.ends_with ~suffix name
  then String.sub name plen (nlen - plen - slen)
  else name

(** Sanitize a keeper name into a filesystem-safe component.

    First strips the [keeper-...-agent] canonical wrapper (see
    {!strip_keeper_agent_wrapper}) so that both ["keeper-X-agent"]
    and ["X"] resolve to the same directory.  Then allows
    [A-Za-z0-9._-] and replaces everything else with [_]. An empty
    input or the special path components [.] / [..] are replaced with
    [_], so [sanitize_keeper_name ".."] returns ["__"] rather than
    returning a traversal segment as a directory name. *)
let sanitize_keeper_name (name : string) : string =
  let name = strip_keeper_agent_wrapper name in
  let mapped =
    String.map (fun c ->
      if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
         || (c >= '0' && c <= '9') || c = '-' || c = '_' || c = '.'
      then c else '_') name
  in
  match mapped with
  | "" -> "_"
  | "." -> "_"
  | ".." -> "__"
  | _ -> mapped

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

(* RFC-0128 §4.5 — parse a sandbox playground absolute file path back
   into [(repo_id, rel_path)]. Used by the keeper write path so that
   files keepers edit inside their per-keeper repo clones map to the
   same canonical-URL bucket as files in the user's working tree.

   Layout matched (relative to [base_path]):

     .masc/playground/<keeper>/repos/<repo_id>/<rel>           — Local
     .masc/playground/docker/<keeper>/repos/<repo_id>/<rel>    — Docker

   The function is structural: it only accepts paths anchored at the
   [.masc/playground/] subtree root. Anything outside that subtree, or
   paths that stop before the [repos/<id>/<rel>] anchor, return [None]. *)
let parse_playground_repo_path ~base_path ~abs_path =
  if Filename.is_relative abs_path then None
  else
    let base =
      let n = String.length base_path in
      if n > 0 && base_path.[n - 1] = '/'
      then String.sub base_path 0 (n - 1)
      else base_path
    in
    let base_with_slash = base ^ "/" in
    if not (String.starts_with ~prefix:base_with_slash abs_path) then None
    else
      let rel =
        String.sub abs_path (String.length base_with_slash)
          (String.length abs_path - String.length base_with_slash)
      in
      let segs = String.split_on_char '/' rel in
      (* Require the ".masc" + "playground" prefix at the base-relative
         root, then parse the accepted layouts structurally. Do not scan
         for a later "repos" segment: keeper names can themselves be
         "repos", and repository working trees may legitimately contain
         nested ".masc/playground" directories.
         Layouts accepted:
           .masc/playground/<keeper>/repos/<id>/<rel>          (Local)
           .masc/playground/docker/<keeper>/repos/<id>/<rel>   (Docker) *)
      match segs with
      | ".masc" :: "playground" :: rest -> (
        match rest with
        | "docker" :: _keeper :: "repos" :: repo :: r
          when repo <> "" && r <> [] ->
          Some (repo, String.concat "/" r)
        | _keeper :: "repos" :: repo :: r when repo <> "" && r <> [] ->
          Some (repo, String.concat "/" r)
        | _ -> None)
      | _ -> None
;;

(** {1 Worktree Naming}

    Worktree directory names and git branch names for keeper task
    isolation.  [room_worktree.ml] and [worktree_remove_r] delegate
    here so the naming convention exists in one place. *)

(** Worktree directory name under [.worktrees/]:
    ["<agent_name>-<task_id>"].  The caller is responsible for passing
    either a raw or sanitized agent name — this function formats only.

    Example: [worktree_dir_name "sangsu" "fix-bug"] -> ["sangsu-fix-bug"]. *)
let worktree_dir_name (agent_name : string) (task_id : string) : string =
  Printf.sprintf "%s-%s" agent_name task_id

(** Git branch name for a keeper worktree:
    ["<agent_name>/<task_id>"].

    Example: [worktree_branch_name "sangsu" "fix-bug"] -> ["sangsu/fix-bug"]. *)
let worktree_branch_name (agent_name : string) (task_id : string) : string =
  Printf.sprintf "%s/%s" agent_name task_id
