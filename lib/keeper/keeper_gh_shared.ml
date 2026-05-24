type gh_command_parse_error =
  | Empty_command
  | Unsupported_shell_construct of string
  | Unsupported_command_shape of string

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

    Historical gh dispatch used direct argv and did not route through the
    keeper Shell IR facade. This helper lets GH callers consume the same
    center axis as typed shell dispatch.

    Construction delegates to [Keeper_shell_ir.simple] so GH argv lowering
    uses the same Shell IR constructor facade as typed shell dispatch. *)
let gh_simple_command_to_shell_ir
      ?(sandbox = Masc_exec.Sandbox_target.host ())
      ?cwd
      (cmd : gh_simple_command)
  : Masc_exec.Shell_ir.t
  =
  match cwd with
  | None -> Keeper_shell_ir.simple ~sandbox Masc_exec.Bin.Gh cmd.argv
  | Some path ->
    Keeper_shell_ir.simple
      ~cwd_raw:path
      ~cwd_base:path
      ~sandbox
      Masc_exec.Bin.Gh
      cmd.argv
;;

let gh_simple_command_risk_class
      ?(sandbox = Masc_exec.Sandbox_target.host ())
      (cmd : gh_simple_command)
  : Masc_exec.Shell_ir_risk.risk_class
  =
  let ir = gh_simple_command_to_shell_ir ~sandbox cmd in
  let envelope = Keeper_shell_ir.classify ir in
  envelope.Masc_exec.Shell_ir_risk.risk
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
      match Keeper_shell_command_parse.parse_cmd_to_ir_opt text with
      | Some ir -> gh_simple_command_of_parsed (Masc_exec.Parsed.Parsed ir)
      | None -> Error (Unsupported_command_shape "parse_error")
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

let gh_simple_command_has_repo_flag cmd =
  Keeper_gh_repo.args_have_repo_flag cmd.argv
;;

let gh_simple_command_with_repo_flag ~repo_slug cmd =
  { argv = Keeper_gh_repo.inject_repo_flag_args ~repo_slug cmd.argv }
;;
