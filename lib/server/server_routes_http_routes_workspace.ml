open Server_auth
open Server_utils
open Server_routes_http_pages

module Http = Http_server_eio

let base_path_of_state state = state.Mcp_server.room_config.base_path

(* Pure classification of the [?keeper=<name>] query param into a
   workspace base directory plus a source tag.

   Without a keeper name (or with an empty / whitespace-only one) the
   project root is used. With a name, [lookup_playground] returns the
   keeper's private workspace root if the keeper meta is known, and
   [exists_dir] validates that the playground directory is actually
   on disk. Failures fall back to the project root so the IDE always
   renders something and never depends on disk state to draw a tree.

   This split keeps the side-effecting wiring (state -> config,
   Keeper_types.read_meta, Sys.file_exists / Sys.is_directory) at the
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
  let config = state.Mcp_server.room_config in
  let lookup_repository repo_id =
    match Repo_store.find ~base_path:project_base repo_id with
    | Ok repo -> Some (Repo_store.local_path ~base_path:project_base repo)
    | Error _ -> None
  in
  let lookup_playground name =
    match Keeper_types.read_meta config name with
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
  Http.Response.json ~status ~request:req
    (Yojson.Safe.to_string json) reqd

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
  Http.Response.json ~status ~extra_headers:(source_header source)
    ~request:req (Yojson.Safe.to_string json) reqd

(* --- Safe path --- *)

let is_digit c = c >= '0' && c <= '9'

let excluded_dirs =
  [ ".git"; "node_modules"; "_build"; ".obsidian"; "__pycache__";
    ".masc"; ".worktrees"; ".cache"; ".tmp"; "dist"; "build" ]

let safe_path base requested =
  let requested = String.map (fun c -> if c = '\\' then '/' else c) requested in
  let parts = String.split_on_char '/' requested in
  let is_dangerous p = p = ".." || p = "." in
  if List.exists is_dangerous parts then base
  else
    let full = List.fold_left (fun acc p -> Filename.concat acc p) base parts in
    if String.starts_with ~prefix:base full then full else base

(* Strip [base] (and the following separator) from [safe]. Handles
   [base = "/"], trailing slash on [base], and [safe = base] (returns "").
   Assumes [safe_path] has already enforced the prefix invariant. *)
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

let file_tree_node ~path ~label ~depth ~parent ~has_children =
  `Assoc [ ("path", `String path); ("label", `String label)
         ; ("depth", `Int depth); ("parent", `String parent)
         ; ("hasChildren", `Bool has_children)
         ; ("diff", `Null); ("keeperId", `Null); ("hueIndex", `Null) ]

let rec scan_dir ~base ~depth ~max_depth acc dir =
  if depth > max_depth then acc
  else
    let entries =
      try Sys.readdir dir |> Array.to_list
      with _ -> []
    in
    List.fold_left (fun acc f ->
      if f = "." || f = ".." then acc
      else if List.mem f excluded_dirs then acc
      else
        let full = Filename.concat dir f in
        let is_dir = try Sys.is_directory full with _ -> false in
        let base_len = String.length base in
        let rel =
          if String.length full > base_len + 1
          then String.sub full (base_len + 1) (String.length full - base_len - 1)
          else f
        in
        let has_children = is_dir && depth < max_depth in
        let parent = if depth = 0 then "" else Filename.dirname rel in
        let node = file_tree_node
          ~path:rel ~label:f ~depth ~parent ~has_children in
        let acc' = node :: acc in
        if is_dir && depth < max_depth then
          scan_dir ~base ~depth:(depth + 1) ~max_depth acc' full
        else acc'
    ) acc entries

(* --- Git helpers --- *)

let git_run ~cwd args =
  let argv = "git" :: "-C" :: cwd :: "--no-optional-locks" :: args in
  let raw_source = String.concat " " (List.map Filename.quote argv) in
  try
    let (status, out) =
      Masc_exec.Exec_gate.run_argv_with_status
        ~actor:"system/workspace_api"
        ~raw_source
        ~summary:"workspace api git command"
        ~timeout_sec:15.0
        argv
    in
    match status with
    | Unix.WEXITED 0 -> Some (String.trim out)
    | _ -> None
  with _ -> None

let git_run_lines ~cwd args =
  match git_run ~cwd args with
  | None -> []
  | Some out ->
    String.split_on_char '\n' out
    |> List.filter (fun l -> l <> "")

(* Surface git failure to the caller instead of collapsing to []. Lets
   route handlers distinguish "command errored / invalid ref" from
   "command succeeded with no output". *)
let git_run_lines_or_error ~cwd args =
  match git_run ~cwd args with
  | None -> Error "git command failed"
  | Some out ->
    Ok (String.split_on_char '\n' out
        |> List.filter (fun l -> l <> ""))

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
        (try go cur_author (Some (Int64.of_string ts)) acc tl
         with _ -> go cur_author cur_time acc tl)
      else if String.length hd > 0 && is_digit (String.get hd 0)
              && String.contains hd ' ' then
        let sp = String.index hd ' ' in
        let line_num_str = String.sub hd 0 sp in
        (try
           let ln = int_of_string line_num_str in
           let a = Option.value cur_author ~default:"unknown" in
           let t = Option.value cur_time ~default:0L in
           go cur_author cur_time ({ bl_line = ln; bl_author = a; bl_time = t } :: acc) tl
         with _ -> go cur_author cur_time acc tl)
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
        | x :: _ -> (try int_of_string x with _ -> 1)
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
             | Some d -> (try max 1 (min 5 (int_of_string d)) with _ -> 3)
             | None -> 3
           in
           let nodes =
             if not (Sys.file_exists base) then []
             else scan_dir ~base ~depth:0 ~max_depth:depth [] base
           in
           let json = `List (List.rev nodes) in
           json_response_with_source ~status:`OK ~source request reqd json)
         request reqd)

  |> Http.Router.get "/api/v1/workspace/file" (fun request reqd ->
       with_public_read
         (fun state _req reqd ->
           let uri = Uri.of_string request.target in
           let base, source = resolve_workspace_base ~state ~uri in
           match Uri.get_query_param uri "path" with
           | None -> json_response ~status:`Bad_request request reqd (json_error "Missing path parameter")
           | Some p ->
               let path = safe_path base p in
               if path = base then
                 json_response ~status:`Bad_request request reqd (json_error "Invalid path")
               else if Sys.file_exists path && not (Sys.is_directory path) then
                 try
                   let content = Fs_compat.load_file path in
                   let json = `Assoc [("ok", `Bool true); ("content", `String content)] in
                   json_response_with_source ~status:`OK ~source request reqd json
                 with _ -> json_response ~status:`Internal_server_error request reqd (json_error "Failed to read file")
               else
                 json_response ~status:`Not_found request reqd (json_error "File not found"))
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
             let safe = safe_path base file_path in
             if safe = base then
               json_response ~status:`Bad_request request reqd (json_error "Invalid path")
             else if not (Sys.file_exists safe) then
               json_response ~status:`Not_found request reqd (json_error "File not found")
             else
               let rel = rel_under base safe in
               (* Blame keeps the original silent-empty contract: a file
                  that exists in the working tree but is not yet tracked
                  in HEAD (newly added, .gitignore'd, etc.) is a valid
                  caller scenario, and surfacing git's non-zero exit as
                  4xx would break it. The end-of-options separator still
                  blocks `-L1,9999`-style argv injection. *)
               match git_run_lines ~cwd:base
                       ["blame"; "--porcelain"; "--"; rel]
               with
               | [] ->
                 json_response_with_source ~status:`OK ~source request reqd (`List [])
               | lines ->
                 let entries = parse_blame_porcelain lines in
                 let grouped = group_blame_entries rel entries in
                 json_response_with_source ~status:`OK ~source request reqd (`List grouped))
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
             let safe = safe_path base file_path in
             if safe = base then
               json_response ~status:`Bad_request request reqd (json_error "Invalid path")
             else
               let rel = rel_under base safe in
               match git_run_lines_or_error ~cwd:base
                       ["diff"; base_ref; "--"; rel]
               with
               | Error _ ->
                 json_response ~status:`Bad_request request reqd
                   (json_error "git diff failed")
               | Ok [] ->
                 json_response_with_source ~status:`OK ~source request reqd
                   (`Assoc [("unified", `List []); ("has_changes", `Bool false)])
               | Ok diff_lines ->
                 let unified = parse_unified_diff diff_lines in
                 let json = `Assoc [("unified", `List unified); ("has_changes", `Bool true)] in
                 json_response_with_source ~status:`OK ~source request reqd json)
         request reqd)
