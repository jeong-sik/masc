(** Playground path SSOT.

    Canonical layout for a keeper's playground bundle, relative to the
    server [base_path]:

    - [.masc/playground/<keeper>/]        — bundle root
    - [.masc/playground/<keeper>/repos/]  — git clones (one dir per repo)

    These helpers are the single source of truth. Both [masc_workspace]
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
    ["keeper-example-keeper-agent"] -> ["example-keeper"].

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
(** Sanitize a keeper name into a filesystem-safe component.

    RFC-0393: the keeper name is the only spelling, so no wrapper
    stripping happens here. Allows [A-Za-z0-9._-] and replaces
    everything else with [_]. An empty input or the special path
    components [.] / [..] are replaced with [_], so
    [sanitize_keeper_name ".."] returns ["__"] rather than returning a
    traversal segment as a directory name. *)
(** The [repos] segment inside a keeper's bundle, spelled once. The repo
    tree has a second, unrelated [repos]: the server-side registration
    store under [.masc/repos/<id>] owned by [Config_dir_resolver]. Same
    spelling, different concept — one names the clone directory inside
    one keeper's bundle, the other a store under the server base path.
    They are two constants. *)
let bundle_repos_dirname = "repos"

let sanitize_keeper_name (name : string) : string =
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

type playground_file_path =
  { keeper_name : string
  ; relative_path : string
  }

let parse_playground_file_path ~base_path ~abs_path =
  if Filename.is_relative abs_path then None
  else
    let base =
      let n = String.length base_path in
      if n > 1 && base_path.[n - 1] = '/'
      then String.sub base_path 0 (n - 1)
      else base_path
    in
    let base_with_slash = if String.equal base "/" then base else base ^ "/" in
    if not (String.starts_with ~prefix:base_with_slash abs_path) then None
    else
      let rel =
        String.sub abs_path (String.length base_with_slash)
          (String.length abs_path - String.length base_with_slash)
      in
      let safe_relative keeper_name segments =
        if
          String.equal keeper_name ""
          || segments = []
          || List.exists
               (fun segment ->
                  String.equal segment ""
                  || String.equal segment "."
                  || String.equal segment "..")
               segments
        then None
        else
          Some
            { keeper_name
            ; relative_path = String.concat "/" segments
            }
      in
      match String.split_on_char '/' rel with
      (* Pattern position cannot call a function, so the segment is bound and
         compared against the SSOT in a guard rather than written inline. *)
      | dir :: "playground" :: "docker" :: keeper_name :: segments
        when String.equal dir Common.masc_dirname ->
        safe_relative keeper_name segments
      | dir :: "playground" :: keeper_name :: segments
        when String.equal dir Common.masc_dirname ->
        safe_relative keeper_name segments
      | _ -> None
;;

(* The [repos/<repo_id>/<rel>] anchor inside one keeper's bundle.

   Split out because two callers reach it from different starting points: the
   absolute parser below arrives after stripping the playground prefix, and a
   producer that already knows whose bundle it is holds the bundle-relative
   form directly -- an action_radius target_path is written that way, and the
   sandbox flavour changes where the bundle lives on disk, not what the path
   inside it looks like. Reconstructing an absolute path just to strip it
   again would make the caller assert a layout it does not know. *)
let parse_bundle_relative_repo_path_segments = function
  | "repos" :: repo :: rest when repo <> "" && rest <> [] ->
    Some (repo, String.concat "/" rest)
  | _ -> None
;;

let parse_bundle_relative_repo_path bundle_relative =
  parse_bundle_relative_repo_path_segments (String.split_on_char '/' bundle_relative)
;;

(* The inverse. Written here so the [repos] segment has one spelling: a caller
   that built the path itself would be a second place that decides what the
   anchor looks like, and the parser above would stop being the authority the
   moment they disagreed. *)
let bundle_relative_repo_path ~repo_id relative_path =
  String.concat "/" [ bundle_repos_dirname; repo_id; relative_path ]
;;

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
      (* The Docker reading is tried first and the Local one is the fallback,
         which is what the two ordered patterns used to do. It matters for a
         keeper actually named "docker": [.masc/playground/docker/repos/<id>/x]
         is that keeper's file, and reading the name as the Docker marker would
         lose it. *)
      let after_keeper = function _keeper :: rest -> Some rest | [] -> None in
      let repo_path segments =
        Option.bind (after_keeper segments) parse_bundle_relative_repo_path_segments
      in
      match segs with
      | ".masc" :: "playground" :: rest -> (
        let docker_reading =
          match rest with "docker" :: below -> repo_path below | _ -> None
        in
        match docker_reading with Some found -> Some found | None -> repo_path rest)
      | _ -> None
;;
