let normalize_path path =
  Keeper_alerting_path.normalize_path_for_check path
  |> Keeper_alerting_path.strip_trailing_slashes

let playground_root_no_create ~(config : Workspace.config) ~(meta : Keeper_meta_contract.keeper_meta) =
  Keeper_sandbox.host_root_abs_of_meta ~config meta

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

let path_segments ~normalize path =
  path
  |> normalize
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

let location_json
      ~normalize
      ~playground
      ~(args : Yojson.Safe.t)
      ~(cwd : string)
  =
  let raw_cwd = Safe_ops.json_string ~default:"" "cwd" args |> String.trim in
  let cwd_source =
    if String.equal raw_cwd "" then "default_playground_root" else "explicit_cwd"
  in
  let playground = normalize playground in
  let cwd = normalize cwd in
  let playground_segments = path_segments ~normalize playground in
  let cwd_segments = path_segments ~normalize cwd in
  let scope, relative_segments, repo_name, repo_root =
    match strip_segment_prefix ~prefix:playground_segments cwd_segments with
    | None -> Outside_playground, [], None, None
    | Some [] -> Playground_root, [], None, None
    | Some (repos_segment :: repo_name :: rest)
      when String.equal repos_segment Playground_paths.bundle_repos_dirname
           && safe_repo_component repo_name ->
      let repo_root =
        Filename.concat
          (Filename.concat playground Playground_paths.bundle_repos_dirname)
          repo_name
        |> normalize
      in
      (match rest with
       | [] ->
         Repo_root,
         [ Playground_paths.bundle_repos_dirname; repo_name ],
         Some repo_name, Some repo_root
       | _ ->
         Repo_subpath,
         [ Playground_paths.bundle_repos_dirname; repo_name ] @ rest,
         Some repo_name, Some repo_root)
    | Some rest -> Playground_subpath, rest, None, None
  in
  let relative_cwd =
    match scope with
    | Outside_playground -> `Null
    | Playground_root | Playground_subpath | Repo_root | Repo_subpath -> `String (relative_path_of_segments relative_segments)
  in
  `Assoc
    [ "cwd", `String cwd
    ; "cwd_source", `String cwd_source
    ; "scope", `String (string_of_execution_location_scope scope)
    ; "playground_root", `String playground
    ; "relative_cwd", relative_cwd
    ; "repo_name", Json_util.string_opt_to_json repo_name
    ; "repo_root", Json_util.string_opt_to_json repo_root
    ]

let execution_location_json ~remote_workspace_root ~config ~meta ~args ~cwd =
  match meta.Keeper_meta_contract.sandbox_profile with
  | Keeper_types_profile_sandbox.Remote_ssh ->
    let location = match remote_workspace_root with
      | None -> Error "remote_ssh_namespace_unresolved"
      | Some playground ->
        Keeper_remote_path.host_to_remote ~base_path:config.Workspace.base_path
          ~remote_workspace_root:playground ~keeper:meta.name cwd
        |> Result.map (fun cwd -> location_json
          ~normalize:Keeper_remote_path.normalize_remote ~playground ~args ~cwd)
    in
    (match location with
     | Ok location -> location
     | Error reason -> `Assoc [ "cwd", `Null; "playground_root", `Null
       ; "repo_root", `Null; "relative_cwd", `Null; "scope", `String "unavailable"
       ; "reason", `String reason ])
  | Micro_vm | Docker ->
  let host_location = location_json ~normalize:normalize_path
    ~playground:(playground_root_no_create ~config ~meta) ~args ~cwd in
  match Keeper_types_profile_sandbox.tree_location_of_profile meta.sandbox_profile with
  (* The execution location is the host bookkeeping bundle: the only
     keeper-visible namespace this side has for a tree the endpoint owns. *)
  | Keeper_types_profile_sandbox.Endpoint_owned -> host_location
  | Keeper_types_profile_sandbox.Shared_mount ->
    let host_root = normalize_path (playground_root_no_create ~config ~meta) in
    let visible_root =
      Keeper_sandbox.container_root meta.name
    in
    let project_path path =
      let path = normalize_path path in
      if String.equal path host_root
      then `String visible_root
      else
        let prefix =
          if String.equal host_root Filename.dir_sep
          then host_root
          else host_root ^ Filename.dir_sep
        in
        if String.length path > String.length prefix
           && String.sub path 0 (String.length prefix) = prefix
        then
          `String
            (Filename.concat
               visible_root
               (String.sub
                  path
                  (String.length prefix)
                  (String.length path - String.length prefix)))
        else if Filename.is_relative path
        then `String path
        else `Null
    in
    let path_fields =
      [ "cwd"; "playground_root"; "repo_root" ]
    in
    let rec project = function
      | `Assoc fields ->
        `Assoc
          (List.map
             (fun (key, value) ->
                if List.mem key path_fields
                then
                  ( key
                  , match value with
                    | `String path -> project_path path
                    | other -> other )
                else key, project value)
             fields)
      | `List values -> `List (List.map project values)
      | value -> value
    in
    project host_location
