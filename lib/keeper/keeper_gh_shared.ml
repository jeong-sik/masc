type gh_command_parse_error =
  | Empty_command
  | Unsupported_shell_construct of string
  | Unsupported_command_shape of string

let gh_parse_error_reason = function
  | Empty_command -> "empty_command"
  | Unsupported_shell_construct tag -> tag
  | Unsupported_command_shape tag -> tag
;;

type gh_simple_command = { argv : string list }

let gh_simple_command_argv cmd = cmd.argv

let render_simple_gh_command cmd =
  cmd.argv |> List.map Filename.quote |> String.concat " "
;;

let gh_simple_command_of_argv argv =
  let rec drop_leading_gh = function
    | token :: rest when String_util.equals_ci token "gh" -> drop_leading_gh rest
    | remaining -> remaining
  in
  let argv = drop_leading_gh argv in
  match argv with
  | [] -> Error Empty_command
  | _ when List.exists (fun arg -> String.contains arg '\000') argv ->
    Error (Unsupported_command_shape "nul_arg")
  | _ -> Ok { argv }
;;

(** RFC-0160 S2: lower a parsed [gh_simple_command] to [Shell_ir.t].

    The gh op handler historically dispatched via direct argv
    ([Exec_gate.run_argv_with_status]) without routing through
    {!Masc_exec_command_gate.Shell_command_gate.gate_typed} or
    {!Exec_policy.validate_shell_ir_paths}. This helper allows the
    handler to consume the same single gate as the op=bash path.

    Construction is total: [Bin.Gh] is unconditionally available
    (see lib/exec/bin.ml), so the result has no failure mode. The
    [sandbox] target is passed by the caller to preserve docker
    routing when [meta.sandbox_profile = Docker].

    [args] are [Lit] tokens — each argv entry is a literal by
    construction (the parser sub-grammar rejects shell metachars and
    operators; see {!parse_simple_gh_command}). *)
let gh_simple_command_to_shell_ir
      ?(sandbox = Masc_exec.Sandbox_target.host ())
      ?cwd
      (cmd : gh_simple_command)
  : Masc_exec.Shell_ir.t
  =
  let shell_arg text =
    Masc_exec.Shell_ir.Lit (text, Masc_exec.Shell_ir.default_meta)
  in
  let cwd_scope =
    match cwd with
    | None -> None
    | Some path -> Some (Masc_exec.Path_scope.classify ~raw:path ~cwd:path)
  in
  Masc_exec.Shell_ir.Simple
    { bin = Masc_exec.Bin.of_known Masc_exec.Bin.Gh
    ; args = List.map shell_arg cmd.argv
    ; env = []
    ; cwd = cwd_scope
    ; redirects = []
    ; sandbox
    }
;;

let too_complex_reason_tag (r : Masc_exec.Parsed.reason_too_complex) =
  match r with
  | `Heredoc -> "heredoc"
  | `Here_string -> "here_string"
  | `Cmd_subst -> "cmd_subst"
  | `Proc_subst -> "proc_subst"
  | `Subshell -> "subshell"
  | `Arith_expansion -> "arith_expansion"
  | `Control_flow -> "control_flow"
  | `Logic_op -> "logic_op"
  | `Function_def -> "function_def"
  | `Glob_brace -> "glob_brace"
  | `Background -> "background"
  | `Redirect -> "redirect"
  | `Unknown_construct s -> "unknown:" ^ s
;;

let aborted_reason_tag (r : Masc_exec.Parsed.reason_aborted) =
  match r with
  | `Timeout_50ms -> "timeout_50ms"
  | `Depth_limit -> "depth_limit"
  | `Token_limit_50k -> "token_limit_50k"
;;

let gh_simple_command_of_simple (simple : Masc_exec.Shell_ir.simple)
  : (string * gh_simple_command, gh_command_parse_error) result
  =
  if simple.env <> []
  then Error (Unsupported_command_shape "env_prefix")
  else (
    match simple.cwd with
    | Some _ -> Error (Unsupported_command_shape "cwd_scope")
    | None ->
      if simple.redirects <> []
      then Error (Unsupported_command_shape "redirect")
      else (
        let rec collect acc = function
          | [] -> Ok (Masc_exec.Bin.to_string simple.bin, { argv = List.rev acc })
          | Masc_exec.Shell_ir.Lit (s, _) :: rest -> collect (s :: acc) rest
          | Masc_exec.Shell_ir.Concat _ :: _ ->
            Error (Unsupported_command_shape "concat_arg")
          | Masc_exec.Shell_ir.Var (_, _) :: _ -> Error (Unsupported_command_shape "var_arg")
        in
        collect [] simple.args))
;;

let gh_simple_command_of_parsed (parsed : Masc_exec.Shell_ir.t Masc_exec.Parsed.t)
  : ([ `Gh of gh_simple_command | `Other ], gh_command_parse_error) result
  =
  match parsed with
  | Masc_exec.Parsed.Parsed (Masc_exec.Shell_ir.Simple simple) ->
    (match gh_simple_command_of_simple simple with
     | Error _ as e -> e
     | Ok (bin, cmd) -> if String.equal bin "gh" then Ok (`Gh cmd) else Ok `Other)
  | Masc_exec.Parsed.Parsed (Masc_exec.Shell_ir.Pipeline _) ->
    Error (Unsupported_shell_construct "pipeline")
  | Masc_exec.Parsed.Parse_error _ -> Error (Unsupported_command_shape "parse_error")
  | Masc_exec.Parsed.Parse_aborted reason ->
    Error (Unsupported_shell_construct ("parse_aborted:" ^ aborted_reason_tag reason))
  | Masc_exec.Parsed.Too_complex reason ->
    Error (Unsupported_shell_construct (too_complex_reason_tag reason))
;;

let parse_simple_gh_command (source : string)
  : (gh_simple_command, gh_command_parse_error) result
  =
  let trimmed = String.trim source in
  if trimmed = ""
  then Error Empty_command
  else (
    let parse text =
      match Masc_exec_command_gate.Shell_command_gate.parse_to_ir_opt text with
      | None -> Error (Unsupported_command_shape "parse_error")
      | Some ir -> gh_simple_command_of_parsed (Masc_exec.Parsed.Parsed ir)
    in
    let accept_gh = function
      | Ok (`Gh cmd) when cmd.argv <> [] -> Ok cmd
      | Ok (`Gh _) -> Error Empty_command
      | Ok `Other -> Error (Unsupported_command_shape "missing_gh_binary")
      | Error err -> Error err
    in
    match parse trimmed with
    | Ok (`Gh cmd) when cmd.argv <> [] -> Ok cmd
    | Ok (`Gh _) -> Error Empty_command
    | Ok `Other | Error (Unsupported_command_shape "parse_error") ->
      accept_gh (parse ("gh " ^ trimmed))
    | Error err -> Error err)
;;

(** Regex matching --repo owner/name, --repo=owner/name, or -R owner/name in gh CLI commands. *)
let repo_flag_re =
  Re.compile
    (Re.seq
       [ Re.alt [ Re.str "--repo"; Re.str "-R" ]
       ; Re.alt [ Re.rep1 Re.blank; Re.str "=" ]
       ; Re.rep1 (Re.compl [ Re.blank ])
       ])
;;

let has_repo_flag cmd = Re.execp repo_flag_re cmd

let is_valid_repo_segment segment =
  segment <> ""
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '-' | '_' -> true
         | _ -> false)
       segment
;;

let validate_repo_slug raw =
  let slug = String.trim raw in
  match String.split_on_char '/' slug with
  | [ owner; repo ] when is_valid_repo_segment owner && is_valid_repo_segment repo ->
    Ok (owner ^ "/" ^ repo)
  | _ -> Error "repo must be an owner/repo slug without spaces or extra flags."
;;

let rec strip_repo_flags_from_args = function
  | [] -> []
  | "--repo" :: _value :: rest | "-R" :: _value :: rest -> strip_repo_flags_from_args rest
  | arg :: rest when String.starts_with ~prefix:"--repo=" arg ->
    strip_repo_flags_from_args rest
  | arg :: rest -> arg :: strip_repo_flags_from_args rest
;;

let args_have_repo_flag args =
  List.exists
    (fun arg -> arg = "--repo" || arg = "-R" || String.starts_with ~prefix:"--repo=" arg)
    args
;;

let inject_repo_flag_args ~repo_slug args =
  [ "--repo"; repo_slug ] @ strip_repo_flags_from_args args
;;

let gh_simple_command_has_repo_flag cmd = args_have_repo_flag cmd.argv

let gh_simple_command_with_repo_flag ~repo_slug cmd =
  { argv = inject_repo_flag_args ~repo_slug cmd.argv }
;;

let repo_slug_of_remote_url url =
  match Tool_code_write.extract_github_org_repo url with
  | Some slug ->
    (match validate_repo_slug slug with
     | Ok v -> Some v
     | Error detail ->
       Log.Misc.warn "repo slug validation error discarded: %s" detail;
       None)
  | None -> None
;;

(** Read an origin slug from a concrete git config path without invoking git.
    This survives host/container worktree divergence where [.git] points at a
    container-only gitdir but the host-side parent clone config is readable. *)
let origin_url_of_git_config_path config_path =
  if not (Sys.file_exists config_path)
  then None
  else (
    let ic = open_in_bin config_path in
    Eio_guard.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
         let rec loop ~in_origin =
           match input_line ic with
           | line ->
             let trimmed = String.trim line in
             if trimmed = "" || String.starts_with ~prefix:";" trimmed
             then loop ~in_origin
             else if String.starts_with ~prefix:"[" trimmed
             then loop ~in_origin:(String.equal trimmed "[remote \"origin\"]")
             else if
               in_origin
               && (String.starts_with ~prefix:"url = " trimmed
                   || String.starts_with ~prefix:"url=" trimmed)
             then (
               let value =
                 if String.starts_with ~prefix:"url = " trimmed
                 then String.sub trimmed 6 (String.length trimmed - 6)
                 else String.sub trimmed 4 (String.length trimmed - 4)
               in
               Some (String.trim value))
             else loop ~in_origin
           | exception End_of_file -> None
         in
         loop ~in_origin:false))
;;

let repo_slug_of_git_config_path config_path =
  match origin_url_of_git_config_path config_path with
  | Some url -> repo_slug_of_remote_url url
  | None -> None
;;

let repo_slug_of_git_config ~git_root =
  Filename.concat git_root ".git/config" |> repo_slug_of_git_config_path
;;

let repo_root_inferred_from_worktree_cwd worktree_cwd =
  let marker = "/.worktrees/" in
  match String_util.find_substring worktree_cwd marker with
  | None -> None
  | Some idx -> Some (String.sub worktree_cwd 0 idx)
;;

let origin_url_of_worktree_parent_config ~worktree_cwd =
  match repo_root_inferred_from_worktree_cwd worktree_cwd with
  | Some repo_root ->
    origin_url_of_git_config_path (Filename.concat repo_root ".git/config")
  | None -> None
;;

let origin_url_of_worktree_gitfile ~worktree_cwd =
  let dotgit = Filename.concat worktree_cwd ".git" in
  if (not (Sys.file_exists dotgit)) || Sys.is_directory dotgit
  then None
  else (
    try
      let line =
        let ic = open_in_bin dotgit in
        Eio_guard.protect ~finally:(fun () -> close_in_noerr ic) (fun () -> input_line ic)
      in
      let prefix = "gitdir:" in
      let trimmed = String.trim line in
      if not (String.starts_with ~prefix trimmed)
      then None
      else (
        let raw =
          String.sub
            trimmed
            (String.length prefix)
            (String.length trimmed - String.length prefix)
          |> String.trim
        in
        let gitdir =
          if Filename.is_relative raw then Filename.concat worktree_cwd raw else raw
        in
        match origin_url_of_git_config_path (Filename.concat gitdir "config") with
        | Some _ as origin -> origin
        | None ->
          let common_git_dir = Filename.dirname (Filename.dirname gitdir) in
          origin_url_of_git_config_path (Filename.concat common_git_dir "config"))
    with
    | Sys_error _ | End_of_file -> None)
;;

let repo_slug_of_git_command ~cwd =
  let argv = [ "git"; "remote"; "get-url"; "origin" ] in
  match
    Masc_exec.Exec_gate.run_argv_with_status
      ~actor:`Coord_git
      ~raw_source:(String.concat " " argv)
      ~summary:"keeper gh repo slug from git"
      ~cwd
      ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Git_meta ())
      argv
  with
  | Unix.WEXITED 0, url -> repo_slug_of_remote_url url
  | _ -> None
;;

let origin_url_of_git_command ~cwd =
  let argv = [ "git"; "remote"; "get-url"; "origin" ] in
  match
    Masc_exec.Exec_gate.run_argv_with_status
      ~actor:`Coord_git
      ~raw_source:(String.concat " " argv)
      ~summary:"keeper gh origin url from git"
      ~cwd
      ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Git_meta ())
      argv
  with
  | Unix.WEXITED 0, url ->
    let url = String.trim url in
    if url = "" then None else Some url
  | _ -> None
;;

let origin_url_of_task_worktree ~git_root ~worktree_cwd =
  [ (fun () -> origin_url_of_git_config_path (Filename.concat git_root ".git/config"))
  ; (fun () -> origin_url_of_worktree_parent_config ~worktree_cwd)
  ; (fun () -> origin_url_of_worktree_gitfile ~worktree_cwd)
  ; (fun () -> origin_url_of_git_command ~cwd:git_root)
  ; (fun () -> origin_url_of_git_command ~cwd:worktree_cwd)
  ]
  |> List.find_map (fun f -> f ())
;;

let repo_slug_of_task_worktree ~git_root ~worktree_cwd =
  match origin_url_of_task_worktree ~git_root ~worktree_cwd with
  | Some url -> repo_slug_of_remote_url url
  | None -> None
;;

let repo_slug_of_git_root ~git_root =
  match repo_slug_of_git_config ~git_root with
  | Some slug -> Some slug
  | None -> repo_slug_of_git_command ~cwd:git_root
;;
