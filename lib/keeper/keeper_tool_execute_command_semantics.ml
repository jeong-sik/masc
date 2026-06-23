(** Execute command semantics.

    This layer owns keeper-specific cwd policy and user-facing command
    guidance. Pure command-shape extraction stays in
    [Masc_exec.Shell_ir_command_shape]. *)

type stage = Masc_exec.Shell_ir_command_shape.stage =
  { bin : string
  ; args : string list
  }

let effective_stages ir = Masc_exec.Shell_ir_command_shape.effective_stages ir

let normalize_command_name =
  Masc_exec.Shell_ir_command_shape.normalize_command_name

let cmd_prefix = Keeper_tool_command_words.cmd_prefix

let strip_simple_shell_quotes token =
  let len = String.length token in
  if
    len >= 2
    && ((token.[0] = '\'' && token.[len - 1] = '\'')
        || (token.[0] = '"' && token.[len - 1] = '"'))
  then String.sub token 1 (len - 2)
  else token

let stages_target_repo_commands stages =
  List.exists (fun stage ->
    let bin = normalize_command_name stage.bin in
    bin = "git" || bin = "gh") stages

let stages_target_repo_hosting_cli stages =
  List.exists (fun stage -> normalize_command_name stage.bin = "gh") stages

let repo_hosting_cli_args_have_repo_flag args =
  List.exists
    (fun arg ->
       arg = "--repo"
       || arg = "-R"
       || String.starts_with ~prefix:"--repo=" arg
       || String.starts_with ~prefix:"-R=" arg)
    args

let stages_have_repo_hosting_cli_repo_flag stages =
  List.exists
    (fun stage ->
       normalize_command_name stage.bin = "gh"
       && repo_hosting_cli_args_have_repo_flag stage.args)
    stages

let repo_flag_value = function
  | "--repo" -> None
  | flag when String.starts_with ~prefix:"--repo=" flag ->
    let value =
      String.sub flag (String.length "--repo=") (String.length flag - String.length "--repo=")
    in
    if value = "" then None else Some value
  | _ -> None

let repo_hosting_cli_repo_flag_api_misuse_of_stages stages =
  let scan_args = function
    | "--repo" :: repo_arg :: "api" :: endpoint :: _ -> Some (repo_arg, endpoint)
    | flag :: "api" :: endpoint :: _ ->
      Option.map (fun repo_arg -> repo_arg, endpoint) (repo_flag_value flag)
    | _ -> None
  in
  List.find_map (fun stage ->
    if normalize_command_name stage.bin = "gh" then scan_args stage.args else None) stages

let gh_pr_diff_misuse_of_stages stages =
  let scan_args args =
    let rec filter_flags = function
      | [] -> []
      | "--" :: rest ->
        "--" :: rest
      | flag :: val_arg :: rest when flag = "--repo" || flag = "-R" || flag = "--color" ->
        filter_flags rest
      | flag :: rest when String.starts_with ~prefix:"--repo=" flag
                       || String.starts_with ~prefix:"-R=" flag
                       || String.starts_with ~prefix:"--color=" flag ->
        filter_flags rest
      | flag :: rest when String.starts_with ~prefix:"-" flag ->
        filter_flags rest
      | pos_arg :: rest ->
        pos_arg :: filter_flags rest
    in
    let pos_args = filter_flags args in
    if List.length pos_args > 1 || List.mem "--" pos_args then
      Some pos_args
    else
      None
  in
  List.find_map (fun stage ->
    if normalize_command_name stage.bin = "gh" then
      match stage.args with
      | "pr" :: "diff" :: rest -> scan_args rest
      | _ -> None
    else
      None) stages

let repo_hosting_cli_repo_flag_api_misuse ir =
  repo_hosting_cli_repo_flag_api_misuse_of_stages (effective_stages ir)

let gh_pr_diff_misuse ir =
  gh_pr_diff_misuse_of_stages (effective_stages ir)

let misuse_error_of_stages stages =
  match repo_hosting_cli_repo_flag_api_misuse_of_stages stages with
  | Some (repo_arg, endpoint) ->
    Some
      (Printf.sprintf
         "잘못된 gh syntax: 'gh --repo %s api %s ...' — '--repo' 는 subcommand \
          flag (gh issue/pr/release/run) 전용이고 'gh api' 에는 적용 안 됨. 올바른 형태: 'gh \
          api repos/%s/%s' (endpoint 안에 org/repo 포함). 다음 turn 에서 cmd 를 수정하세요."
         repo_arg
         endpoint
         repo_arg
         endpoint)
  | None ->
    (match gh_pr_diff_misuse_of_stages stages with
     | Some pos_args ->
       Some
         (Printf.sprintf
            "잘못된 gh syntax: 'gh pr diff'는 파일 경로 필터링(예: '--', '*.ml')을 지원하지 않으며, positional argument는 최대 1개([<number> | <url> | <branch>])만 허용됩니다. (입력받은 positional args: %s). 전체 diff를 원하시면 파일 필터를 제거하시고, 특정 파일만 보시려면 git 저장소 내에서 'git diff origin/main <pr> -- <paths>'를 실행하세요."
            (String.concat ", " pos_args))
     | None -> None)

let misuse_error ir = misuse_error_of_stages (effective_stages ir)


let bare_worktrees_path token =
  let token = strip_simple_shell_quotes token in
  String.equal token ".worktrees"
  || String.equal token "./.worktrees"
  || String.starts_with ~prefix:".worktrees/" token
  || String.starts_with ~prefix:"./.worktrees/" token

let git_global_c_path_groups_of_stages stages =
  let rec scan_git_args acc = function
    | "-C" :: path :: rest -> scan_git_args (path :: acc) rest
    | "-C" :: [] -> List.rev acc
    | "--" :: _ -> List.rev acc
    | option :: rest when String.starts_with ~prefix:"-C" option ->
      let path =
        String.sub option 2 (String.length option - 2) |> String.trim
      in
      if path = "" then List.rev acc else scan_git_args (path :: acc) rest
    | ("-c" | "--config-env" | "--git-dir" | "--work-tree" | "--namespace"
      | "--super-prefix" | "--exec-path") :: _value :: rest ->
      scan_git_args acc rest
    | option :: rest when String.starts_with ~prefix:"-" option ->
      scan_git_args acc rest
    | _ :: _ -> List.rev acc
    | [] -> List.rev acc
  in
  List.filter_map (fun stage ->
    if normalize_command_name stage.bin = "git"
    then (
      match scan_git_args [] stage.args with
      | [] -> None
      | paths -> Some paths)
    else None) stages

let normalize_cwd_relative_path ?container_root ?host_root ~cwd path =
  let path = strip_simple_shell_quotes path |> String.trim in
  let path = if Filename.is_relative path then Filename.concat cwd path else path in
  let path =
    Keeper_alerting_path.normalize_path_for_check path
    |> Keeper_alerting_path.strip_trailing_slashes
  in
  match container_root, host_root with
  | Some container_root, Some host_root ->
    let container_root =
      Keeper_alerting_path.normalize_path_for_check container_root
      |> Keeper_alerting_path.strip_trailing_slashes
    in
    if path = container_root
    then host_root
    else (
      let prefix = container_root ^ "/" in
      if String.starts_with ~prefix path
      then
        Filename.concat
          host_root
          (String.sub path (String.length prefix) (String.length path - String.length prefix))
      else path)
  | _ -> path

let path_is_existing_dir path =
  try Sys.file_exists path && Sys.is_directory path with
  | Sys_error _ -> false

let resolve_sandbox_root_git_cwd
    ~(config : Workspace.config) ~(meta : Keeper_meta_contract.keeper_meta) ~cwd ~cmd ir
  =
  let stages = effective_stages ir in
  let host_root =
    Keeper_sandbox.host_root_abs_of_meta ~config meta
    |> Keeper_alerting_path.normalize_path_for_check
    |> Keeper_alerting_path.strip_trailing_slashes
  in
  let cwd_normalized =
    Keeper_alerting_path.normalize_path_for_check cwd
    |> Keeper_alerting_path.strip_trailing_slashes
  in
  let repos_in_playground () =
    let repos_dir = Filename.concat host_root "repos" in
    if not (Sys.file_exists repos_dir && Sys.is_directory repos_dir)
    then []
    else (
      try
        Sys.readdir repos_dir
        |> Array.to_list
        |> List.filter (fun name ->
          let p = Filename.concat repos_dir name in
          try Sys.is_directory p && Sys.file_exists (Filename.concat p ".git") with
          | Sys_error _ -> false)
        |> List.sort compare
      with
      | Sys_error _ -> [])
  in
  if
    cwd_normalized = host_root && stages_target_repo_hosting_cli stages
    && stages_have_repo_hosting_cli_repo_flag stages
  then cwd, None
  else if cwd_normalized = host_root && stages_target_repo_commands stages
  then (
    (* Sandbox root is the keeper's own mount point. We no longer require an
       explicit repos/ target or a single existing repo: let git/gh run from
       the root and fail/succeed naturally inside the container. We only
       preflight explicit -C paths so that missing targets surface as clear
       errors before docker exec. *)
    let explicit_git_c_path_groups = git_global_c_path_groups_of_stages stages in
    let base_for_git_c_paths = function
      | first :: _ when bare_worktrees_path first ->
        (match repos_in_playground () with
         | [ single_repo ] ->
           Some (Filename.concat (Filename.concat host_root "repos") single_repo)
         | _ -> None)
      | _ -> Some cwd_normalized
    in
    let git_c_target_from_paths ~base paths =
      List.fold_left
        (fun cwd path ->
           normalize_cwd_relative_path
             ~container_root:(Keeper_sandbox.container_root meta.name)
             ~host_root
             ~cwd
             path)
        base
        paths
    in
    let validate_git_c_paths paths =
      match base_for_git_c_paths paths with
      | None -> Ok ()
      | Some base ->
      let target =
        git_c_target_from_paths ~base paths
      in
      if path_is_existing_dir target
      then Ok ()
      else
        Error
          (Printf.sprintf
             "cwd_not_directory: %s (git -C target must be an existing directory)"
             target)
    in
    match explicit_git_c_path_groups with
    | [] -> cwd, None
    | groups ->
      (match List.find_map
               (fun paths ->
                  match validate_git_c_paths paths with
                  | Ok () -> None
                  | Error msg -> Some msg)
               groups
       with
       | Some msg -> cwd, Some msg
       | None -> cwd, None))
  else cwd, None
