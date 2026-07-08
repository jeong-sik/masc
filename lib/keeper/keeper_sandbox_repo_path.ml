open Keeper_types
open Keeper_meta_contract

let normalize_path path =
  Keeper_alerting_path.normalize_path_for_check path
  |> Keeper_alerting_path.strip_trailing_slashes

let playground_root_no_create ~(config : Workspace.config) ~(meta : keeper_meta) =
  Keeper_sandbox.host_root_abs_of_meta ~config meta

let repos_root_of_playground_root playground_root =
  Filename.concat playground_root "repos" |> normalize_path

let repo_root_of_playground_root ~playground_root ~repo_name =
  Filename.concat (repos_root_of_playground_root playground_root) repo_name
  |> normalize_path

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

let candidate_repo_roots_no_create ~base_path ~keeper_id ~repository_id =
  if not (safe_repo_component repository_id)
  then []
  else
    [ Keeper_types_profile_sandbox.Local; Keeper_types_profile_sandbox.Docker ]
    |> List.map (fun sandbox_profile ->
      let playground_root =
        Filename.concat
          base_path
          (Keeper_sandbox.host_root_rel_of_profile sandbox_profile keeper_id)
      in
      repo_root_of_playground_root ~playground_root ~repo_name:repository_id)
    |> List.sort_uniq String.compare

type path_context =
  { path_repo_name : string
  ; path_repo_root : string
  ; path_root : string
  ; accepted_toplevels : string list
  }

let classify_path ~(config : Workspace.config) ~(meta : keeper_meta) ~path =
  let playground =
    playground_root_no_create ~config ~meta
    |> normalize_path
  in
  let repos_root = repos_root_of_playground_root playground in
  let path = normalize_path path in
  if String.equal path repos_root then None
  else
    let prefix = repos_root ^ "/" in
    if not (String.starts_with ~prefix path) then None
    else
      let suffix =
        String.sub path (String.length prefix) (String.length path - String.length prefix)
      in
      match String.split_on_char '/' suffix with
      | repo_name :: _ when safe_repo_component repo_name ->
        let repo_root = repo_root_of_playground_root ~playground_root:playground ~repo_name in
        Some
          { path_repo_name = repo_name
          ; path_repo_root = repo_root
          ; path_root = repo_root
          ; accepted_toplevels = [ repo_root ]
          }
      | _ -> None

type cwd_context =
  { repo_name : string
  ; repo_root : string
  ; path_root : string
  ; is_direct_root : bool
  }

let classify_cwd ~config ~meta ~cwd =
  let cwd = normalize_path cwd in
  match classify_path ~config ~meta ~path:cwd with
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
  | Outside_playground

let string_of_execution_location_scope = function
  | Playground_root -> "playground_root"
  | Playground_subpath -> "playground_subpath"
  | Repo_root -> "repo_root"
  | Repo_subpath -> "repo_subpath"
  | Outside_playground -> "outside_playground"

let path_segments path =
  path
  |> normalize_path
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
    playground_root_no_create ~config ~meta
    |> normalize_path
  in
  let cwd = normalize_path cwd in
  let playground_segments = path_segments playground in
  let cwd_segments = path_segments cwd in
  let scope, relative_segments, repo_name, repo_root =
    match strip_segment_prefix ~prefix:playground_segments cwd_segments with
    | None -> Outside_playground, [], None, None
    | Some [] -> Playground_root, [], None, None
    | Some ("repos" :: repo_name :: rest)
      when safe_repo_component repo_name ->
      let repo_root =
        Filename.concat (Filename.concat playground "repos") repo_name
        |> normalize_path
      in
      (match rest with
       | [] ->
         Repo_root, [ "repos"; repo_name ], Some repo_name, Some repo_root
       | _ ->
         Repo_subpath, [ "repos"; repo_name ] @ rest, Some repo_name, Some repo_root)
    | Some rest -> Playground_subpath, rest, None, None
  in
  let relative_cwd =
    match scope with
    | Outside_playground -> `Null
    | _ -> `String (relative_path_of_segments relative_segments)
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
    ]
