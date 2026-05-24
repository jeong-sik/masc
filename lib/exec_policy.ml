(** Shared execution policy for shell-like tool frontends.

    [Worker_dev_tools] is an Agent SDK tool bundle. This module is the common
    policy substrate beneath that bundle plus keeper/code-shell callers. *)

module Paths = Exec_policy_paths
module Log_sanitize = Exec_policy_log_sanitize
module Command_syntax = Exec_policy_command_syntax
module Mutation_classifier = Exec_policy_mutation_classifier
module Exec_shell_gate = Masc_exec_command_gate.Shell_command_gate

open Command_syntax

let resolve_path = Paths.resolve_path
let validate_path = Paths.validate_path

let dev_allowed_commands = Dev_exec_allowlist.dev

let default_common_allowed_commands_hint =
  "scripts/dune-local.sh, git, rg, ls, cat, head, tail, grep, find, make, node, npm, \
   python3, pytest, cargo, go"
;;

let allowed_commands_hint = function
  | [] -> "(none)"
  | commands -> String.concat ", " commands
;;

let command_blocked_hint ?allowed_commands name =
  let looks_like_source_code s =
    (match String.index_opt s '.' with
     | Some i -> i > 0 && i < String.length s - 1
     | None -> false)
    || List.mem
         s
         [ "let"
         ; "match"
         ; "if"
         ; "then"
         ; "else"
         ; "fun"
         ; "rec"
         ; "in"
         ; "module"
         ; "open"
         ; "type"
         ; "def"
         ; "class"
         ; "import"
         ; "from"
         ]
  in
  let alt =
    match name with
    | "sort" | "uniq" -> " Use rg or jq for filtering."
    | "sed" | "awk" -> " Use keeper_fs_edit for in-place edits."
    | "find" -> " Use rg --files or masc_code_search."
    | "curl" | "wget" ->
      " Use masc_web_fetch to fetch page content, or masc_web_search to find sources."
    | "gh" ->
      " Use keeper_pr_* tools for GitHub operations (create, merge, comment) or \
       masc_board_post to escalate. Use git directly for repository/worktree/branch operations."
    | "docker"
    | "podman"
    | "kubectl"
    | "systemctl"
    | "brew"
    | "apt"
    | "apt-get"
    | "yum"
    | "dnf" ->
      Printf.sprintf
        " '%s' operates on host / cluster state and is deliberately excluded from the \
         keeper sandbox. If you need this operation, escalate to an operator via \
         masc_board_post instead of retrying."
        name
    | "ssh" | "scp" | "rsync" | "ftp" | "sftp" | "nc" ->
      Printf.sprintf
        " '%s' is a network primitive and is not permitted. Keeper network access goes \
         through masc_web_search or masc_web_fetch tools."
        name
    | _ when looks_like_source_code name ->
      " This looks like source code, not a shell command - use masc_code_edit / \
       masc_code_write / masc_code_read instead."
    | _ -> ""
  in
  let list_label, commands =
    match allowed_commands with
    | None -> "Common allowed commands", default_common_allowed_commands_hint
    | Some commands -> "Allowed commands for this tool", allowed_commands_hint commands
  in
  Printf.sprintf
    "Command blocked: '%s' is not allowed. %s: %s.%s See \
     keeper_tools_list for the exhaustive tool surface, and keeper_fs_read / \
     keeper_fs_edit for file operations."
    name
    list_label
    commands
    alt
;;

type block_reason =
  | Empty_command
  | Chain_or_redirect
  | Injection
  | Process_substitution
  | Unsafe_redirect
  | Pipes_not_allowed
  | Direct_dune_invocation
  | Command_not_allowed of string

let block_reason_to_string = function
  | Empty_command -> "command must not be empty"
  | Chain_or_redirect ->
    "Blocked: chaining (&&/||/;) and redirects (|/>) are not allowed. Run ONE command \
     per call. To change directory, use the `cwd` argument instead of `cd` - Good: \
     cwd='repos/masc-mcp', cmd='scripts/dune-local.sh build'. Bad:  cmd='cd repos/masc-mcp && dune \
     build'. For pipelines like `rg foo | wc -l`, run the primary command and process \
     output at the LLM layer. To write files, use keeper_fs_edit."
  | Injection ->
    "Shell injection syntax (;, &&, standalone &, `, $) not allowed. Run ONE command per \
     call. To change directory, use the `cwd` argument - Good: cwd='repos/masc-mcp', \
     cmd='scripts/dune-local.sh build'. Bad:  cmd='cd repos/masc-mcp && dune build' or cmd='cmd1 ; cmd2'. \
     Relative paths resolve from `cwd` (defaults to playground root). For file writes, \
     use keeper_fs_edit."
  | Process_substitution -> "Process substitution (<(...) or >(...)) is not allowed."
  | Unsafe_redirect ->
    "Redirect syntax is not allowed in this shell surface. Consume stdout/stderr \
     directly from the tool response, and use a dedicated write tool for files."
  | Pipes_not_allowed -> "Pipes are not allowed. Run one command per call."
  | Direct_dune_invocation ->
    "Direct `dune` is blocked in local agent shells because it bypasses \
     scripts/dune-local.sh's machine-wide build lock and can trigger \
     host-wide ENFILE/EMFILE pressure. Use `scripts/dune-local.sh build ...` \
     from the repo root instead."
  | Command_not_allowed name -> command_blocked_hint name
;;

let block_reason_to_string_with_allowlist ~allowed_commands = function
  | Direct_dune_invocation -> block_reason_to_string Direct_dune_invocation
  | Command_not_allowed name -> command_blocked_hint ~allowed_commands name
  | reason -> block_reason_to_string reason
;;

let validate_command_name_with_allowlist ~allowed_commands = function
  | None -> Error Empty_command
  | Some name when List.mem name allowed_commands -> Ok ()
  | Some name -> Error (Command_not_allowed name)
;;

let strict_allowlist_policy ~allowed_commands : Exec_shell_gate.allowlist_policy =
  { allowed_commands; allow_pipes = false; redirect_allowed = false }
;;

let coding_allowlist_policy ?(allow_pipes = true) ~allowed_commands ()
  : Exec_shell_gate.allowlist_policy =
  { allowed_commands; allow_pipes; redirect_allowed = false }
;;

let rec shell_ir_literal_text = function
  | Masc_exec.Shell_ir.Lit (text, _) -> Some text
  | Masc_exec.Shell_ir.Concat parts ->
    let rec loop acc = function
      | [] -> Some (String.concat "" (List.rev acc))
      | part :: rest ->
        (match shell_ir_literal_text part with
         | Some text -> loop (text :: acc) rest
         | None -> None)
    in
    loop [] parts
  | Masc_exec.Shell_ir.Var (_, _) -> None
;;

let simple_literal_args (simple : Masc_exec.Shell_ir.simple) =
  let rec loop acc = function
    | [] -> Some (List.rev acc)
    | arg :: rest ->
      (match shell_ir_literal_text arg with
       | Some text -> loop (text :: acc) rest
       | None -> None)
  in
  loop [] simple.Masc_exec.Shell_ir.args
;;

let meta_has_unquoted_glob (meta : Masc_exec.Shell_ir.arg_meta) =
  meta.glob && not meta.quoted
;;

let rec shell_ir_arg_has_unquoted_glob = function
  | Masc_exec.Shell_ir.Lit (_, meta)
  | Masc_exec.Shell_ir.Var (_, meta) -> meta_has_unquoted_glob meta
  | Masc_exec.Shell_ir.Concat parts ->
    List.exists shell_ir_arg_has_unquoted_glob parts
;;

let simple_has_unquoted_glob (simple : Masc_exec.Shell_ir.simple) =
  List.exists
    shell_ir_arg_has_unquoted_glob
    simple.Masc_exec.Shell_ir.args
  || List.exists
       (fun (_, arg) -> shell_ir_arg_has_unquoted_glob arg)
       simple.Masc_exec.Shell_ir.env
;;

let rec shell_ir_has_unquoted_glob = function
  | Masc_exec.Shell_ir.Simple simple -> simple_has_unquoted_glob simple
  | Masc_exec.Shell_ir.Pipeline stages ->
    List.exists shell_ir_has_unquoted_glob stages
;;

let validate_no_unquoted_glob ast =
  if shell_ir_has_unquoted_glob ast then Error Injection else Ok ()
;;

let validate_wrapper_target ~allowed_commands ~wrapper_name = function
  | None -> Error (Command_not_allowed wrapper_name)
  | Some "dune" -> Error Direct_dune_invocation
  | Some name -> validate_command_name_with_allowlist ~allowed_commands (Some name)
;;

let validate_env_wrapped_stage ~allowed_commands
      (simple : Masc_exec.Shell_ir.simple)
  =
  let bin = Masc_exec.Bin.to_string simple.Masc_exec.Shell_ir.bin in
  if not (String.equal bin "env")
  then Ok ()
  else
    match simple_literal_args simple with
    | None -> Error Injection
    | Some args ->
      validate_wrapper_target
        ~allowed_commands
        ~wrapper_name:"env"
        (command_after_env_prefix args)
;;

let validate_opam_exec_wrapped_stage ~allowed_commands
      (simple : Masc_exec.Shell_ir.simple)
  =
  let bin = Masc_exec.Bin.to_string simple.Masc_exec.Shell_ir.bin in
  if not (String.equal bin "opam")
  then Ok ()
  else
    match simple_literal_args simple with
    | None -> Error Injection
    | Some args ->
      (match opam_exec_command_name args with
       | Some "opam" -> Ok ()
       | command ->
         validate_wrapper_target
           ~allowed_commands
           ~wrapper_name:"opam"
           command)
;;

let validate_wrapped_stages ~allowed_commands ast =
  let rec loop = function
    | Masc_exec.Shell_ir.Simple simple -> (
      match validate_env_wrapped_stage ~allowed_commands simple with
      | Ok () -> validate_opam_exec_wrapped_stage ~allowed_commands simple
      | Error _ as error -> error)
    | Masc_exec.Shell_ir.Pipeline stages ->
      let rec loop_stages = function
        | [] -> Ok ()
        | stage :: rest ->
          (match loop stage with
           | Ok () -> loop_stages rest
           | Error _ as error -> error)
      in
      loop_stages stages
  in
  loop ast
;;

let block_reason_of_exec_reject : Exec_shell_gate.reject_reason -> block_reason =
  function
  | Command_not_in_allowlist { bin } -> Command_not_allowed bin
  | Pipeline_segment_disallowed { bin; _ } -> Command_not_allowed bin
  | Pipes_not_allowed _ -> Pipes_not_allowed
  | Redirect_disallowed_in_caller _
  | Path_outside_policy _ -> Unsafe_redirect
;;

let block_reason_of_exec_too_complex
      (reason : Exec_shell_gate.too_complex_reason)
  : block_reason =
  match reason with
  | Unsupported_construct `Proc_subst -> Process_substitution
  | Unsupported_construct (`Heredoc | `Here_string | `Redirect) -> Unsafe_redirect
  | Unsupported_nested_pipeline
  | Unsupported_construct
      ( `Cmd_subst
      | `Subshell
      | `Arith_expansion
      | `Control_flow
      | `Logic_op
      | `Function_def
      | `Glob_brace
      | `Background
      | `Unknown_construct _ ) -> Injection
;;

type parse_mode = Strict | Coding

let parse_string_to_ir ~mode cmd =
  let trimmed = String.trim cmd in
  if trimmed = ""
  then Error Empty_command
  else (
    match Masc_exec_bash_parser.Bash.parse_string trimmed with
    | (Masc_exec.Parsed.Parse_error _ | Masc_exec.Parsed.Parse_aborted _) ->
      Error (match mode with Strict -> Chain_or_redirect | Coding -> Injection)
    | Masc_exec.Parsed.Too_complex reason ->
      Error (block_reason_of_exec_too_complex (Unsupported_construct reason))
    | Masc_exec.Parsed.Parsed ir -> Ok ir)
;;

let command_context_with_allowlist ?caller ~allowed_commands ir =
  let verdict =
    Exec_shell_gate.gate_typed
      ?caller
      ~ir
      ~allowlist:(strict_allowlist_policy ~allowed_commands)
      ~path_policy:Exec_shell_gate.allow_all_paths
      ~sandbox:Exec_shell_gate.host_sandbox
      ()
  in
  match verdict with
  | Allow context ->
    if context.Exec_shell_gate.direct_dune_seen
    then Error Direct_dune_invocation
    else (
      match validate_no_unquoted_glob context.Exec_shell_gate.ast with
      | Error _ as err -> err
      | Ok () ->
        (match
           validate_wrapped_stages ~allowed_commands context.Exec_shell_gate.ast
         with
         | Ok () -> Ok context
         | Error _ as err -> err))
  | Reject { context; reason; _ } ->
    if context.Exec_shell_gate.direct_dune_seen
    then Error Direct_dune_invocation
    else Error (block_reason_of_exec_reject reason)
  | Cannot_parse _ -> Error Chain_or_redirect
  | Too_complex { reason } -> Error (block_reason_of_exec_too_complex reason)
;;

let validate_command_with_allowlist ?caller ~allowed_commands ir =
  command_context_with_allowlist ?caller ~allowed_commands ir
  |> Result.map (fun _ -> ())
;;

let validate_command ?caller ir =
  validate_command_with_allowlist ?caller ~allowed_commands:dev_allowed_commands ir
;;

let command_context_coding_with_allowlist
      ?caller
      ?(allow_pipes = true)
      ~(allowed_commands : string list)
      ir
  =
  let verdict =
    Exec_shell_gate.gate_typed
      ?caller
      ~ir
      ~allowlist:(coding_allowlist_policy ~allow_pipes ~allowed_commands ())
      ~path_policy:Exec_shell_gate.allow_all_paths
      ~sandbox:Exec_shell_gate.host_sandbox
      ()
  in
  match verdict with
  | Allow context ->
    if context.Exec_shell_gate.direct_dune_seen
    then Error Direct_dune_invocation
    else (
      match validate_no_unquoted_glob context.Exec_shell_gate.ast with
      | Error _ as err -> err
      | Ok () ->
        (match
           validate_wrapped_stages ~allowed_commands context.Exec_shell_gate.ast
         with
         | Ok () -> Ok context
         | Error _ as err -> err))
  | Reject { context; reason; _ } ->
    (match reason with
     | Pipes_not_allowed _ -> Error Pipes_not_allowed
     | _ when context.Exec_shell_gate.direct_dune_seen ->
       Error Direct_dune_invocation
     | _ -> Error (block_reason_of_exec_reject reason))
  | Cannot_parse _ -> Error Injection
  | Too_complex { reason } -> Error (block_reason_of_exec_too_complex reason)
;;

let validate_command_coding_with_allowlist ?caller ?allow_pipes ~allowed_commands ir =
  command_context_coding_with_allowlist
    ?caller
    ?allow_pipes
    ~allowed_commands
    ir
  |> Result.map (fun _ -> ())
;;

let validate_command_coding ?caller ir =
  validate_command_coding_with_allowlist
    ?caller
    ~allow_pipes:true
    ~allowed_commands:dev_allowed_commands
    ir
;;

let looks_like_url token =
  match String.index_opt token ':' with
  | Some idx when idx + 2 < String.length token ->
    token.[idx + 1] = '/' && token.[idx + 2] = '/'
  | _ -> false
;;

(* Path-argument descriptors moved to [Exec_policy_path_arg_descriptor]
   under Shell IR Adjacent Surfaces Plan §P11. The descriptor module
   is consulted before the [looks_like_path_token] heuristic so path
   validation routes through typed metadata first. *)
let is_path_flag = Exec_policy_path_arg_descriptor.is_path_flag

let path_flag_requires_existing_dir =
  Exec_policy_path_arg_descriptor.path_flag_requires_existing_dir
;;

let path_value_of_flagged_token =
  Exec_policy_path_arg_descriptor.path_value_of_flagged_token
;;

let inline_path_flag_requires_existing_dir =
  Exec_policy_path_arg_descriptor.inline_path_flag_requires_existing_dir
;;

let command_materializes_path_arg =
  Exec_policy_path_arg_descriptor.command_materializes_path_arg
;;

let path_is_existing_dir ?workdir path =
  let resolved = resolve_path ?base_dir:workdir path in
  try Sys.file_exists resolved && Sys.is_directory resolved with
  | Sys_error _ -> false
;;

let looks_like_path_token token =
  token <> ""
  && (not (looks_like_url token))
  && (token = "."
      || token = ".."
      || String.starts_with ~prefix:"/" token
      || String.starts_with ~prefix:"./" token
      || String.starts_with ~prefix:"../" token
      || String.starts_with ~prefix:"~/" token
      || String.contains token '/')
;;

let token_value_is_explicit_path token =
  token = "."
  || token = ".."
  || String.starts_with ~prefix:"/" token
  || String.starts_with ~prefix:"./" token
  || String.starts_with ~prefix:"../" token
  || String.starts_with ~prefix:"~/" token
;;

let token_has_parent_dir_segment token =
  token
  |> String.split_on_char '/'
  |> List.exists (String.equal "..")
;;

let git_revisionish_token ?workdir token =
  let token = String.trim token in
  token <> ""
  && String.contains token '/'
  && (not (token_value_is_explicit_path token))
  && not (token_has_parent_dir_segment token)
  &&
  let resolved = resolve_path ?base_dir:workdir token in
  not (Sys.file_exists resolved)
;;

let token_value_is_redirect_to_dev_null value =
  String.equal value ">/dev/null"
  || String.equal value "2>/dev/null"
  || String.equal value "1>/dev/null"
  || String.equal value ">>/dev/null"
  || String.equal value "2>>/dev/null"
  || String.equal value "1>>/dev/null"
;;

let token_value_is_redirect_op value =
  match value with
  | ">" | ">>" | "<" | "2>" | "2>>" | "1>" | "1>>" -> true
  | _ -> false
;;

let command_pattern_arg_flags cmd =
  match cmd with
  | "find" ->
    [ "-name", false
    ; "-iname", false
    ; "-path", false
    ; "-ipath", false
    ; "-wholename", false
    ; "-iwholename", false
    ; "-regex", false
    ; "-iregex", false
    ]
  | "rg" ->
    [ "-e", true
    ; "--regexp", true
    ; "-f", true
    ; "--file", true
    ; "-g", false
    ; "--glob", false
    ; "--iglob", false
    ; "--type", false
    ; "-t", false
    ; "--type-not", false
    ; "-T", false
    ]
  | "grep" ->
    [ "-e", true
    ; "--regexp", true
    ; "-f", true
    ; "--file", true
    ; "--include", false
    ; "--exclude", false
    ]
  | "sed" -> [ "-e", true; "--expression", true ]
  | "gh" ->
    [ "-R", false
    ; "--repo", false
    ; "--json", false
    ; "--jq", false
    ; "--template", false
    ; "--search", false
    ; "--state", false
    ; "--author", false
    ; "--assignee", false
    ; "--label", false
    ; "--base", false
    ; "--head", false
    ]
  | "git" ->
    [ "--branches", false
    ; "--remotes", false
    ; "--glob", false
    ; "--exclude", false
    ; "--format", false
    ; "--pretty", false
    ; "--author", false
    ; "--grep", false
    ]
  | _ -> []
;;

let token_is_inline_pattern_flag cmd value =
  command_pattern_arg_flags cmd
  |> List.find_map (fun (flag, consumes_primary_pattern) ->
    if String.starts_with ~prefix:(flag ^ "=") value
    then Some consumes_primary_pattern
    else None)
;;

let command_flag_pattern_arity cmd value =
  command_pattern_arg_flags cmd
  |> List.find_map (fun (flag, consumes_primary_pattern) ->
    if String.equal flag value then Some consumes_primary_pattern else None)
;;

let rg_token_is_option_value value =
  String.starts_with ~prefix:"-" value && String.length value > 1
;;

let command_treats_plain_args_as_content = function
  | "echo" | "printf" -> true
  | _ -> false
;;

let path_argument_values command_name args =
  let rg_files_mode =
    String.equal command_name "rg"
    && List.exists (String.equal "--files") args
  in
  let rec loop ~skip_next_pattern ~redirect_target ~seen_primary_pattern acc = function
    | [] -> List.rev acc
    | token :: rest ->
      if redirect_target
      then
        let acc = if String.equal token "/dev/null" then acc else token :: acc in
        loop ~skip_next_pattern:None ~redirect_target:false ~seen_primary_pattern acc rest
      else if token_value_is_redirect_to_dev_null token
      then loop ~skip_next_pattern:None ~redirect_target:false ~seen_primary_pattern acc rest
      else (
        match skip_next_pattern with
        | Some consumes_primary_pattern ->
          loop
            ~skip_next_pattern:None
            ~redirect_target:false
            ~seen_primary_pattern:(seen_primary_pattern || consumes_primary_pattern)
            acc
            rest
        | None ->
          if token_value_is_redirect_op token
          then loop ~skip_next_pattern:None ~redirect_target:true ~seen_primary_pattern acc rest
          else (
            match command_flag_pattern_arity command_name token with
            | Some consumes_primary_pattern ->
              loop
                ~skip_next_pattern:(Some consumes_primary_pattern)
                ~redirect_target:false
                ~seen_primary_pattern
                acc
                rest
            | None ->
              (match token_is_inline_pattern_flag command_name token with
               | Some consumes_primary_pattern ->
                 loop
                   ~skip_next_pattern:None
                   ~redirect_target:false
                   ~seen_primary_pattern:(seen_primary_pattern || consumes_primary_pattern)
                   acc
                   rest
               | None when command_treats_plain_args_as_content command_name ->
                 loop ~skip_next_pattern:None ~redirect_target:false ~seen_primary_pattern acc rest
               | None when command_name = "sed"
                           && (not seen_primary_pattern)
                           && not (rg_token_is_option_value token) ->
                 loop
                   ~skip_next_pattern:None
                   ~redirect_target:false
                   ~seen_primary_pattern:true
                   acc
                   rest
               | None when command_name = "rg"
                           && (not rg_files_mode)
                           && (not seen_primary_pattern)
                           && not (rg_token_is_option_value token) ->
                 loop
                   ~skip_next_pattern:None
                   ~redirect_target:false
                   ~seen_primary_pattern:true
                   acc
                   rest
               | None when command_name = "grep"
                           && (not seen_primary_pattern)
                           && not (rg_token_is_option_value token) ->
                 loop
                   ~skip_next_pattern:None
                   ~redirect_target:false
                   ~seen_primary_pattern:true
                   acc
                   rest
               | None ->
                 loop
                   ~skip_next_pattern:None
                   ~redirect_target:false
                   ~seen_primary_pattern
                   (token :: acc)
                   rest)))
  in
  loop
    ~skip_next_pattern:None
    ~redirect_target:false
    ~seen_primary_pattern:false
    []
    args
;;

let literal_args_of_simple (simple : Masc_exec.Shell_ir.simple) =
  let rec loop acc = function
    | [] -> Some (List.rev acc)
    | Masc_exec.Shell_ir.Lit (value, _) :: rest -> loop (value :: acc) rest
    | Masc_exec.Shell_ir.Concat _ :: _ | Masc_exec.Shell_ir.Var (_, _) :: _ -> None
  in
  loop [] simple.args
;;

let existing_dir_path_values_of_simple (simple : Masc_exec.Shell_ir.simple) =
  let command_name = Masc_exec.Bin.to_string simple.bin |> Filename.basename in
  let rec loop expect_existing_dir acc = function
    | [] -> List.rev acc
    | value :: rest ->
      if value = ""
      then loop expect_existing_dir acc rest
      else if expect_existing_dir
      then loop false (value :: acc) rest
      else (
        match path_value_of_flagged_token value with
        | Some value when inline_path_flag_requires_existing_dir value ->
          loop false (value :: acc) rest
        | Some _ -> loop false acc rest
        | None when is_path_flag value -> loop (path_flag_requires_existing_dir value) acc rest
        | None
          when command_materializes_path_arg command_name
               && looks_like_path_token value ->
          loop false (value :: acc) rest
        | None -> loop false acc rest)
  in
  match literal_args_of_simple simple with
  | None -> []
  | Some args -> loop false [] (path_argument_values command_name args)
;;

let rec existing_dir_path_values_of_shell_ir = function
  | Masc_exec.Shell_ir.Simple simple -> existing_dir_path_values_of_simple simple
  | Masc_exec.Shell_ir.Pipeline stages ->
    List.concat_map existing_dir_path_values_of_shell_ir stages
;;

let validate_shell_ir_paths ?keeper_id ?base_path ?workdir shell_ir =
  match workdir with
  | None -> Ok ()
  | Some _ ->
      let validate_path_value ~requires_existing_dir value =
        if String.equal value "/dev/null"
        then Ok ()
        else if not (validate_path ?keeper_id ?base_path ?workdir value)
        then
          Error
            (Keeper_path_check_error.(
               to_message
                 (Path_outside_whitelist
                    { path = value; for_keeper_command = true })))
        else if requires_existing_dir && not (path_is_existing_dir ?workdir value)
        then
          Error
            (Keeper_path_check_error.(
               to_message (Cwd_not_directory { path = value; hint = None })))
        else Ok ()
      in
      let rec validate_path_values ~command_name expect_existing_dir = function
        | [] -> Ok ()
        | value :: rest ->
          if value = ""
          then validate_path_values ~command_name expect_existing_dir rest
          else if expect_existing_dir
          then
            (match validate_path_value ~requires_existing_dir:true value with
             | Ok () -> validate_path_values ~command_name false rest
             | Error _ as err -> err)
          else (
            match path_value_of_flagged_token value with
            | Some flagged_value ->
              (match
                 validate_path_value
                   ~requires_existing_dir:(inline_path_flag_requires_existing_dir value)
                   flagged_value
               with
               | Ok () -> validate_path_values ~command_name false rest
               | Error _ as err -> err)
            | None when is_path_flag value ->
              validate_path_values
                ~command_name
                (path_flag_requires_existing_dir value)
                rest
            | None
              when String.equal command_name "git"
                   && git_revisionish_token ?workdir value ->
              validate_path_values ~command_name false rest
            | None when looks_like_path_token value ->
              (match validate_path_value ~requires_existing_dir:false value with
               | Ok () -> validate_path_values ~command_name false rest
               | Error _ as err -> err)
            | None -> validate_path_values ~command_name false rest)
      in
      let rec validate_redirects = function
        | [] -> Ok ()
        | Masc_exec.Redirect_scope.File { target; _ } :: rest ->
          let target = Masc_exec.Path_scope.raw target in
          (match validate_path_value ~requires_existing_dir:false target with
           | Ok () -> validate_redirects rest
           | Error _ as err -> err)
        | Masc_exec.Redirect_scope.Fd_to_fd _ :: rest -> validate_redirects rest
      in
      let validate_cwd = function
        | None -> Ok ()
        | Some cwd ->
          Masc_exec.Path_scope.raw cwd
          |> validate_path_value ~requires_existing_dir:true
      in
      let validate_simple (simple : Masc_exec.Shell_ir.simple) =
        let command_name = Masc_exec.Bin.to_string simple.bin |> Filename.basename in
        let argv_result =
          match literal_args_of_simple simple with
          | None -> Ok ()
          | Some args ->
            path_argument_values command_name args
            |> validate_path_values ~command_name false
        in
        match validate_cwd simple.cwd with
        | Error _ as err -> err
        | Ok () ->
          (match argv_result with
           | Error _ as err -> err
           | Ok () -> validate_redirects simple.redirects)
      in
      let rec validate_parsed_shell_ir = function
        | Masc_exec.Shell_ir.Simple simple -> validate_simple simple
        | Masc_exec.Shell_ir.Pipeline stages ->
          let rec loop = function
            | [] -> Ok ()
            | Masc_exec.Shell_ir.Simple simple :: rest ->
              (match validate_simple simple with
               | Ok () -> loop rest
               | Error _ as err -> err)
            | Masc_exec.Shell_ir.Pipeline nested :: rest ->
              (match validate_parsed_shell_ir (Masc_exec.Shell_ir.Pipeline nested) with
               | Ok () -> loop rest
               | Error _ as err -> err)
          in
          loop stages
      in
      validate_parsed_shell_ir shell_ir
;;


let is_git_branch_switch = Mutation_classifier.is_git_branch_switch
let is_destructive_bash_operation = Mutation_classifier.is_destructive_bash_operation
let flat_stage_words = Mutation_classifier.flat_stage_words
let stage_words_of_string = Mutation_classifier.stage_words_of_string
let sanitize_command_for_log = Log_sanitize.sanitize_command_for_log
let sanitize_command_for_log_of_ir = Log_sanitize.sanitize_command_for_log_of_ir
let truncate_for_log = Log_sanitize.truncate_for_log

let block_reason_tag = function
  | Empty_command -> "empty_command"
  | Chain_or_redirect -> "chain_or_redirect"
  | Injection -> "injection"
  | Process_substitution -> "process_substitution"
  | Unsafe_redirect -> "unsafe_redirect"
  | Pipes_not_allowed -> "pipes_not_allowed"
  | Direct_dune_invocation -> "direct_dune_invocation"
  | Command_not_allowed _ -> "command_not_allowed"
;;

let attribution_of_validation ~cmd (result : (unit, block_reason) result) : Attribution.t =
  match result with
  | Ok () ->
    let evidence : Yojson.Safe.t = `Assoc [ "cmd", `String cmd ] in
    Attribution.passed ~origin:Det ~gate:"worker_dev_tools" ~evidence
  | Error br ->
    let command_name =
      match br with
      | Command_not_allowed name -> Some name
      | Direct_dune_invocation -> Some "dune"
      | _ -> None
    in
    let evidence : Yojson.Safe.t =
      `Assoc
        ([ "cmd", `String cmd; "block_reason", `String (block_reason_tag br) ]
         @
         match command_name with
         | Some n -> [ "command_name", `String n ]
         | None -> [])
    in
    Attribution.policy_failed
      ~origin:Det
      ~gate:"worker_dev_tools"
      ~evidence
      ~reason:(block_reason_to_string br)
;;
