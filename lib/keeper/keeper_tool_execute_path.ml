open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime

let normalize_repo_cwd_path path =
  Keeper_alerting_path.normalize_path_for_check path
  |> Keeper_alerting_path.strip_trailing_slashes

let safe_repo_component s =
  s <> ""
  && s <> "."
  && s <> ".."
  && (not (String.contains s '/'))
  && (not (String.contains s '\\'))
  && (not (String.contains s '\x00'))
  && String.for_all
       (fun c ->
          (c >= 'A' && c <= 'Z')
          || (c >= 'a' && c <= 'z')
          || (c >= '0' && c <= '9')
          || c = '-'
          || c = '_'
          || c = '.')
       s

type repo_path_context =
  { path_repo_name : string
  ; path_repo_root : string
  ; path_root : string
  ; accepted_toplevels : string list
  }

let repo_path_context ~(config : Workspace.config) ~(meta : keeper_meta) ~path =
  let playground =
    keeper_playground_root ~config ~meta
    |> normalize_repo_cwd_path
  in
  let repos_root = Filename.concat playground "repos" |> normalize_repo_cwd_path in
  let path = normalize_repo_cwd_path path in
  if String.equal path repos_root then None
  else
    let prefix = repos_root ^ "/" in
    if not (String.starts_with ~prefix path) then None
    else
      let suffix =
        String.sub path (String.length prefix) (String.length path - String.length prefix)
      in
      match String.split_on_char '/' suffix with
      | repo_name :: ".worktrees" :: task_name :: _
        when safe_repo_component repo_name && safe_repo_component task_name ->
        let repo_root = Filename.concat repos_root repo_name in
        let worktree_root =
          Filename.concat (Filename.concat repo_root ".worktrees") task_name
          |> normalize_repo_cwd_path
        in
        Some
          { path_repo_name = repo_name
          ; path_repo_root = normalize_repo_cwd_path repo_root
          ; path_root = worktree_root
          ; accepted_toplevels = [ worktree_root ]
          }
      | repo_name :: _ when safe_repo_component repo_name ->
        let repo_root = Filename.concat repos_root repo_name in
        let repo_root = normalize_repo_cwd_path repo_root in
        Some
          { path_repo_name = repo_name
          ; path_repo_root = repo_root
          ; path_root = repo_root
          ; accepted_toplevels = [ repo_root ]
          }
      | _ -> None

type repo_cwd_context =
  { repo_name : string
  ; repo_root : string
  ; path_root : string
  ; is_direct_root : bool
  }

let repo_cwd_context ~config ~meta ~cwd =
  let cwd = normalize_repo_cwd_path cwd in
  match repo_path_context ~config ~meta ~path:cwd with
  | Some { path_repo_name; path_repo_root; path_root; _ } ->
    Some
      { repo_name = path_repo_name
      ; repo_root = path_repo_root
      ; path_root
      ; is_direct_root = String.equal path_repo_root cwd
      }
  | None -> None

type execution_location_scope =
  | Playground_root
  | Playground_subpath
  | Repo_root
  | Repo_subpath
  | Repo_worktree_root
  | Repo_worktree_subpath
  | Outside_playground

let string_of_execution_location_scope = function
  | Playground_root -> "playground_root"
  | Playground_subpath -> "playground_subpath"
  | Repo_root -> "repo_root"
  | Repo_subpath -> "repo_subpath"
  | Repo_worktree_root -> "repo_worktree_root"
  | Repo_worktree_subpath -> "repo_worktree_subpath"
  | Outside_playground -> "outside_playground"

let path_segments path =
  path
  |> normalize_repo_cwd_path
  |> String.split_on_char '/'
  |> List.filter (fun segment -> not (String.equal segment ""))

let strip_segment_prefix ~prefix segments =
  let rec loop prefix segments =
    match prefix, segments with
    | [], rest -> Some rest
    | p :: ps, s :: ss when String.equal p s -> loop ps ss
    | _ -> None
  in
  loop prefix segments

let relative_path_of_segments = function
  | [] -> "."
  | segments -> String.concat "/" segments

let execution_location_json
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
      ~(cwd : string)
  =
  let raw_cwd = Safe_ops.json_string ~default:"" "cwd" args |> String.trim in
  let cwd_source =
    if String.equal raw_cwd "" then "default_playground_root" else "explicit_cwd"
  in
  let playground =
    keeper_playground_root ~config ~meta
    |> normalize_repo_cwd_path
  in
  let cwd = normalize_repo_cwd_path cwd in
  let playground_segments = path_segments playground in
  let cwd_segments = path_segments cwd in
  let scope, relative_segments, repo_name, repo_root, worktree_name, worktree_root =
    match strip_segment_prefix ~prefix:playground_segments cwd_segments with
    | None -> Outside_playground, [], None, None, None, None
    | Some [] -> Playground_root, [], None, None, None, None
    | Some ("repos" :: repo_name :: rest)
      when safe_repo_component repo_name ->
      let repo_root =
        Filename.concat (Filename.concat playground "repos") repo_name
        |> normalize_repo_cwd_path
      in
      (match rest with
       | [] ->
         Repo_root, [ "repos"; repo_name ], Some repo_name, Some repo_root, None, None
       | ".worktrees" :: task_name :: tail
         when safe_repo_component task_name ->
         let worktree_root =
           Filename.concat (Filename.concat repo_root ".worktrees") task_name
           |> normalize_repo_cwd_path
         in
         let scope =
           match tail with
           | [] -> Repo_worktree_root
           | _ -> Repo_worktree_subpath
         in
         ( scope
         , [ "repos"; repo_name; ".worktrees"; task_name ] @ tail
         , Some repo_name
         , Some repo_root
         , Some task_name
         , Some worktree_root )
       | _ ->
         Repo_subpath, [ "repos"; repo_name ] @ rest, Some repo_name, Some repo_root, None, None)
    | Some rest -> Playground_subpath, rest, None, None, None, None
  in
  let relative_cwd =
    match scope with
    | Outside_playground -> `Null
    | _ -> `String (relative_path_of_segments relative_segments)
  in
  let selected_worktree =
    match repo_name, repo_root, worktree_name, worktree_root with
    | Some repo_name, Some repo_root, Some worktree_name, Some worktree_root ->
      `Assoc
        [ "repo_name", `String repo_name
        ; "repo_root", `String repo_root
        ; "worktree_name", `String worktree_name
        ; "worktree_root", `String worktree_root
        ; "selection_source", `String "execution_cwd"
        ; "scope", `String (string_of_execution_location_scope scope)
        ; "relative_cwd", relative_cwd
        ]
    | _ -> `Null
  in
  `Assoc
    [ "cwd", `String cwd
    ; "cwd_source", `String cwd_source
    ; "scope", `String (string_of_execution_location_scope scope)
    ; "playground_root", `String playground
    ; "relative_cwd", relative_cwd
    ; "relative_path_base", `String cwd
    ; "argv_relative_paths_resolve_against_cwd", `Bool true
    ; "repo_name", Json_util.string_opt_to_json repo_name
    ; "repo_root", Json_util.string_opt_to_json repo_root
    ; "worktree_selected", `Bool (Option.is_some worktree_root)
    ; "worktree_name", Json_util.string_opt_to_json worktree_name
    ; "worktree_root", Json_util.string_opt_to_json worktree_root
    ; "selected_worktree", selected_worktree
    ]

let resolve_missing_cwd cwd =
  Error (Printf.sprintf "cwd_not_directory: %s (directory does not exist)" cwd)

let resolve_tool_read_cwd
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let raw_cwd = Safe_ops.json_string ~default:"" "cwd" args |> String.trim in
  let resolved =
    if raw_cwd = ""
    then Ok (keeper_default_read_root ~config ~meta)
    else resolve_keeper_read_path ~config ~meta ~raw_path:raw_cwd
  in
  match resolved with
  | Error _ as err -> err
  | Ok cwd when Fs_compat.file_exists cwd && Sys.is_directory cwd -> Ok cwd
  | Ok cwd ->
    if not (Fs_compat.file_exists cwd) then resolve_missing_cwd cwd
    else
      Error (Printf.sprintf "cwd_not_directory: %s (path_is_file_not_directory)" cwd)

let resolve_tool_write_cwd
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let raw_cwd = Safe_ops.json_string ~default:"" "cwd" args |> String.trim in
  let resolved =
    if raw_cwd = ""
    then Ok (keeper_default_write_root ~config ~meta)
    else resolve_keeper_path ~config ~meta ~raw_path:raw_cwd
  in
  match resolved with
  | Error _ as err -> err
  | Ok cwd when Fs_compat.file_exists cwd && Sys.is_directory cwd -> Ok cwd
  | Ok cwd ->
    if not (Fs_compat.file_exists cwd) then resolve_missing_cwd cwd
    else
      Error (Printf.sprintf "cwd_not_directory: %s (path_is_file_not_directory)" cwd)

(* Docker playground path mapping: host → container.
   Host:      <base_path>/.masc/playground/<keeper>/repos/X
   Container: <container_playground_root>/<keeper>/repos/X
   The container-side root comes from
   [Env_config_sandbox.Runtime.docker_playground_container_root ()] so the
   mount point is configurable (default "/home/keeper/playground"). *)
let _docker_playground_cwd ~(config : Workspace.config) ~(meta : keeper_meta) host_cwd =
  let root = Keeper_alerting_path.project_root_of_config config in
  let playground_prefix =
    Filename.concat root Playground_paths.all_playgrounds_prefix
  in
  let container_root =
    Env_config_sandbox.Runtime.docker_playground_container_root ()
  in
  (* Boundary-safe prefix match: require either an exact match or a
     prefix ending at a path separator. Without this, host paths like
     "<root>/.masc/playgroundXYZ/..." would match "<root>/.masc/playground"
     and leak into the container playground. *)
  let prefix_with_sep = playground_prefix ^ "/" in
  let starts_at_boundary =
    host_cwd = playground_prefix
    || String.starts_with ~prefix:prefix_with_sep host_cwd
  in
  if starts_at_boundary then
    if host_cwd = playground_prefix then container_root
    else
      let raw_suffix =
        String.sub host_cwd (String.length prefix_with_sep)
          (String.length host_cwd - String.length prefix_with_sep)
      in
      (* A [host_cwd] like ".../.masc/playground//cheolsu/..." produces a
         [raw_suffix] that starts with "/". [Filename.concat] would then
         treat [raw_suffix] as an absolute path and drop [container_root],
         silently escaping the mount. Strip any leading slashes so the
         suffix is always a strict relative segment. *)
      let suffix =
        let n = String.length raw_suffix in
        let i = ref 0 in
        while !i < n && raw_suffix.[!i] = '/' do incr i done;
        if !i = 0 then raw_suffix
        else String.sub raw_suffix !i (n - !i)
      in
      if suffix = "" then container_root
      else Filename.concat container_root suffix
  else
    (* meta.name is sanitized through Playground_paths so a poisoned
       name cannot escape the container_root. *)
    Filename.concat container_root
      (Playground_paths.sanitize_keeper_name meta.name)

(* Common wrong path prefixes that keepers use.
   Maps wrong prefix → corrected relative path using the keeper
   playground SSOT ([Playground_paths]). [sanitize_keeper_name] in the
   SSOT rejects "", "." and ".." as whole-name segments (substituting
   "_", "_", "__" respectively), so a poisoned [meta.name] cannot
   produce a ".."/"." directory component and cannot escape the
   playground bundle via [Filename.concat]. *)
let auto_correct_path ~(meta : keeper_meta) (raw : string) : string option =
  (* bundle_root yields ".masc/playground/<safe>/" — strip the trailing
     slash so we can append "/repos/..." cleanly. *)
  let playground_bundle = Keeper_sandbox.allowed_root_rel_of_meta ~meta in
  let playground =
    if String.ends_with ~suffix:"/" playground_bundle
    then String.sub playground_bundle 0 (String.length playground_bundle - 1)
    else playground_bundle
  in
  let try_strip prefix replacement =
    let plen = String.length prefix in
    if String.length raw >= plen
       && String.sub raw 0 plen = prefix
    then Some (replacement ^ String.sub raw plen (String.length raw - plen))
    else None
  in
  (* /repos/X → .masc/playground/<safe-name>/repos/X *)
  match try_strip "/repos/" (playground ^ "/repos/") with
  | Some _ as r -> r
  | None ->
  match try_strip "repos/" (playground ^ "/repos/") with
  | Some _ as r -> r
  | None ->
  match try_strip "playground/" (Playground_paths.all_playgrounds_prefix ^ "/") with
  | Some _ as r -> r
  | None -> None

let resolve_tool_read_path
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let raw_path = Safe_ops.json_string ~default:"" "path" args |> String.trim in
  let resolve_with_autocorrect raw_path_to_resolve =
    match resolve_keeper_read_path ~config ~meta ~raw_path:raw_path_to_resolve with
    | Ok _ as ok -> ok
    | Error original_err ->
      (* Try auto-correcting common wrong prefixes *)
      match auto_correct_path ~meta raw_path_to_resolve with
      | Some corrected ->
        (match resolve_keeper_read_path ~config ~meta ~raw_path:corrected with
         | Ok resolved ->
           Log.Keeper.info "%s: auto-corrected path %S → %S"
             meta.name raw_path_to_resolve resolved;
           Ok resolved
         | Error _ -> Error original_err)
      | None -> Error original_err
  in
  match resolve_tool_read_cwd ~config ~meta ~args with
  | Error _ as err when raw_path = "" -> err
  | Error _ ->
    let fallback_path = if raw_path = "" then "." else raw_path in
    resolve_with_autocorrect fallback_path
  | Ok cwd ->
    if raw_path = ""
    then Ok cwd
    else if
      (not (Filename.is_relative raw_path)) || is_playground_lane_relative_path raw_path
    then resolve_with_autocorrect raw_path
    else
      let projected_path = Filename.concat cwd raw_path in
      resolve_projected_keeper_read_path
        ~config
        ~meta
        ~raw_for_error:raw_path
        ~projected_path

let executable_file path =
  try
    let st = Unix.stat path in
    st.Unix.st_kind = Unix.S_REG
    &&
    (Unix.access path [ Unix.X_OK ];
     true)
  with
  | Unix.Unix_error _ | Sys_error _ -> false

let path_has_executable name =
  match Sys.getenv_opt "PATH" with
  | None -> false
  | Some path ->
    path
    |> String.split_on_char ':'
    |> List.exists (fun dir ->
      (* Do not mirror the shell's empty-PATH current-directory fallback
         for keeper probes; only explicit directories are trusted. *)
      dir <> "" && executable_file (Filename.concat dir name))

let shell_command_available name =
  let name = String.trim name in
  if name = "" then false
  else if String.contains name '/' then executable_file name
  else path_has_executable name

let normalize_for_containment path =
  Keeper_alerting_path.normalize_path_for_check path
  |> Keeper_alerting_path.strip_trailing_slashes

let in_playground ~root ~cwd ~meta =
  let cwd_canonical = normalize_for_containment cwd in
  let playground_rel = Keeper_sandbox.allowed_root_rel_of_meta ~meta in
  let playground_abs = normalize_for_containment (Filename.concat root playground_rel) in
  String.starts_with ~prefix:(playground_abs ^ "/") (cwd_canonical ^ "/")
  || String.equal playground_abs cwd_canonical
