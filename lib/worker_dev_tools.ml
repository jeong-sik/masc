(** Development tools for autonomous agent coding.

    Provides file_read, file_write, shell_exec so Fleet agents
    can perform local development tasks (code generation, test runs,
    file modifications).

    file_read/file_write use OCaml stdlib (no Eio filesystem capability needed).
    shell_exec validates commands locally with the Shell IR gate and routes
    supported commands through Shell IR dispatch.

    Safety classification helpers are defined in [Shell_safety_types]
    and re-exported here for backward compat. *)

include Shell_safety_types
module Paths = Worker_dev_tools_paths
module Log_sanitize = Worker_dev_tools_log_sanitize
module Command_syntax = Worker_dev_tools_command_syntax
module Mutation_classifier = Worker_dev_tools_mutation_classifier
module Exec_shell_gate = Masc_exec_command_gate.Shell_command_gate

open Command_syntax

(* --- Safety validation --- *)

let normalize_path = Paths.normalize_path
let resolve_path = Paths.resolve_path
let validate_path = Paths.validate_path

let tool_error ?(recoverable = false) message : Agent_sdk.Types.tool_result =
  Error { Agent_sdk.Types.message; recoverable; error_class = None }
;;

(** shell_exec intentionally supports only a narrow allowlist of dev/test
    commands and rejects shell control syntax to keep execution predictable.

    RFC-0091 PR-1: allowlist tables moved to {!Dev_exec_allowlist}.  These
    bindings remain as in-module aliases until all callers reference
    the shared allowlist module directly. *)
let dev_allowed_commands = Dev_exec_allowlist.dev
let readonly_allowed_commands = Dev_exec_allowlist.readonly

(** Error hint for a blocked command.

    A terse "'foo' is not allowed, allowed: git, rg..." drives the LLM
    to retry variants of foo, including OCaml/Python syntax fragments
    ('let', 'sort', 'Keeper_agent_run.build_ctx_composition', etc.) —
    live log 2026-04-16 shows 12+ retries per ~3MB.

    Give the LLM an actionable nudge based on what it probably tried:
      - OCaml/Python identifier → redirect to code tools
      - common shell command we don't allow (sort, awk) → name the
        supported alternative (rg/jq)
      - everything else → plain allowlist

    The helper is a pure function of the tried command name and the
    optional caller-specific allowlist. *)
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
    (* Contains '.' at a non-boundary position (A.B), or starts with a
       reserved OCaml keyword that no shell command uses. *)
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
      " 'gh' is NOT available in the keeper sandbox. For pull-request work use \
       keeper_pr_list / keeper_pr_status / keeper_pr_create / keeper_pr_review_read / \
       keeper_pr_review_comment. For issues use masc_board_list / masc_board_post / \
       masc_board_comment. For commits or branches just use 'git' directly — it is on \
       the allowlist."
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
      " This looks like source code, not a shell command — use masc_code_edit / \
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
     per call. To change directory, use the `cwd` argument instead of `cd` — Good: \
     cwd='repos/masc-mcp', cmd='scripts/dune-local.sh build'. Bad:  cmd='cd repos/masc-mcp && dune \
     build'. For pipelines like `rg foo | wc -l`, run the primary command and process \
     output at the LLM layer. To write files, use keeper_fs_edit."
  | Injection ->
    "Shell injection syntax (;, &&, standalone &, `, $) not allowed. Run ONE command per \
     call. To change directory, use the `cwd` argument — Good: cwd='repos/masc-mcp', \
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
  | Masc_exec.Shell_ir.Lit text -> Some text
  | Masc_exec.Shell_ir.Concat parts ->
    let rec loop acc = function
      | [] -> Some (String.concat "" (List.rev acc))
      | part :: rest ->
        (match shell_ir_literal_text part with
         | Some text -> loop (text :: acc) rest
         | None -> None)
    in
    loop [] parts
  | Masc_exec.Shell_ir.Var _ -> None
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

let validate_wrapper_target ~allowed_commands ~wrapper_name = function
  | None -> Error (Command_not_allowed wrapper_name)
  | Some "dune" -> Error Direct_dune_invocation
  | Some name ->
    validate_command_name_with_allowlist
      ~allowed_commands
      (Some name)
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

let command_context_with_allowlist ?caller ~allowed_commands cmd =
  let trimmed = String.trim cmd in
  if trimmed = ""
  then Error Empty_command
  else (
    let verdict =
      Exec_shell_gate.gate
        ?caller
        ~raw:trimmed
        ~allowlist:(strict_allowlist_policy ~allowed_commands)
        ~path_policy:Exec_shell_gate.allow_all_paths
        ~sandbox:Exec_shell_gate.host_sandbox
        ()
    in
    match verdict with
    | Allow context ->
      if context.Exec_shell_gate.direct_dune_seen
      then Error Direct_dune_invocation
      else Ok ()
    | Reject { context; reason; _ } ->
      if context.Exec_shell_gate.direct_dune_seen
      then Error Direct_dune_invocation
      else Error (block_reason_of_exec_reject reason)
    | Cannot_parse _ -> Error Chain_or_redirect
    | Too_complex { reason } -> Error (block_reason_of_exec_too_complex reason))
;;

let validate_command_with_allowlist ?caller ~allowed_commands cmd =
  command_context_with_allowlist ?caller ~allowed_commands cmd
  |> Result.map (fun _ -> ())
;;

let validate_command ?caller cmd =
  validate_command_with_allowlist ?caller ~allowed_commands:dev_allowed_commands cmd
;;

let legendary_caller_of_exec = function
  | Exec_shell_gate.Worker_dev_tools -> Legendary_counters.Worker_dev_tools
  | Exec_shell_gate.Tool_code_write -> Legendary_counters.Tool_code_write
  | Exec_shell_gate.Keeper_shell_bash -> Legendary_counters.Keeper_shell_bash
;;

let legendary_verdict_of_exec = function
  | Exec_shell_gate.Allow _ -> Legendary_counters.Allow
  | Exec_shell_gate.Reject _ -> Legendary_counters.Reject
  | Exec_shell_gate.Cannot_parse _
  | Exec_shell_gate.Too_complex _ -> Legendary_counters.Cannot_parse
;;

let record_exec_shell_gate ?caller verdict =
  match caller with
  | None -> ()
  | Some c ->
    Legendary_counters.incr_shell_gate
      ~caller:(legendary_caller_of_exec c)
      ~verdict:(legendary_verdict_of_exec verdict)
;;

let validate_command_coding_with_allowlist
      ?caller
      ?(allow_pipes = true)
      ~(allowed_commands : string list)
      cmd
  =
  let trimmed = String.trim cmd in
  if trimmed = ""
  then Error Empty_command
  else (
    let verdict =
      Exec_shell_gate.gate
        ?caller
        ~raw:trimmed
        ~allowlist:(coding_allowlist_policy ~allow_pipes ~allowed_commands ())
        ~path_policy:Exec_shell_gate.allow_all_paths
        ~sandbox:Exec_shell_gate.host_sandbox
        ()
    in
    record_exec_shell_gate ?caller verdict;
    match verdict with
    | Allow context ->
      if context.Exec_shell_gate.direct_dune_seen
      then Error Direct_dune_invocation
      else validate_wrapped_stages ~allowed_commands context.Exec_shell_gate.ast
    | Reject { context; reason; _ } ->
      (match reason with
       | Pipes_not_allowed _ -> Error Pipes_not_allowed
       | _ when context.Exec_shell_gate.direct_dune_seen ->
         Error Direct_dune_invocation
       | _ -> Error (block_reason_of_exec_reject reason))
    | Cannot_parse _ -> Error Injection
    | Too_complex { reason } -> Error (block_reason_of_exec_too_complex reason))
;;

(** Relaxed command validation for Coding/Full preset keepers.
    Allows pipes; redirects remain blocked by the shell gate. Validates every
    command in the pipeline against [dev_allowed_commands]. *)
let validate_command_coding ?caller cmd =
  validate_command_coding_with_allowlist
    ?caller
    ~allow_pipes:true
    ~allowed_commands:dev_allowed_commands
    cmd
;;

let looks_like_url token =
  let token = strip_wrapping_quotes token in
  match String.index_opt token ':' with
  | Some idx when idx + 2 < String.length token ->
    token.[idx + 1] = '/' && token.[idx + 2] = '/'
  | _ -> false
;;

let is_path_flag token =
  match strip_wrapping_quotes token with
  | "-C" | "--git-dir" | "--work-tree" | "--exec-path" -> true
  | _ -> false
;;

let path_flag_requires_existing_dir token =
  match strip_wrapping_quotes token with
  | "-C" | "--work-tree" -> true
  | _ -> false
;;

let path_value_of_flagged_token token =
  let token = strip_wrapping_quotes token in
  let prefixes = [ "--git-dir="; "--work-tree="; "--exec-path=" ] in
  List.find_map
    (fun prefix ->
       if String.starts_with ~prefix token
       then
         Some
           (String.sub
              token
              (String.length prefix)
              (String.length token - String.length prefix))
       else None)
    prefixes
;;

let inline_path_flag_requires_existing_dir token =
  let token = strip_wrapping_quotes token in
  String.starts_with ~prefix:"--work-tree=" token
;;

let command_materializes_path_arg = function
  | "cat" | "find" | "grep" | "head" | "ls" | "nl" | "rg" | "sed" | "stat"
  | "tail" | "wc" -> true
  | _ -> false
;;

let path_is_existing_dir ?workdir path =
  let resolved = resolve_path ?base_dir:workdir path in
  try Sys.file_exists resolved && Sys.is_directory resolved with
  | Sys_error _ -> false
;;

let looks_like_path_token token =
  let token = strip_wrapping_quotes token in
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
  let token = strip_wrapping_quotes token in
  token = "."
  || token = ".."
  || String.starts_with ~prefix:"/" token
  || String.starts_with ~prefix:"./" token
  || String.starts_with ~prefix:"../" token
  || String.starts_with ~prefix:"~/" token
;;

let token_has_parent_dir_segment token =
  token
  |> strip_wrapping_quotes
  |> String.split_on_char '/'
  |> List.exists (String.equal "..")
;;

let git_revisionish_token ?workdir token =
  let token = strip_wrapping_quotes token |> String.trim in
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
    | Masc_exec.Shell_ir.Lit value :: rest -> loop (value :: acc) rest
    | Masc_exec.Shell_ir.Concat _ :: _ | Masc_exec.Shell_ir.Var _ :: _ -> None
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

let existing_dir_path_values cmd =
  match Masc_exec_bash_parser.Bash.parse_string cmd with
  | Masc_exec.Parsed.Parsed (Masc_exec.Shell_ir.Simple simple) ->
    existing_dir_path_values_of_simple simple
  | Masc_exec.Parsed.Parsed (Masc_exec.Shell_ir.Pipeline stages) ->
    stages
    |> List.concat_map (function
      | Masc_exec.Shell_ir.Simple simple -> existing_dir_path_values_of_simple simple
      | Masc_exec.Shell_ir.Pipeline _ -> [])
  | Masc_exec.Parsed.Parse_error _
  | Masc_exec.Parsed.Parse_aborted _
  | Masc_exec.Parsed.Too_complex _ -> []
;;

let validate_command_paths ?keeper_id ?base_path ?workdir cmd =
  match workdir with
  | None -> Ok ()
  | Some _ ->
      let validate_path_value ~requires_existing_dir value =
        if String.equal (strip_wrapping_quotes value) "/dev/null"
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
      let validate_simple (simple : Masc_exec.Shell_ir.simple) =
        let command_name = Masc_exec.Bin.to_string simple.bin |> Filename.basename in
        match literal_args_of_simple simple with
        | None -> Ok ()
        | Some args ->
          (match
             path_argument_values command_name args
             |> validate_path_values ~command_name false
           with
           | Ok () -> validate_redirects simple.redirects
           | Error _ as err -> err)
      in
      let validate_parsed_shell_ir = function
        | Masc_exec.Shell_ir.Simple simple -> validate_simple simple
        | Masc_exec.Shell_ir.Pipeline stages ->
          let rec loop = function
            | [] -> Ok ()
            | Masc_exec.Shell_ir.Simple simple :: rest ->
              (match validate_simple simple with
               | Ok () -> loop rest
               | Error _ as err -> err)
            | Masc_exec.Shell_ir.Pipeline _ :: _ -> Ok ()
          in
          loop stages
      in
      (match Masc_exec_bash_parser.Bash.parse_string cmd with
       | Masc_exec.Parsed.Parsed shell_ir -> validate_parsed_shell_ir shell_ir
       | Masc_exec.Parsed.Parse_error _
       | Masc_exec.Parsed.Parse_aborted _
       | Masc_exec.Parsed.Too_complex _ -> Ok ())
;;

(** Check if a command performs write/mutating operations.
    Returns [true] for commands like [git push], [git commit],
    [make deploy], [npm publish], [mv], [cp], etc.
    Read-only commands (git status, rg) return [false]. *)
let is_write_operation = Mutation_classifier.is_write_operation
let is_git_branch_switch = Mutation_classifier.is_git_branch_switch
let is_destructive_bash_operation = Mutation_classifier.is_destructive_bash_operation

let sanitize_command_for_log = Log_sanitize.sanitize_command_for_log
let truncate_for_log = Log_sanitize.truncate_for_log

(* --- gh CLI validation (extracted to Gh_command_validation) --- *)

include Gh_command_validation

(* --- Recursive mkdir --- *)

let mkdir_p path _perm = Fs_compat.mkdir_p path

(* Closed sum: five producer-emitted error categories. The closed type
   replaces the previous [Tool_exec_error_kind of string] wrapper —
   string values are only re-introduced at the telemetry wire via
   [tool_exec_error_kind_to_string].  Adding a new variant is a compile
   obligation at every observer call site below. *)
type tool_exec_error_kind =
  | Path_blocked
  | File_read_error
  | File_write_error
  | Command_blocked
  | Shell_error

let tool_exec_error_kind_to_string = function
  | Path_blocked -> "path_blocked"
  | File_read_error -> "file_read_error"
  | File_write_error -> "file_write_error"
  | Command_blocked -> "command_blocked"
  | Shell_error -> "shell_error"
;;

type tool_exec_observer =
  tool_name:string
  -> success:bool
  -> duration_ms:int
  -> ?error_kind:tool_exec_error_kind
  -> ?error_message:string
  -> unit
  -> unit

(* --- Tool implementations --- *)

(** [file_read] byte cap. Reads longer than this are truncated to prevent
    context overflow. SSOT for the limit, its display label, and the
    tool description shown to agents. *)
let file_read_max_bytes = 100_000

let file_read_max_label = "100KB"

let file_read_description =
  Printf.sprintf
    "Read file contents by absolute path. Returns file text. Use shell_exec with 'ls' \
     instead if you need directory listing. Maximum %s per read to prevent context \
     overflow."
    file_read_max_label
;;

let make_file_read ?workdir ?on_exec () =
  Agent_sdk.Tool.create
    ~name:"file_read"
    ~description:file_read_description
    ~parameters:
      [ { name = "path"
        ; description = "Absolute file path to read"
        ; param_type = Agent_sdk.Types.String
        ; required = true
        }
      ]
    (fun input ->
       match Worker_tool_input.extract_string "path" input with
       | Error e -> tool_error e
       | Ok path ->
         let started = Time_compat.now () in
         let resolved_path = resolve_path ?base_dir:workdir path in
         if not (validate_path ?workdir path)
         then (
           let err =
             Keeper_path_check_error.(
               to_message
                 (Path_outside_whitelist
                    { path; for_keeper_command = false }))
           in
           let duration_ms = int_of_float ((Time_compat.now () -. started) *. 1000.0) in
           Option.iter
             (fun (f : tool_exec_observer) ->
                f
                  ~tool_name:"file_read"
                  ~success:false
                  ~duration_ms
                  ~error_kind:Path_blocked
                  ~error_message:err
                  ())
             on_exec;
           tool_error err)
         else (
           try
             let content = In_channel.with_open_text resolved_path In_channel.input_all in
             let duration_ms = int_of_float ((Time_compat.now () -. started) *. 1000.0) in
             Option.iter
               (fun (f : tool_exec_observer) ->
                  f ~tool_name:"file_read" ~success:true ~duration_ms ())
               on_exec;
             if String.length content > file_read_max_bytes
             then
               Ok
                 { Agent_sdk.Types.content =
                     String.sub content 0 file_read_max_bytes
                     ^ Printf.sprintf "\n[TRUNCATED at %s]" file_read_max_label
                 }
             else Ok { Agent_sdk.Types.content }
           with
           | Sys_error msg ->
             let duration_ms = int_of_float ((Time_compat.now () -. started) *. 1000.0) in
             Option.iter
               (fun (f : tool_exec_observer) ->
                  f
                    ~tool_name:"file_read"
                    ~success:false
                    ~duration_ms
                    ~error_kind:File_read_error
                    ~error_message:msg
                    ())
               on_exec;
             tool_error (Printf.sprintf "Cannot read: %s" msg)))
;;

let make_file_write ?workdir ?on_exec () =
  Agent_sdk.Tool.create
    ~name:"file_write"
    ~description:
      "Write content to a file by absolute path. Creates the file if it doesn't exist, \
       overwrites if it does. Creates parent directories. Use file_read first to check \
       existing content before overwriting."
    ~parameters:
      [ { name = "path"
        ; description = "Absolute file path to write"
        ; param_type = Agent_sdk.Types.String
        ; required = true
        }
      ; { name = "content"
        ; description = "Content to write to the file"
        ; param_type = Agent_sdk.Types.String
        ; required = true
        }
      ]
    (fun input ->
       match
         ( Worker_tool_input.extract_string "path" input
         , Worker_tool_input.extract_string "content" input )
       with
       | Error e, _ | _, Error e -> tool_error e
       | Ok path, Ok content ->
         let started = Time_compat.now () in
         let resolved_path = resolve_path ?base_dir:workdir path in
         if not (validate_path ?workdir path)
         then (
           let err =
             Keeper_path_check_error.(
               to_message
                 (Path_outside_whitelist
                    { path; for_keeper_command = false }))
           in
           let duration_ms = int_of_float ((Time_compat.now () -. started) *. 1000.0) in
           Option.iter
             (fun (f : tool_exec_observer) ->
                f
                  ~tool_name:"file_write"
                  ~success:false
                  ~duration_ms
                  ~error_kind:Path_blocked
                  ~error_message:err
                  ())
             on_exec;
           tool_error err)
         else (
           try
             mkdir_p (Filename.dirname resolved_path) 0o755;
             Out_channel.with_open_text resolved_path (fun oc ->
               Out_channel.output_string oc content);
             let duration_ms = int_of_float ((Time_compat.now () -. started) *. 1000.0) in
             Option.iter
               (fun (f : tool_exec_observer) ->
                  f ~tool_name:"file_write" ~success:true ~duration_ms ())
               on_exec;
             Ok
               { Agent_sdk.Types.content =
                   Printf.sprintf
                     "Written %d bytes to %s"
                     (String.length content)
                     resolved_path
               }
           with
           | Sys_error msg ->
             let duration_ms = int_of_float ((Time_compat.now () -. started) *. 1000.0) in
             Option.iter
               (fun (f : tool_exec_observer) ->
                  f
                    ~tool_name:"file_write"
                    ~success:false
                    ~duration_ms
                    ~error_kind:File_write_error
                    ~error_message:msg
                    ())
               on_exec;
             tool_error (Printf.sprintf "Cannot write: %s" msg)))
;;

(* --- Attribution envelope conversion (Layer 1) ---
   Shell command validation is a Det policy gate. The 8 block_reason
   variants map uniformly to Policy_failed (no transition involved —
   this is a pre-execution allow/deny check).

   Defined before [make_shell_exec_with_allowlist] so the tool's
   validation callsite can record the attribution without forward
   referencing. *)

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

let shell_ir_with_default_cwd cwd ir =
  match cwd with
  | None -> ir
  | Some dir ->
    let default_cwd = Masc_exec.Path_scope.classify ~raw:dir ~cwd:dir in
    let rec map_ir = function
      | Masc_exec.Shell_ir.Simple simple ->
        let simple =
          match simple.cwd with
          | Some _ -> simple
          | None -> { simple with cwd = Some default_cwd }
        in
        Masc_exec.Shell_ir.Simple simple
      | Masc_exec.Shell_ir.Pipeline stages ->
        Masc_exec.Shell_ir.Pipeline (List.map map_ir stages)
    in
    map_ir ir
;;

let output_for_dispatch_status ~(status : Unix.process_status) ~stdout ~stderr =
  match status with
  | Unix.WEXITED 0 -> stdout
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> (
    match stdout, stderr with
    | "", err -> err
    | out, "" -> out
    | out, err -> out ^ "\n" ^ err)
;;

let make_shell_exec_with_allowlist
      ~workdir
      ~on_exec
      ~proc_mgr:_
      ~clock
      ~allowed_commands
      ~description
      ()
  =
  Agent_sdk.Tool.create
    ~name:"shell_exec"
    ~description
    ~parameters:
      [ { name = "command"
        ; description = "Shell command to execute"
        ; param_type = Agent_sdk.Types.String
        ; required = true
        }
      ; { name = "timeout_s"
        ; description = "Timeout in seconds (default 30, max 120)"
        ; param_type = Agent_sdk.Types.Number
        ; required = false
        }
      ]
    (fun input ->
       match Worker_tool_input.extract_string "command" input with
       | Error e -> tool_error e
       | Ok command ->
         let command_context =
           command_context_with_allowlist ~allowed_commands command
         in
         let validation = Result.map (fun _ -> ()) command_context in
         Dashboard_attribution.record (attribution_of_validation ~cmd:command validation);
         (match command_context with
          | Error reason ->
            (* #13078: emit [command_blocked] telemetry so observers
               see validation failures.  Without this, the .mli's
               documented [command_blocked] error_kind never appears
               on the wire — operators can't distinguish "policy
               denied" from "no shell_exec attempt".  duration_ms = 0
               because no subprocess was spawned. *)
            Option.iter
              (fun (f : tool_exec_observer) ->
                 f
                   ~tool_name:"shell_exec"
                   ~success:false
                   ~duration_ms:0
                   ~error_kind:Command_blocked
                   ~error_message:(block_reason_to_string reason)
                   ())
              on_exec;
            tool_error (block_reason_to_string reason)
          | Ok context ->
            let path_workdir =
              match workdir with
              | Some dir when String.trim dir <> "" -> dir
              | Some _ | None -> Sys.getcwd ()
            in
            (match validate_command_paths ~workdir:path_workdir command with
             | Error message ->
               Option.iter
                 (fun (f : tool_exec_observer) ->
                    f
                      ~tool_name:"shell_exec"
                      ~success:false
                      ~duration_ms:0
                      ~error_kind:Path_blocked
                      ~error_message:message
                      ())
                 on_exec;
               tool_error message
             | Ok () ->
               let timeout =
                 Worker_tool_input.extract_float "timeout_s" input
                 |> Option.value ~default:30.0
                    (* DET-OK: fixed policy default for absent shell timeout. *)
                 |> Float.min 120.0
               in
               (try
                  let started = Time_compat.now () in
                  let record_result ?error_message result =
                    let duration_ms =
                      int_of_float ((Time_compat.now () -. started) *. 1000.0)
                    in
                    Option.iter
                      (fun (f : tool_exec_observer) ->
                         let success = Result.is_ok result in
                         if success
                         then f ~tool_name:"shell_exec" ~success:true ~duration_ms ()
                         else
                           f
                             ~tool_name:"shell_exec"
                             ~success:false
                             ~duration_ms
                             ~error_kind:Shell_error
                             ?error_message
                             ())
                      on_exec;
                    result
                  in
                  Tool_resource_gate.with_permit_raw
                    ~clock
                    ~tool_name:"shell_exec"
                    ~arguments:input
                    ~is_read_only:false
                    ~on_reject:(fun message ->
                      let message = "tool_resource_gate_saturated: " ^ message in
                      record_result
                        ~error_message:message
                        (tool_error ~recoverable:true message))
                    (fun () ->
                       let cwd =
                         match workdir with
                         | Some dir when String.trim dir <> "" -> Some dir
                         | Some _ | None -> None
                       in
                       let result =
                         try
                           let dispatch_result =
                             Fd_accountant.with_slot ~kind:Sandbox_exec (fun () ->
                               let dispatch_ir =
                                 shell_ir_with_default_cwd
                                   cwd
                                   context.Exec_shell_gate.ast
                               in
                               Masc_exec.Exec_dispatch.dispatch
                                 ~timeout_sec:timeout
                                 dispatch_ir)
                           in
                           let output =
                             output_for_dispatch_status
                               ~status:dispatch_result.status
                               ~stdout:dispatch_result.stdout
                               ~stderr:dispatch_result.stderr
                           in
                           match dispatch_result.status with
                           | Unix.WEXITED 0 -> Ok { Agent_sdk.Types.content = output }
                           | Unix.WEXITED 124 ->
                             tool_error
                               ~recoverable:true
                               (Printf.sprintf
                                  "Timeout after %.0fs: %s\n%s"
                                  timeout
                                  command
                                  output)
                           | Unix.WEXITED code ->
                             tool_error (Printf.sprintf "Exit code %d:\n%s" code output)
                           | Unix.WSIGNALED sig_num ->
                             tool_error
                               ~recoverable:(sig_num = Sys.sigterm)
                               (Printf.sprintf
                                  "Killed by signal %d:\n%s"
                                  sig_num
                                  output)
                           | Unix.WSTOPPED sig_num ->
                             tool_error
                               ~recoverable:true
                               (Printf.sprintf
                                  "Stopped by signal %d:\n%s"
                                  sig_num
                                  output)
                         with
                         | Eio.Time.Timeout ->
                           tool_error
                             ~recoverable:true
                             (Printf.sprintf "Timeout after %.0fs: %s\n%s" timeout command "")
                       in
                       record_result result)
                with
                | Eio.Cancel.Cancelled _ as e -> raise e
                | exn ->
                  let duration_ms = 0 in
                  let exn_msg = Printexc.to_string exn in
                  Option.iter
                    (fun (f : tool_exec_observer) ->
                       f
                         ~tool_name:"shell_exec"
                         ~success:false
                         ~duration_ms
                         ~error_kind:Shell_error
                         ~error_message:exn_msg
                         ())
                    on_exec;
                  tool_error (Printf.sprintf "Command failed: %s" exn_msg)))))
;;

let make_shell_exec ~workdir ~on_exec ~proc_mgr ~clock =
  make_shell_exec_with_allowlist
    ~workdir
    ~on_exec
    ~proc_mgr
    ~clock
    ~allowed_commands:dev_allowed_commands
    ~description:
      "Execute a shell command and return stdout+stderr. Timeout: 30s default, max 120s. \
       Use for: running tests, git commands, build tools, directory listing. Unlike \
       file_read (single file), this handles approved CLI operations. Supported commands \
       run through Shell IR native dispatch; shell control syntax is rejected."
    ()
;;

let make_shell_exec_readonly ~workdir ~on_exec ~proc_mgr ~clock =
  make_shell_exec_with_allowlist
    ~workdir
    ~on_exec
    ~proc_mgr
    ~clock
    ~allowed_commands:readonly_allowed_commands
    ~description:
      "Execute a read-only shell command and return stdout+stderr. Timeout: 30s default, \
       max 120s. Use for search, inspection, and verification only. Write-oriented \
       commands are intentionally excluded."
    ()
;;

(** Create dev tools that close over Eio capabilities.
    Returns [file_read; file_write; shell_exec]. *)
let make_tools ~proc_mgr ~clock ?workdir ?on_exec () : Agent_sdk.Tool.t list =
  [ make_file_read ?workdir ?on_exec ()
  ; make_file_write ?workdir ?on_exec ()
  ; make_shell_exec ~workdir ~on_exec ~proc_mgr ~clock
  ]
;;

let make_readonly_tools ~proc_mgr ~clock ?workdir ?on_exec () : Agent_sdk.Tool.t list =
  [ make_file_read ?workdir ?on_exec ()
  ; make_shell_exec_readonly ~workdir ~on_exec ~proc_mgr ~clock
  ]
;;
