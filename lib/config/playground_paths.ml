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
