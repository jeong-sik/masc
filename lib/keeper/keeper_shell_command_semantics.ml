(** Keeper shell command semantics.

    This layer owns command-shape interpretation. Runtime backends call
    into it when they need deterministic cwd policy for git/gh commands,
    but it does not execute shell commands and does not construct Docker
    invocations. *)

type parsed_stage =
  { bin : string
  ; args : string list
  }

let parse_cmd_to_ir_opt = Keeper_shell_command_parse.parse_cmd_to_ir_opt

let literal_args args =
  let rec loop acc = function
    | [] -> Some (List.rev acc)
    | Masc_exec.Shell_ir.Lit (arg, _) :: rest -> loop (arg :: acc) rest
    | Masc_exec.Shell_ir.Concat _ :: _ | Masc_exec.Shell_ir.Var (_, _) :: _ -> None
  in
  loop [] args

let stage_of_simple simple =
  match literal_args simple.Masc_exec.Shell_ir.args with
  | None -> None
  | Some args ->
    Some { bin = Masc_exec.Exec_program.to_string simple.bin; args }

let parsed_stages_of_ir ir =
  let rec loop acc = function
    | Masc_exec.Shell_ir.Simple simple -> (
        match stage_of_simple simple with
        | Some stage -> Some (stage :: acc)
        | None -> None)
    | Masc_exec.Shell_ir.Pipeline stages ->
      List.fold_left
        (fun acc stage -> Option.bind acc (fun acc -> loop acc stage))
        (Some acc)
        stages
  in
  match loop [] ir with
  | Some stages -> List.rev stages
  | None -> []

let is_shell_identifier name =
  let len = String.length name in
  let is_head = function
    | 'A' .. 'Z' | 'a' .. 'z' | '_' -> true
    | _ -> false
  in
  let is_tail = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' -> true
    | _ -> false
  in
  len > 0
  && is_head name.[0]
  && Seq.for_all is_tail (String.to_seq (String.sub name 1 (len - 1)))

let is_env_assignment token =
  match String.index_opt token '=' with
  | None -> false
  | Some 0 -> false
  | Some i -> is_shell_identifier (String.sub token 0 i)

let rec effective_stage = function
  | { bin = "env"; args } ->
    let rec scan = function
      | [] -> None
      | ("-i" | "--ignore-environment") :: rest -> scan rest
      | arg :: rest when is_env_assignment arg -> scan rest
      | arg :: rest when String.starts_with ~prefix:"-" arg -> None
      | bin :: args -> Some { bin; args }
    in
    scan args
  | { bin = "opam"; args = "exec" :: rest } ->
    (match rest with
     | "--" :: bin :: args -> Some { bin; args }
     | bin :: args when not (String.starts_with ~prefix:"-" bin) ->
       Some { bin; args }
     | _ -> None)
  | stage -> Some stage

let effective_stages_of_ir ir =
  parsed_stages_of_ir ir |> List.filter_map effective_stage

let strip_simple_shell_quotes token =
  let len = String.length token in
  if
    len >= 2
    && ((token.[0] = '\'' && token.[len - 1] = '\'')
        || (token.[0] = '"' && token.[len - 1] = '"'))
  then String.sub token 1 (len - 2)
  else token

let stages_targets_git_or_gh stages =
  List.exists (fun stage -> stage.bin = "git" || stage.bin = "gh") stages

let stages_targets_gh stages =
  List.exists (fun stage -> stage.bin = "gh") stages

let repo_flag_value = function
  | "--repo" -> None
  | flag when String.starts_with ~prefix:"--repo=" flag ->
    let value =
      String.sub flag (String.length "--repo=") (String.length flag - String.length "--repo=")
    in
    if value = "" then None else Some value
  | _ -> None

let gh_repo_flag_api_misuse_of_stages stages =
  let scan_args = function
    | "--repo" :: repo_arg :: "api" :: endpoint :: _ -> Some (repo_arg, endpoint)
    | flag :: "api" :: endpoint :: _ ->
      Option.map (fun repo_arg -> repo_arg, endpoint) (repo_flag_value flag)
    | _ -> None
  in
  List.find_map (fun stage ->
    if stage.bin = "gh" then scan_args stage.args else None) stages

let bare_worktrees_path token =
  let token = strip_simple_shell_quotes token in
  String.equal token ".worktrees"
  || String.equal token "./.worktrees"
  || String.starts_with ~prefix:".worktrees/" token
  || String.starts_with ~prefix:"./.worktrees/" token

let git_c_path_of_stages stages =
  let rec scan_git_args = function
    | "-C" :: path :: _ -> Some path
    | "--" :: _ -> None
    | option :: _ when String.starts_with ~prefix:"-C" option ->
      let path =
        String.sub option 2 (String.length option - 2) |> String.trim
      in
      if path = "" then None else Some path
    | _ :: rest -> scan_git_args rest
    | [] -> None
  in
  List.find_map (fun stage ->
    if stage.bin = "git" then scan_git_args stage.args else None) stages

let normalize_repos_path_token token =
  let token = strip_simple_shell_quotes token |> String.trim in
  let token =
    if String.starts_with ~prefix:"./" token then
      String.sub token 2 (String.length token - 2)
    else token
  in
  match String.split_on_char '/' token with
  | "repos" :: repo :: _ when Coord_worktree.safe_repo_name repo -> Some token
  | _ -> None

let repos_path_hint_of_stages ~cmd stages =
  List.find_map (fun stage ->
    if stage.bin <> "git" && stage.bin <> "gh"
    then None
    else
      stage.args
      |> List.find_map (fun token ->
           match normalize_repos_path_token token with
           | Some path -> Some (path, cmd)
           | None -> None)) stages

let resolve_sandbox_root_git_cwd_of_stages
    ~(config : Coord.config) ~(meta : Keeper_types.keeper_meta) ~cwd ~cmd stages
  =
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
    cwd_normalized = host_root && stages_targets_gh stages
    && Keeper_gh_repo.has_repo_flag cmd
  then cwd, None
  else if cwd_normalized = host_root && stages_targets_git_or_gh stages
  then (
    let explicit_git_c_path = git_c_path_of_stages stages in
    match explicit_git_c_path with
    | Some path when not (bare_worktrees_path path) -> cwd, None
    | _ -> (
      match repos_in_playground () with
      | [ single_repo ] ->
        Filename.concat (Filename.concat host_root "repos") single_repo, None
      | [] ->
        ( cwd
        , Some
            (Printf.sprintf
               "sandbox root cannot run git/gh: mount point %s is not a git repository and \
                no sandbox git clones exist under repos/. First clone a repo with \
                the visible clone tool, then retry with cwd=\"repos/<repo>\" or \
                cwd=\"repos/<repo>/.worktrees/<task>\"."
               host_root) )
      | example_repo :: _ as many ->
        let suggested_cwd =
          match repos_path_hint_of_stages ~cmd:(String.trim cmd) stages with
          | Some (path, _) -> path
          | None -> "repos/" ^ example_repo
        in
        ( cwd
        , Some
            (Printf.sprintf
               "sandbox root cannot run git/gh: mount point %s is not a git repository and \
                multiple sandbox repos exist. Set cwd explicitly before retrying. Example \
                next call: Execute { \"executable\": \"git\", \"argv\": [\"status\"], \"cwd\": %S }. Available repos: %s. \
                Do not retry the same cmd from sandbox root."
               host_root
               suggested_cwd
               (String.concat ", " many)) )))
  else cwd, None

let effective_stages_of_cmd cmd =
  match parse_cmd_to_ir_opt cmd with
  | Some ir -> effective_stages_of_ir ir
  | None -> []
