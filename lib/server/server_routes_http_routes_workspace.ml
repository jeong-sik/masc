open Server_auth
open Server_utils
open Server_routes_http_pages

module Http = Http_server_eio

let base_path_of_state state = (Mcp_server.workspace_config state).base_path

let sanitize_log_value ?(max_bytes = 240) s =
  let without_controls =
    String.map
      (fun c ->
        let code = Char.code c in
        if code < 0x20 || code = 0x7f then '_' else c)
      s
  in
  String_util.utf8_safe ~max_bytes ~suffix:"..."
    without_controls
  |> String_util.to_string

let observe_workspace_route_failure ?(warn_on_failure = true) ~site ~path exn =
  match exn with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      let site = sanitize_log_value ~max_bytes:64 site in
      let path = sanitize_log_value ~max_bytes:180 path in
      let error = sanitize_log_value (Printexc.to_string exn) in
      Otel_metric_store.inc_counter Otel_metric_store.metric_workspace_route_failures
        ~labels:[("site", site)]
        ();
      if warn_on_failure then
        Log.Server.warn "workspace route %s failed path=%s err=%s"
          site path error
      else
        Log.Server.debug "workspace route %s failed path=%s err=%s"
          site path error

let workspace_or_default ?(warn_on_failure = true) ~site ~path ~default f =
  try f () with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      observe_workspace_route_failure ~warn_on_failure ~site ~path exn;
      default

(* Pure classification of the [?keeper=<name>] query param into a
   workspace base directory plus a source tag.

   Without a keeper name (or with an empty / whitespace-only one) the
   project root is used. With a name, [lookup_playground] returns the
   keeper's private workspace root if the keeper meta is known, and
   [exists_dir] validates that the playground directory is actually
   on disk. Failures fall back to the project root so the IDE always
   renders something and never depends on disk state to draw a tree.

   This split keeps the side-effecting wiring (state -> config,
   Keeper_meta_store.read_meta, Sys.file_exists / Sys.is_directory) at the
   route boundary while the dispatch logic stays unit-testable. *)
let classify_keeper_query
    ~project_base
    ~lookup_playground
    ~exists_dir
    keeper_param =
  match keeper_param with
  | None | Some "" -> (project_base, `Project)
  | Some keeper_name ->
    let trimmed = String.trim keeper_name in
    if trimmed = "" then (project_base, `Project)
    else
      match lookup_playground trimmed with
      | Some playground when exists_dir playground ->
        (playground, `Playground trimmed)
      | Some _ -> (project_base, `PlaygroundMissing trimmed)
      | None -> (project_base, `KeeperUnknown trimmed)

let classify_workspace_query
    ~project_base
    ~lookup_repository
    ~lookup_playground
    ~exists_dir
    ~repo_param
    ~keeper_param =
  match repo_param with
  | Some raw_repo when String.trim raw_repo <> "" ->
    let repo_id = String.trim raw_repo in
    (match lookup_repository repo_id with
     | Some repo_path when exists_dir repo_path ->
       (repo_path, `Repository repo_id)
     | Some _ ->
       (project_base, `RepositoryMissing repo_id)
     | None ->
       (project_base, `RepositoryUnknown repo_id))
  | _ ->
    classify_keeper_query
      ~project_base
      ~lookup_playground
      ~exists_dir
      keeper_param

let resolve_workspace_base ~state ~uri =
  let project_base = base_path_of_state state in
  let config = (Mcp_server.workspace_config state) in
  let lookup_repository repo_id =
    match Repo_store.find ~base_path:project_base repo_id with
    | Ok repo -> Some (Repo_store.local_path ~base_path:project_base repo)
    | Error _ -> None
  in
  let lookup_playground name =
    match Keeper_meta_store.read_meta config name with
    | Ok (Some m) -> Some (Keeper_sandbox.host_root_abs_of_meta ~config m)
    | _ -> None
  in
  let exists_dir p = Sys.file_exists p && Sys.is_directory p in
  classify_workspace_query
    ~project_base
    ~lookup_repository
    ~lookup_playground
    ~exists_dir
    ~repo_param:(Uri.get_query_param uri "repo_id")
    ~keeper_param:(Uri.get_query_param uri "keeper")

let json_error message =
  `Assoc [("ok", `Bool false); ("error", `String message)]

let json_response ~status req reqd json =
  Http.Response.json_value ~status ~request:req json reqd

(* Strip CR/LF and other control characters from a value before placing
   it into an HTTP response header. RFC 7230 §3.2.4 prohibits CR/LF in
   field-value, and an unsanitized name with "\r\nSet-Cookie: ..." would
   let an attacker inject arbitrary headers via the keeper query param. *)
let sanitize_header_value s =
  String.map (fun c ->
    let code = Char.code c in
    if code < 0x20 || code = 0x7f then '_' else c) s

(* Encode the workspace source tag as a single header value so the
   frontend can render hints ("Playground 없음 — 프로젝트로 fallback")
   without parsing the JSON body. *)
let source_header source =
  let v = match source with
    | `Project -> "project"
    | `Repository repo_id -> "repository:" ^ sanitize_header_value repo_id
    | `RepositoryMissing repo_id -> "repository_missing:" ^ sanitize_header_value repo_id
    | `RepositoryUnknown repo_id -> "repository_unknown:" ^ sanitize_header_value repo_id
    | `Playground name -> "playground:" ^ sanitize_header_value name
    | `PlaygroundMissing name -> "playground_missing:" ^ sanitize_header_value name
    | `KeeperUnknown name -> "keeper_unknown:" ^ sanitize_header_value name
  in
  [("X-Workspace-Source", v)]

let json_response_with_source ~status ~source req reqd json =
  Http.Response.json_value ~status ~extra_headers:(source_header source)
    ~request:req json reqd

let json_response_with_source_and_base ~status ~source ~base_path req reqd json =
  let headers = ("X-Workspace-Base-Path", sanitize_header_value base_path)
                :: source_header source in
  Http.Response.json_value ~status ~extra_headers:headers
    ~request:req json reqd

(* --- Safe path --- *)

let is_digit c = c >= '0' && c <= '9'

(* Confidentiality SSOT (task-1734). A single path component is
   confidential when serving or listing it leaks secrets (.env,
   credentials, .ssh) or the agent's internal state (.git config URLs,
   .masc*/ stores). Both guards read this one list so they cannot drift:
   the file read routes reject any request whose path contains a
   confidential component (see [resolve_workspace_path]) and the tree
   listing hides the same components (see [scan_dir]). Anything blocked
   from reads is therefore also hidden from the tree.

   RFC-0128 §4.6 — [.masc-ide/] is keeper metadata about the workspace,
   not workspace content; listing it exposed the agent's annotation
   store to the IDE (leak observed 2026-05-17 against [?repo_id=masc]).
   The [.masc] prefix rule below subsumes both [.masc] and [.masc-ide]. *)
type confidential_rule =
  | Name_equals of string
  | Name_prefix of string
  | Name_contains of string

let confidential_rules =
  [ Name_equals ".git"
  ; Name_prefix Common.masc_dirname (* ".masc" — SSOT #9571; subsumes .masc-ide *)
  ; Name_prefix ".env"
  ; Name_equals ".ssh"
    (* [Name_contains] over-blocks names such as [credentials_guide.md];
       for a secret denylist over-blocking is the safe direction, since a
       false negative would serve a real credentials file. *)
  ; Name_contains "credentials"
  ]

(* Case-insensitive matching: a case-insensitive filesystem (APFS,
   default macOS) resolves [.ENV] to [.env], so a case-sensitive denylist
   would be bypassable by varying case. On a case-sensitive filesystem
   this over-blocks a distinctly-cased non-secret, which is the safe
   direction for a secret denylist. Rule literals are already lowercase. *)
let component_is_confidential component =
  List.exists
    (fun rule ->
      match rule with
      | Name_equals s -> String.equal (String.lowercase_ascii component) s
      | Name_prefix s -> String_util.starts_with_ci ~prefix:s component
      | Name_contains s -> String_util.contains_substring_ci component s)
    confidential_rules

(* Directories excluded from the tree only to reduce noise. These are
   NOT confidential — reads under them are allowed. Confidential entries
   are hidden separately via [component_is_confidential] so the read
   guard and the tree stay in sync from the single SSOT above. *)
let tree_noise_dirs =
  [ "node_modules"; "_build"; ".obsidian"; "__pycache__";
    ".worktrees"; ".cache"; ".tmp"; "dist"; "build" ]

let default_tree_node_limit = 750
let max_tree_node_limit = 2000

(* Strict numeric validator.  OCaml's [int_of_string] accepts forms
   that we want to reject ("1_" -> 1, "1__2" -> 12) because they let
   malformed inputs request meaningful tree sizes.  This validator
   mirrors what an operator would reasonably expect of a [limit=]
   query parameter: optional sign, at least one decimal digit,
   underscores only between digits.  When this returns [false] we
   fall back to the default regardless of what [int_of_string_opt]
   would have produced. *)
let is_strict_decimal_int_string s =
  let len = String.length s in
  if len = 0 then false
  else
    let start = if s.[0] = '-' || s.[0] = '+' then 1 else 0 in
    if start >= len then false
    else if Char.equal s.[start] '_' || Char.equal s.[len - 1] '_' then false
    else
      let ok = ref true in
      let has_digit = ref false in
      let prev_was_underscore = ref false in
      for i = start to len - 1 do
        let c = s.[i] in
        if c >= '0' && c <= '9' then begin
          has_digit := true;
          prev_was_underscore := false
        end else if c = '_' then begin
          if !prev_was_underscore then ok := false;
          prev_was_underscore := true
        end else begin
          ok := false;
          prev_was_underscore := false
        end
      done;
      !ok && !has_digit

let tree_node_limit_of_query = function
  | Some raw ->
      (* Reject malformed numerics up front so that "1_" / "1__2" /
         "_1" are treated as junk and fall back to default, even
         though [int_of_string_opt] would otherwise accept them. *)
      if not (is_strict_decimal_int_string raw) then default_tree_node_limit
      else (
        match int_of_string_opt raw with
        | Some n -> max 1 (min max_tree_node_limit n)
        | None ->
            (* Issue #13191 follow-up: parse failure on a strict
               numeric input means the value overflowed [int].  A
               request like [?limit=99999999999999999999] used to fall
               back to [default_tree_node_limit] (750) instead of
               clamping to [max_tree_node_limit] (2000), so clients
               asking for "very large" got fewer nodes than a
               smaller-but-valid request would.  Positive overflow
               clamps to the maximum; negative overflow mirrors the
               existing in-range "clamps low" behaviour and pins to 1. *)
            let is_negative =
              String.length raw > 0 && Char.equal raw.[0] '-'
            in
            if is_negative then 1 else max_tree_node_limit)
  | None -> default_tree_node_limit

(* Resolve symlinks in [path], tolerating a non-existent final component
   so a deleted file (still shown by [git diff]) and a missing file
   (which must reach the route's 404) resolve to a lexical path instead
   of raising. Mirrors the existing-prefix realpath idiom in
   [Eval_calibration]; kept local to avoid a server -> eval_calibration
   dependency. *)
let rec resolve_existing_prefix path =
  try Fs_compat.realpath path with
  | Unix.Unix_error _ | Invalid_argument _ | Sys_error _ ->
    let parent = Filename.dirname path in
    if String.equal parent path then path
    else
      Filename.concat (resolve_existing_prefix parent) (Filename.basename path)

let path_within ~base candidate =
  String.equal candidate base
  ||
  let base_slash =
    let n = String.length base in
    if n > 0 && base.[n - 1] = '/' then base else base ^ "/"
  in
  String.starts_with ~prefix:base_slash candidate

let components_under ~base candidate =
  if String.equal candidate base then []
  else
    let base_slash =
      let n = String.length base in
      if n > 0 && base.[n - 1] = '/' then base else base ^ "/"
    in
    if String.starts_with ~prefix:base_slash candidate
    then
      String.sub candidate (String.length base_slash) (String.length candidate - String.length base_slash)
      |> String.split_on_char '/'
      |> List.filter (fun part -> not (String.equal part ""))
    else []

type path_rejection =
  | Path_traversal
  | Confidential_component of string
  | Symlink_escape

type path_resolution =
  | Path_ok of string
  | Path_rejected of path_rejection

type workspace_file = {
  lexical_path : string;
  resolved_base : string;
  resolved_path : string;
}

type workspace_file_read_error =
  | File_not_found
  | File_not_regular
  | File_changed_during_open
  | File_too_large of int
  | File_read_failed of string

let workspace_file_read_max_bytes = Env_config_runtime.Workspace_file.max_read_bytes

(* Resolve [requested] (a slash-separated path relative to [base]) into
   an absolute path guaranteed to stay within [base], or a typed
   rejection. Guards, in order:
   1. parent traversal ([..]/[.]) or a lexical prefix escape,
   2. a confidential component (secret denylist SSOT), and
   3. a symlink whose real target resolves outside [base] (B2).
   [resolve_workspace_file] carries both paths: the lexical path under
   [base] for Git pathspecs, and the realpath-resolved target for file
   I/O.  The compatibility wrapper [resolve_workspace_path] preserves
   the older lexical [Path_ok] contract used by tests and callers that
   only need admission control. *)
let resolve_workspace_file base requested =
  let requested = String.map (fun c -> if c = '\\' then '/' else c) requested in
  let parts = String.split_on_char '/' requested in
  let is_traversal p = String.equal p ".." || String.equal p "." in
  if List.exists is_traversal parts then Error Path_traversal
  else
    match List.find_opt component_is_confidential parts with
    | Some c -> Error (Confidential_component c)
    | None ->
      let full = List.fold_left (fun acc p -> Filename.concat acc p) base parts in
      if not (path_within ~base full) then
        Error Path_traversal
      else
        let resolved_base = resolve_existing_prefix base in
        let resolved_full = resolve_existing_prefix full in
        if not (path_within ~base:resolved_base resolved_full) then
          Error Symlink_escape
        else
          match
            components_under ~base:resolved_base resolved_full
            |> List.find_opt component_is_confidential
          with
          | Some c -> Error (Confidential_component c)
          | None ->
            Ok
              {
                lexical_path = full;
                resolved_base;
                resolved_path = resolved_full;
              }

let resolve_workspace_path base requested =
  match resolve_workspace_file base requested with
  | Ok file -> Path_ok file.lexical_path
  | Error rejection -> Path_rejected rejection

let run_blocking_file_io f =
  try Eio_unix.run_in_systhread ~label:"workspace-file-read" f with
  | Stdlib.Effect.Unhandled _ -> f ()

let same_file_identity a b =
  a.Unix.st_dev = b.Unix.st_dev
  && a.Unix.st_ino = b.Unix.st_ino

let read_fd_to_string fd len =
  let buf = Bytes.create len in
  let rec loop offset =
    if offset >= len then Bytes.unsafe_to_string buf
    else
      let n = Unix.read fd buf offset (len - offset) in
      if n = 0 then Bytes.sub_string buf 0 offset
      else loop (offset + n)
  in
  loop 0

let load_workspace_file_content ?(max_bytes = workspace_file_read_max_bytes) file =
  run_blocking_file_io (fun () ->
    try
      let before_open = Unix.lstat file.resolved_path in
      match before_open.Unix.st_kind with
      | Unix.S_REG ->
        let fd =
          Unix.openfile file.resolved_path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0
        in
        Fun.protect
          ~finally:(fun () -> try Unix.close fd with Unix.Unix_error _ -> ())
          (fun () ->
            let after_open = Unix.fstat fd in
            if
              (not (same_file_identity before_open after_open))
              || after_open.Unix.st_kind <> Unix.S_REG
            then Error File_changed_during_open
            else if after_open.Unix.st_size > max_bytes then
              Error (File_too_large after_open.Unix.st_size)
            else Ok (read_fd_to_string fd after_open.Unix.st_size))
      | Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK | Unix.S_LNK ->
        Error File_not_regular
    with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> Error File_not_found
    | Unix.Unix_error _ as exn -> Error (File_read_failed (Printexc.to_string exn))
    | Sys_error msg -> Error (File_read_failed msg))

(* Strip [base] (and the following separator) from [safe]. Handles
   [base = "/"], trailing slash on [base], and [safe = base] (returns "").
   Assumes [resolve_workspace_path] has already enforced the prefix
   invariant. *)
let rel_under base safe =
  if safe = base then ""
  else
    let base_norm =
      let n = String.length base in
      if n > 0 && base.[n - 1] = '/' then base else base ^ "/"
    in
    let bn = String.length base_norm in
    if String.length safe >= bn && String.starts_with ~prefix:base_norm safe
    then String.sub safe bn (String.length safe - bn)
    else safe

(* Reject anything that could be parsed by git as an option (leading
   "-") or that contains separators outside the conservative ref/SHA +
   revision-syntax charset. Defense against `?base_ref=-L1,9999` style
   injection even on git versions that lack [--end-of-options].

   Charset rationale:
   - alphanumerics + [._/-]: ordinary ref/branch/tag names
   - [~^@]: revision-syntax suffix operators (HEAD~1, HEAD^, @{u})
   - [+]: valid in branch names per [git check-ref-format]
   - [{}]: needed for [@{upstream}] / [HEAD@{1}] expressions
   Excluded: [: ! ? * \ space NUL] — separators with shell or git
   pathspec semantics that callers should not need in [base_ref]. *)
let valid_git_ref s =
  let n = String.length s in
  n > 0 && n <= 256 && s.[0] <> '-'
  && String.for_all (fun c ->
       (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
       || (c >= '0' && c <= '9')
       || c = '/' || c = '.' || c = '_' || c = '-'
       || c = '~' || c = '^' || c = '@' || c = '+'
       || c = '{' || c = '}')
       s

(* --- Recursive file tree --- *)

let file_tree_node ~diff_by_path ~path ~label ~depth ~parent ~has_children =
  let diff =
    match diff_by_path with
    | Some diff_by_path when not has_children ->
      (match Hashtbl.find_opt diff_by_path path with
       | Some badge -> `String badge
       | None -> `Null)
    | _ -> `Null
  in
  `Assoc [ ("path", `String path); ("label", `String label)
         ; ("depth", `Int depth); ("parent", `String parent)
         ; ("hasChildren", `Bool has_children)
         ; ("diff", diff); ("keeperId", `Null); ("hueIndex", `Null) ]

let rec scan_dir_bounded ?diff_by_path ~base ~depth ~max_depth ~remaining acc dir =
  if depth > max_depth || remaining <= 0 then (acc, remaining)
  else
    let raw_entries =
      workspace_or_default
        ~site:"tree_readdir"
        ~path:dir
        ~default:[]
        (fun () -> Sys.readdir dir |> Array.to_list)
    in
    (* Sort alphabetically, then partition directories-first so that
       the node limit (default 750) is consumed by directory trees
       (lib/, src/) before leaf files ( *.py, *.md).  Without this,
       a flat directory like ~/me with hundreds of root-level files
       exhausts the limit before important subdirectories appear. *)
    let entries =
      let sorted = List.sort String.compare raw_entries in
      let dirs, files = List.partition (fun name ->
        let full = Filename.concat dir name in
        workspace_or_default
          ~warn_on_failure:false
          ~site:"tree_is_directory_partition"
          ~path:full
          ~default:false
          (fun () -> Sys.is_directory full)
      ) sorted in
      dirs @ files
    in
    let rec fold acc remaining = function
      | [] -> (acc, remaining)
      | _ when remaining <= 0 -> (acc, 0)
      | f :: rest ->
        if f = "." || f = ".." then fold acc remaining rest
        else if component_is_confidential f || List.mem f tree_noise_dirs then
          fold acc remaining rest
        else
          let full = Filename.concat dir f in
          let is_dir =
            workspace_or_default
              ~warn_on_failure:false
              ~site:"tree_is_directory"
              ~path:full
              ~default:false
              (fun () ->
                 match Unix.lstat full with
                 | { Unix.st_kind = Unix.S_LNK; _ } -> false
                 | _ -> Sys.is_directory full)
          in
          let rel = rel_under base full in
          (* With /api/v1/workspace/children lazy-loading a directory's entries
             on first expand, a directory is expandable regardless of the
             initial scan depth. Decoupling [has_children] from
             [depth < max_depth] keeps the chevron on boundary directories; the
             recursion guard below stays depth-bounded, so the initial scan
             shape is unchanged and only the boundary display flag flips. *)
          let has_children = is_dir in
          let parent = if depth = 0 then "" else Filename.dirname rel in
          let node = file_tree_node ~diff_by_path
              ~path:rel ~label:f ~depth ~parent ~has_children in
          let acc' = node :: acc in
          let remaining' = remaining - 1 in
          let acc'', remaining'' =
            if is_dir && depth < max_depth then
              scan_dir_bounded
                ?diff_by_path
                ~base ~depth:(depth + 1) ~max_depth ~remaining:remaining'
                acc' full
            else (acc', remaining')
          in
          fold acc'' remaining'' rest
    in
    fold acc remaining entries

let scan_dir ?diff_by_path ~base ~depth ~max_depth ~max_nodes acc dir =
  fst (scan_dir_bounded ?diff_by_path ~base ~depth ~max_depth ~remaining:max_nodes acc dir)

(* --- Git helpers --- *)

let git_run_lines ~cwd args =
  match Repo_git.run_git ~cwd ("--no-optional-locks" :: args) with
  | Ok lines -> lines
  | Error msg ->
      observe_workspace_route_failure
        ~site:"git_run"
        ~path:cwd
        (Failure msg);
      []

let diff_badge_of_numstat ~added ~deleted =
  match int_of_string_opt added, int_of_string_opt deleted with
  | Some added, Some deleted ->
    let parts =
      (if added > 0 then [Printf.sprintf "+%d" added] else [])
      @ (if deleted > 0 then [Printf.sprintf "-%d" deleted] else [])
    in
    (match parts with
     | [] -> None
     | _ -> Some (String.concat " " parts))
  | _ when String.equal added "-" && String.equal deleted "-" -> Some "bin"
  | _ -> None

let parse_git_numstat_line line =
  match String.split_on_char '\t' line with
  | added :: deleted :: path_parts ->
    let path = String.concat "\t" path_parts in
    if path = "" then None
    else
      (match diff_badge_of_numstat ~added ~deleted with
       | Some badge -> Some (path, badge)
       | None -> None)
  | _ -> None

let git_diff_badges ~base =
  let badges = Hashtbl.create 32 in
  git_run_lines ~cwd:base ["diff"; "--numstat"; "HEAD"; "--"]
  |> List.iter (fun line ->
       match parse_git_numstat_line line with
       | Some (path, badge) -> Hashtbl.replace badges path badge
       | None -> ());
  badges

(* Surface git failure to the caller instead of collapsing to []. Lets
   route handlers distinguish "command errored / invalid ref" from
   "command succeeded with no output". *)
let git_run_lines_or_error ~cwd args =
  Repo_git.run_git ~cwd ("--no-optional-locks" :: args)

module For_testing = struct
  let sanitize_log_value = sanitize_log_value
  let observe_workspace_route_failure = observe_workspace_route_failure
  let parse_git_numstat_line = parse_git_numstat_line
  type safe_workspace_file = workspace_file
  let resolve_workspace_file = resolve_workspace_file
  let load_workspace_file_content = load_workspace_file_content
end

(* --- Blame parsing: collect per-line then group adjacent same-author ranges --- *)

type blame_entry = { bl_line: int; bl_author: string; bl_time: int64 }

let parse_blame_porcelain lines =
  let rec go cur_author cur_time acc remaining =
    match remaining with
    | [] -> List.rev acc
    | hd :: tl ->
      if String.starts_with ~prefix:"author " hd then
        let a = String.sub hd 7 (String.length hd - 7) in
        go (Some a) cur_time acc tl
      else if String.starts_with ~prefix:"author-time " hd then
        let ts = String.sub hd 12 (String.length hd - 12) in
        (match Int64.of_string_opt ts with
         | Some n -> go cur_author (Some n) acc tl
         | None -> go cur_author cur_time acc tl)
      else if String.length hd > 0 && is_digit (String.get hd 0)
              && String.contains hd ' ' then
        let sp = String.index hd ' ' in
        let line_num_str = String.sub hd 0 sp in
        (match int_of_string_opt line_num_str with
         | Some ln ->
           let a = Option.value cur_author ~default:"unknown" in
           let t = Option.value cur_time ~default:0L in
           go cur_author cur_time ({ bl_line = ln; bl_author = a; bl_time = t } :: acc) tl
         | None -> go cur_author cur_time acc tl)
      else
        go cur_author cur_time acc tl
  in
  go None None [] lines

let blame_entry_to_json file_path ~line_start ~line_end ~author ~time =
  `Assoc [ ("file_path", `String file_path)
         ; ("line_start", `Int line_start); ("line_end", `Int line_end)
         ; ("keeper_id", `String author)
         ; ("timestamp_ms", `Int (Int64.to_int time * 1000))
         ; ("kind", `String "edit") ]

let group_blame_entries file_path entries =
  let sorted = List.sort (fun a b -> compare a.bl_line b.bl_line) entries in
  let rec go current_start current_end current_author current_time acc remaining =
    match remaining with
    | [] ->
      (match current_start with
       | Some s ->
         let json = blame_entry_to_json file_path
           ~line_start:s ~line_end:current_end
           ~author:current_author ~time:current_time in
         List.rev (json :: acc)
       | None -> List.rev acc)
    | hd :: tl ->
      match current_start with
      | Some s when hd.bl_author = current_author && hd.bl_line = current_end + 1 ->
        go (Some s) hd.bl_line current_author hd.bl_time acc tl
      | Some s ->
        let json = blame_entry_to_json file_path
          ~line_start:s ~line_end:current_end
          ~author:current_author ~time:current_time in
        go (Some hd.bl_line) hd.bl_line hd.bl_author hd.bl_time (json :: acc) tl
      | None ->
        go (Some hd.bl_line) hd.bl_line hd.bl_author hd.bl_time acc tl
  in
  go None 0 "" 0L [] sorted

(* --- Diff parsing --- *)

let parse_hunk_header line =
  if not (String.starts_with ~prefix:"@@ -" line) then None
  else
    let rest = String.sub line 4 (String.length line - 4) in
    let sp_idx =
      let rec find i =
        if i >= String.length rest then String.length rest
        else if String.get rest i = ' ' then i
        else find (i + 1)
      in
      find 0
    in
    if sp_idx >= String.length rest then None
    else
      let old_part = String.sub rest 0 sp_idx in
      let new_rest = String.sub rest (sp_idx + 1) (String.length rest - sp_idx - 1) in
      let plus_idx =
        let rec find i =
          if i >= String.length new_rest then String.length new_rest
          else if String.get new_rest i = ' ' then i
          else find (i + 1)
        in
        find 0
      in
      let new_part = String.sub new_rest 0 plus_idx in
      let parse_start s =
        match String.split_on_char ',' s with
        | x :: _ -> Option.value (int_of_string_opt x) ~default:1
        | [] -> 1
      in
      Some (parse_start old_part, parse_start new_part)

let parse_unified_diff lines =
  let rec go old_line new_line acc remaining =
    match remaining with
    | [] -> List.rev acc
    | hd :: tl ->
      if String.starts_with ~prefix:"@@" hd then
        (match parse_hunk_header hd with
         | Some (ol, nl) -> go ol nl acc tl
         | None -> go old_line new_line acc tl)
      else if String.starts_with ~prefix:"+++" hd
           || String.starts_with ~prefix:"---" hd then
        go old_line new_line acc tl
      else if String.starts_with ~prefix:"+" hd then
        let text = String.sub hd 1 (max 0 (String.length hd - 1)) in
        let row = `Assoc [ ("kind", `String "add")
                         ; ("oldLine", `Null); ("newLine", `Int new_line)
                         ; ("text", `String text) ] in
        go old_line (new_line + 1) (row :: acc) tl
      else if String.starts_with ~prefix:"-" hd then
        let text = String.sub hd 1 (max 0 (String.length hd - 1)) in
        let row = `Assoc [ ("kind", `String "delete")
                         ; ("oldLine", `Int old_line); ("newLine", `Null)
                         ; ("text", `String text) ] in
        go (old_line + 1) new_line (row :: acc) tl
      else if String.starts_with ~prefix:" " hd then
        let text = String.sub hd 1 (max 0 (String.length hd - 1)) in
        let row = `Assoc [ ("kind", `String "context")
                         ; ("oldLine", `Int old_line); ("newLine", `Int new_line)
                         ; ("text", `String text) ] in
        go (old_line + 1) (new_line + 1) (row :: acc) tl
      else
        go old_line new_line acc tl
  in
  go 1 1 [] lines

(* --- Routes --- *)

let add_routes router =
  router
  |> Http.Router.get "/api/v1/workspace/tree" (fun request reqd ->
       with_public_read
         (fun state _req reqd ->
           let uri = Uri.of_string request.target in
           let base, source = resolve_workspace_base ~state ~uri in
           let depth =
             match Uri.get_query_param uri "depth" with
             | Some d ->
               (match int_of_string_opt d with
                | Some n -> max 1 (min 5 n)
                | None -> 3)
             | None -> 3
           in
           let max_nodes =
             tree_node_limit_of_query (Uri.get_query_param uri "limit")
           in
           let include_diff = bool_query_param request "diff" ~default:false in
           let effective_depth, effective_max_nodes =
             match source with
             | `Project
             | `RepositoryMissing _
             | `RepositoryUnknown _
             | `PlaygroundMissing _
             | `KeeperUnknown _ -> (0, min max_nodes 200)
             | `Repository _ | `Playground _ -> (depth, max_nodes)
           in
           let cache_key =
             Printf.sprintf "workspace:tree:%s:%s:%d:%d:%b"
               base
               (match source with
                | `Project -> "project"
                | `Repository repo_id -> "repository:" ^ repo_id
                | `RepositoryMissing repo_id -> "repository_missing:" ^ repo_id
                | `RepositoryUnknown repo_id -> "repository_unknown:" ^ repo_id
                | `Playground name -> "playground:" ^ name
                | `PlaygroundMissing name -> "playground_missing:" ^ name
                | `KeeperUnknown name -> "keeper_unknown:" ^ name)
               effective_depth effective_max_nodes include_diff
           in
           let json =
             Dashboard_cache.get_or_compute cache_key
               ~ttl:Server_dashboard_http_core_cache.realtime_cache_ttl_s
               (fun () ->
                  Domain_pool_ref.submit_io_or_inline (fun () ->
                    let nodes =
                      if not (Sys.file_exists base) then []
                      else
                        let diff_by_path =
                          if include_diff then Some (git_diff_badges ~base)
                          else None
                        in
                        scan_dir ?diff_by_path ~base ~depth:0
                          ~max_depth:effective_depth
                          ~max_nodes:effective_max_nodes [] base
                    in
                    `List (List.rev nodes)))
           in
           json_response_with_source_and_base
             ~status:`OK ~source ~base_path:base request reqd json)
         request reqd)

  |> Http.Router.get "/api/v1/workspace/children" (fun request reqd ->
       (* Lazy tree: return exactly one level of a directory's entries so the
          IDE can expand deep trees on demand instead of relying on the single
          bounded /tree snapshot (which, for the [project] workspace source, is
          root-only). [base] stays the whole workspace base and only [dir] is
          the subpath, so each node's path/parent/depth stay anchored to the
          whole tree and merge into the client's flat node array. *)
       with_public_read
         (fun state _req reqd ->
           let uri = Uri.of_string request.target in
           let base, source = resolve_workspace_base ~state ~uri in
           match Uri.get_query_param uri "path" with
           | None ->
             json_response ~status:`Bad_request request reqd
               (json_error "Missing path parameter")
           | Some requested ->
             (* Same admission control as /file, /blame, /diff: uniform
                [Invalid path] on traversal / confidential / symlink escape so a
                caller cannot probe which subpaths exist or are secret. *)
             (match resolve_workspace_file base requested with
              | Error _ ->
                json_response ~status:`Bad_request request reqd
                  (json_error "Invalid path")
              | Ok file ->
                let max_nodes =
                  tree_node_limit_of_query (Uri.get_query_param uri "limit")
                in
                (* A rel path with N non-empty segments sits at depth N-1, so
                   its children are at depth N. Passing ~depth = ~max_depth =
                   child_depth reads exactly one level (the recursion guard
                   [depth < max_depth] is false), while [rel_under base] keeps
                   path/parent anchored to the whole tree. *)
                let child_depth =
                  rel_under base file.lexical_path
                  |> String.split_on_char '/'
                  |> List.filter (fun s -> not (String.equal s ""))
                  |> List.length
                in
                let cache_key =
                  Printf.sprintf "workspace:children:%s:%s:%d:%d"
                    base file.lexical_path child_depth max_nodes
                in
                let json =
                  Dashboard_cache.get_or_compute cache_key
                    ~ttl:Server_dashboard_http_core_cache.realtime_cache_ttl_s
                    (fun () ->
                       Domain_pool_ref.submit_io_or_inline (fun () ->
                         let is_dir =
                           workspace_or_default
                             ~warn_on_failure:false
                             ~site:"children_is_directory"
                             ~path:file.lexical_path
                             ~default:false
                             (fun () -> Sys.is_directory file.lexical_path)
                         in
                         if not is_dir then `List []
                         else
                           let nodes =
                             scan_dir ~base ~depth:child_depth
                               ~max_depth:child_depth ~max_nodes []
                               file.lexical_path
                           in
                           `List (List.rev nodes)))
                in
                json_response_with_source_and_base
                  ~status:`OK ~source ~base_path:base request reqd json))
         request reqd)

  |> Http.Router.get "/api/v1/workspace/file" (fun request reqd ->
       with_public_read
         (fun state _req reqd ->
           let uri = Uri.of_string request.target in
           let base, source = resolve_workspace_base ~state ~uri in
           match Uri.get_query_param uri "path" with
           | None -> json_response ~status:`Bad_request request reqd (json_error "Missing path parameter")
           | Some p ->
             (match resolve_workspace_file base p with
              | Error _ ->
                (* Uniform [Invalid path] for traversal, confidential, and
                   symlink-escape rejections: a distinct message would let
                   a caller probe which paths are secret or exist. *)
                json_response ~status:`Bad_request request reqd (json_error "Invalid path")
              | Ok file ->
                (match load_workspace_file_content file with
                 | Ok content ->
                   let json = `Assoc [("ok", `Bool true); ("content", `String content)] in
                   json_response_with_source ~status:`OK ~source request reqd json
                 | Error File_not_found | Error File_not_regular ->
                   json_response ~status:`Not_found request reqd (json_error "File not found")
                 | Error File_changed_during_open ->
                   json_response ~status:`Bad_request request reqd (json_error "Invalid path")
                 | Error (File_too_large _) ->
                   json_response ~status:`Payload_too_large request reqd (json_error "File too large")
                 | Error (File_read_failed msg) ->
                   observe_workspace_route_failure
                     ~site:"file_read"
                     ~path:file.lexical_path
                     (Failure msg);
                   json_response ~status:`Internal_server_error request reqd (json_error "Failed to read file"))))
         request reqd)

  |> Http.Router.get "/api/v1/git/blame" (fun request reqd ->
       with_public_read
         (fun state _req reqd ->
           let uri = Uri.of_string request.target in
           let base, source = resolve_workspace_base ~state ~uri in
           let file_path =
             match Uri.get_query_param uri "path" with
             | Some p -> p
             | None -> ""
           in
           if file_path = "" then
             json_response ~status:`Bad_request request reqd (json_error "Missing path parameter")
           else
             (match resolve_workspace_file base file_path with
              | Error _ ->
                json_response ~status:`Bad_request request reqd (json_error "Invalid path")
              | Ok safe ->
                if not (Sys.file_exists safe.resolved_path) then
                  json_response ~status:`Not_found request reqd (json_error "File not found")
                else
                  let rel = rel_under base safe.lexical_path in
                  let cache_key =
                    Printf.sprintf "git:blame:%s:%s:%s"
                      base
                      (match source with
                       | `Project -> "project"
                       | `Repository repo_id -> "repository:" ^ repo_id
                       | `RepositoryMissing repo_id -> "repository_missing:" ^ repo_id
                       | `RepositoryUnknown repo_id -> "repository_unknown:" ^ repo_id
                       | `Playground name -> "playground:" ^ name
                       | `PlaygroundMissing name -> "playground_missing:" ^ name
                       | `KeeperUnknown name -> "keeper_unknown:" ^ name)
                      rel
                  in
                  let json =
                    Dashboard_cache.get_or_compute cache_key
                      ~ttl:Server_dashboard_http_core_cache.realtime_cache_ttl_s
                      (fun () ->
                         Domain_pool_ref.submit_io_or_inline (fun () ->
                           match git_run_lines ~cwd:base
                                   ["blame"; "--porcelain"; "--"; rel]
                           with
                           | [] -> `List []
                           | lines ->
                             let entries = parse_blame_porcelain lines in
                             let grouped = group_blame_entries rel entries in
                             `List grouped))
                  in
                  json_response_with_source ~status:`OK ~source request reqd json))
         request reqd)

  |> Http.Router.get "/api/v1/git/diff" (fun request reqd ->
       with_public_read
         (fun state _req reqd ->
            let uri = Uri.of_string request.target in
            let base, source = resolve_workspace_base ~state ~uri in
            let file_path =
              match Uri.get_query_param uri "path" with
              | Some p -> p
              | None -> ""
            in
            if file_path = "" then
              json_response ~status:`Bad_request request reqd (json_error "Missing path parameter")
            else
              let base_ref =
                match Uri.get_query_param uri "base_ref" with
                | Some r -> r
                | None -> "HEAD"
              in
              if not (valid_git_ref base_ref) then
                json_response ~status:`Bad_request request reqd
                  (json_error "Invalid base_ref")
              else
              (match resolve_workspace_file base file_path with
               | Error _ ->
                 json_response ~status:`Bad_request request reqd (json_error "Invalid path")
               | Ok safe ->
                 let rel = rel_under base safe.lexical_path in
                 let cache_key =
                   Printf.sprintf "git:diff:%s:%s:%s:%s"
                     base
                     (match source with
                      | `Project -> "project"
                      | `Repository repo_id -> "repository:" ^ repo_id
                      | `RepositoryMissing repo_id -> "repository_missing:" ^ repo_id
                      | `RepositoryUnknown repo_id -> "repository_unknown:" ^ repo_id
                      | `Playground name -> "playground:" ^ name
                      | `PlaygroundMissing name -> "playground_missing:" ^ name
                      | `KeeperUnknown name -> "keeper_unknown:" ^ name)
                     base_ref
                     rel
                 in
                 let json =
                   Dashboard_cache.get_or_compute cache_key
                     ~ttl:Server_dashboard_http_core_cache.realtime_cache_ttl_s
                     (fun () ->
                        Domain_pool_ref.submit_io_or_inline (fun () ->
                          match git_run_lines_or_error ~cwd:base
                                  ["diff"; base_ref; "--"; rel]
                          with
                          | Error _ ->
                            `Assoc [("ok", `Bool false); ("error", `String "git diff failed")]
                          | Ok [] ->
                            `Assoc [("ok", `Bool true); ("data", `Assoc [("unified", `List []); ("has_changes", `Bool false)])]
                          | Ok diff_lines ->
                            let unified = parse_unified_diff diff_lines in
                            `Assoc [("ok", `Bool true); ("data", `Assoc [("unified", `List unified); ("has_changes", `Bool true)])]))
                 in
                 (match json with
                  | `Assoc fields ->
                    (match List.assoc_opt "ok" fields with
                     | Some (`Bool true) ->
                       let data = List.assoc "data" fields in
                       json_response_with_source ~status:`OK ~source request reqd data
                     | _ ->
                       json_response ~status:`Bad_request request reqd
                         (json_error "git diff failed"))
                  | _ ->
                    json_response ~status:`Bad_request request reqd
                      (json_error "git diff failed"))))
         request reqd)
