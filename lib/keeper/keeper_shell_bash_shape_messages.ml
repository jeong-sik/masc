open Keeper_shell_bash_task_state
open Keeper_shell_bash_words

type bash_shape_block =
  | Gh_pr_checks
  | Pipe_or_redirect
  | Chaining
  | Substitution
  | Repo_wide_scan

type recovery_plan = {
  next_tool : string;
  next_args : (string * Yojson.Safe.t) list;
  instruction : string;
  reason : string;
  confidence : string;
}

let bash_shape_block_tag = function
  | Gh_pr_checks -> "gh_pr_checks"
  | Pipe_or_redirect -> "pipe_or_redirect"
  | Chaining -> "chaining"
  | Substitution -> "substitution"
  | Repo_wide_scan -> "repo_wide_scan"

let bash_shape_block_reason = function
  | Gh_pr_checks ->
    "gh pr checks exits non-zero when checks are red. That is useful status \
     data, but it trips keeper shell failure and circuit-breaker accounting."
  | Pipe_or_redirect ->
    "Bash accepts one direct command. Pipes and redirects such as |, 2>&1, \
     2&1, >/dev/null, <, and | head are blocked before execution."
  | Chaining ->
    "Bash accepts one command per call. Chaining with &&, ||, ;, or \
     newlines is blocked before execution."
  | Substitution ->
    "Command substitution is blocked before execution. Compute values in a \
     separate tool call and pass literal arguments."
  | Repo_wide_scan ->
    "Repo-wide recursive scans are blocked in raw Bash. Under long-running \
     Keeper fleets they can stampede Docker bind mounts and exhaust host file \
     descriptors."

let bash_shape_block_hint ~cmd = function
  | _ when command_looks_like_task_state_discovery cmd -> task_state_shell_hint
  | Gh_pr_checks ->
    "Use keeper_pr_status. If raw gh is the only visible status path, use gh \
     pr view NUMBER --repo OWNER/REPO --json \
     statusCheckRollup,mergeStateStatus,isDraft."
  | Pipe_or_redirect when command_looks_like_search_pipeline cmd ->
    "Do not pipe grep/rg through Bash. Use Grep with a scoped path and \
     pattern instead; if the command starts with cd, put that directory in the \
     Grep path or use Bash cwd for a single command."
  | Pipe_or_redirect when
      command_looks_like_find_pipeline cmd || lowercase_contains cmd "find " ->
    "Do not pipe find through Bash. Remove | head and run one scoped Bash find \
     command with cwd set when needed; if the command needs multiple -name \
     globs, run one Bash call per pattern."
  | Pipe_or_redirect ->
    "Remove the pipe or redirect. Run the primary command once and summarize \
     the returned output; use Read for file slices."
  | Chaining when command_looks_like_cd_chained_search cmd ->
    "Do not prepend cd ... && to search commands. Pass the target repo or \
     worktree in the Grep path, or use Bash cwd with a single command."
  | Chaining ->
    "Split the work into separate Bash calls and use the cwd argument instead \
     of cd chaining."
  | Substitution ->
    "Run the discovery command first, then use its literal result in a second \
     Bash call."
  | Repo_wide_scan ->
    if command_looks_like_repo_wide_git_log_grep cmd then
      "Do not use raw Bash for repo-wide git history grep. Use Bash command=\"git \
       log --oneline -5 --grep=<term>\" with cwd set to the repo/worktree."
    else if command_looks_like_repo_wide_rg cmd then
      "Do not scan repos/ from raw Bash. Use Grep with a scoped path such as \
       repos/masc-mcp/lib or repos/oas/src, plus type/glob filters."
    else
      "Use Grep, or one scoped Bash find command, with a path such as lib/, \
       test/, or a specific repos/REPO subdirectory; avoid scanning . or repos/ \
       from raw Bash."

let bash_shape_block_alternatives ~cmd = function
  | _ when command_looks_like_task_state_discovery cmd -> task_state_shell_alternatives
  | Gh_pr_checks ->
    [
      "keeper_pr_status";
      "gh pr view NUMBER --repo OWNER/REPO --json \
       statusCheckRollup,mergeStateStatus,isDraft";
    ]
  | Pipe_or_redirect ->
    if command_looks_like_search_pipeline cmd
    then
      [
        "Grep pattern=search-term path=lib glob=*.ml";
        "Grep pattern=search-term path=repos/REPO/lib glob=*.ml";
        "Bash command='git status --short' cwd='repos/REPO'";
      ]
    else if command_looks_like_find_pipeline cmd || lowercase_contains cmd "find "
    then
      [
        "Bash command='find . -name \"*.ml\"' cwd='repos/REPO/.worktrees/TASK'";
        "Bash command='find . -name \"*.mli\"' cwd='repos/REPO/.worktrees/TASK'";
        "Bash command='find lib -name \"*.ml\"' cwd='repos/REPO'";
      ]
    else
      [
        "Bash command='ls lib/' cwd='repos/REPO'";
        "Read file_path=file/path";
        "Grep pattern=search-term path=dir/path";
      ]
  | Chaining ->
    if command_looks_like_cd_chained_search cmd
    then
      [
        "Grep pattern=search-term path=repos/REPO/lib glob=*.ml";
        "Bash command='git status --short' cwd='repos/REPO'";
      ]
    else
      [
        "Bash command='git status --short' cwd='repos/REPO'";
        "Bash command='git log -1' cwd='repos/REPO'";
      ]
  | Substitution ->
    [
      "Bash command='rg --files lib' cwd='repos/REPO'";
      "Read file_path=path/from/previous-step";
    ]
  | Repo_wide_scan ->
    if command_looks_like_repo_wide_git_log_grep cmd
    then
      [
        "Bash command='git log --oneline -5 --grep=search-term' cwd='repos/REPO'";
        "Bash command='git log --oneline -5 --grep=search-term' cwd='repos/REPO/.worktrees/TASK'";
      ]
    else if command_looks_like_repo_wide_rg cmd
    then
      [
        "Grep pattern=search-term path=repos/masc-mcp/lib glob=*.ml";
        "Grep pattern=search-term path=repos/oas/src glob=*.ml";
        "Bash command='find lib -name \"*.ml\"' cwd='repos/REPO'";
      ]
    else
      [
        "Grep pattern=search-term path=lib";
        "Bash command='find lib -name \"*.ml\"' cwd='repos/REPO'";
        "Bash command='git log --oneline -20' cwd='repos/REPO'";
      ]

let recovery_plan_to_json plan =
  `Assoc
    [ "kind", `String "structured_tool_rewrite"
    ; "next_tool", `String plan.next_tool
    ; "next_args", `Assoc plan.next_args
    ; "instruction", `String plan.instruction
    ; "reason", `String plan.reason
    ; "confidence", `String plan.confidence
    ; "do_not_retry_same_args", `Bool true
    ]

let plan ?(confidence = "medium") ~next_tool ~next_args ~instruction ~reason () =
  { next_tool; next_args; instruction; reason; confidence }

type simple_command = {
  bin_name : string;
  args : string list;
}

let arg_literal = function
  | Masc_exec.Shell_ir.Lit text -> Some text
  | Masc_exec.Shell_ir.Concat _ | Masc_exec.Shell_ir.Var _ -> None

let simple_command_of_shell_simple (simple : Masc_exec.Shell_ir.simple) =
  let rec loop acc = function
    | [] -> Some { bin_name = Masc_exec.Bin.to_string simple.bin; args = List.rev acc }
    | arg :: rest ->
      (match arg_literal arg with
       | None -> None
       | Some text -> loop (text :: acc) rest)
  in
  loop [] simple.args

let parsed_simple_commands cmd =
  let rec collect acc = function
    | Masc_exec.Shell_ir.Simple simple ->
      (match simple_command_of_shell_simple simple with
       | Some command -> command :: acc
       | None -> acc)
    | Masc_exec.Shell_ir.Pipeline stages -> List.fold_left collect acc stages
  in
  match Masc_exec_bash_parser.Bash.parse_string cmd with
  | Masc_exec.Parsed.Parsed ir -> List.rev (collect [] ir)
  | Masc_exec.Parsed.Parse_error _
  | Masc_exec.Parsed.Parse_aborted _
  | Masc_exec.Parsed.Too_complex _ -> []

let shell_word_simple_commands cmd =
  let rec from_cmd cmd =
    let words = shell_words_with_boundaries cmd in
    let rec take_args = function
      | [] -> []
      | word :: _ when word.starts_command -> []
      | word :: rest -> word.text :: take_args rest
    in
    let rec loop acc = function
      | word :: rest when word.starts_command ->
        let command_words = strip_command_wrappers (word :: rest) in
        let acc =
          match command_words with
          | bin :: args ->
            { bin_name = command_name bin.text; args = take_args args } :: acc
          | [] -> acc
        in
        loop acc rest
      | _ :: rest -> loop acc rest
      | [] -> List.rev acc
    in
    let commands = loop [] words in
    match shell_c_payload words with
    | Some payload -> commands @ from_cmd payload
    | None -> commands
  in
  from_cmd cmd

let find_simple_command cmd predicate =
  match List.find_opt predicate (parsed_simple_commands cmd) with
  | Some command -> Some command
  | None -> List.find_opt predicate (shell_word_simple_commands cmd)

let option_consumes_value text =
  Keeper_shell_bash_repo_wide_scan.option_consumes_next_arg text

let positional_args args =
  let rec loop acc = function
    | [] -> List.rev acc
    | arg :: _value :: rest when option_consumes_value arg -> loop acc rest
    | arg :: rest when String.starts_with ~prefix:"--" arg -> loop acc rest
    | arg :: rest when String.length arg > 1 && Char.equal arg.[0] '-' ->
      loop acc rest
    | arg :: rest -> loop (arg :: acc) rest
  in
  loop [] args

let option_value ~name args =
  let prefix = name ^ "=" in
  let rec loop = function
    | [] -> None
    | arg :: rest when String.equal arg name ->
      (match rest with
       | value :: _ -> Some value
       | [] -> None)
    | arg :: _ when String.starts_with ~prefix arg ->
      Some (String.sub arg (String.length prefix) (String.length arg - String.length prefix))
    | _ :: rest -> loop rest
  in
  loop args

let first_positional_or_placeholder ~placeholder args =
  match positional_args args with
  | value :: _ when String.trim value <> "" -> value
  | [] | _ -> placeholder

let repo_wide_rg_pattern cmd =
  let is_rg command =
    String.equal (command_name command.bin_name) "rg"
  in
  match find_simple_command cmd is_rg with
  | Some { args; _ } -> Some (first_positional_or_placeholder ~placeholder:"SEARCH_TERM" args)
  | None -> None

let repo_wide_grep_pattern cmd =
  let is_grep command =
    match command_name command.bin_name with
    | "grep" | "egrep" | "fgrep" -> true
    | _ -> false
  in
  match find_simple_command cmd is_grep with
  | Some { args; _ } -> Some (first_positional_or_placeholder ~placeholder:"SEARCH_TERM" args)
  | None -> None

let repo_wide_find_pattern cmd =
  let is_find command = String.equal (command_name command.bin_name) "find" in
  let rec find_name_arg = function
    | [] -> None
    | ("-name" | "-iname" | "-path") :: value :: _ -> Some value
    | _ :: rest -> find_name_arg rest
  in
  match find_simple_command cmd is_find with
  | Some { args; _ } ->
    Some (Option.value (find_name_arg args) ~default:"FILE_GLOB")
  | None -> None

let repo_wide_git_log_grep cmd =
  let is_git_log command =
    match command_name command.bin_name, command.args with
    | "git", subcmd :: _ -> String.equal subcmd "log"
    | _ -> false
  in
  match find_simple_command cmd is_git_log with
  | Some { args; _ } -> option_value ~name:"--grep" args
  | None -> None

let rg_scoped_path_placeholder cmd =
  if lowercase_contains cmd " repos"
  then "repos/REPO/SCOPED_PATH"
  else "SCOPED_PATH"

let shell_single_quote text =
  let escaped =
    text
    |> String.split_on_char '\''
    |> String.concat "'\\''"
  in
  "'" ^ escaped ^ "'"

let bash_find_command pattern =
  "find . -name " ^ shell_single_quote pattern

let bash_git_log_grep_command grep =
  "git log --oneline -5 --grep=" ^ shell_single_quote grep

let bash_shape_block_recovery_plan ~cmd = function
  | _ when command_looks_like_task_state_discovery cmd ->
    Some
      (plan
         ~confidence:"high"
         ~next_tool:"keeper_tasks_list"
         ~next_args:[ "include_done", `Bool false ]
         ~instruction:task_state_shell_hint
         ~reason:"task_state_tool_ssot"
         ())
  | Gh_pr_checks ->
    Some
      (plan
         ~next_tool:"keeper_pr_status"
         ~next_args:
           [ "pr", `String "NUMBER_FROM_COMMAND"
           ; "repo", `String "OWNER/REPO_FROM_COMMAND"
           ]
         ~instruction:(bash_shape_block_hint ~cmd Gh_pr_checks)
         ~reason:"native_pr_status_tool_required"
         ())
  | Pipe_or_redirect when command_looks_like_search_pipeline cmd ->
    let pattern =
      repo_wide_rg_pattern cmd
      |> Option.value
           ~default:
             (Option.value (repo_wide_grep_pattern cmd) ~default:"SEARCH_TERM")
    in
    Some
      (plan
         ~confidence:"high"
         ~next_tool:"Grep"
         ~next_args:
           [ "pattern", `String pattern
           ; "path", `String "SCOPED_PATH"
           ; "glob", `String "*.ml"
           ]
         ~instruction:(bash_shape_block_hint ~cmd Pipe_or_redirect)
         ~reason:"pipe_to_head_rewrite"
         ())
  | Pipe_or_redirect when
      command_looks_like_find_pipeline cmd || lowercase_contains cmd "find " ->
    let pattern = Option.value (repo_wide_find_pattern cmd) ~default:"FILE_GLOB" in
    Some
      (plan
         ~confidence:"high"
         ~next_tool:"Bash"
         ~next_args:
           [ "command", `String (bash_find_command pattern)
           ; "cwd", `String "SCOPED_REPO_OR_WORKTREE_CWD"
           ]
         ~instruction:(bash_shape_block_hint ~cmd Pipe_or_redirect)
         ~reason:"find_head_rewrite"
         ())
  | Pipe_or_redirect ->
    Some
      (plan
         ~next_tool:"Bash"
         ~next_args:
           [ "command", `String "PRIMARY_COMMAND_WITHOUT_PIPE_OR_REDIRECT"
           ; "cwd", `String "REPO_OR_WORKTREE_CWD"
           ]
         ~instruction:(bash_shape_block_hint ~cmd Pipe_or_redirect)
         ~reason:"pipe_or_redirect_blocked"
         ())
  | Chaining when command_looks_like_cd_chained_search cmd ->
    let pattern =
      repo_wide_rg_pattern cmd
      |> Option.value
           ~default:
             (Option.value (repo_wide_grep_pattern cmd) ~default:"SEARCH_TERM")
    in
    Some
      (plan
         ~confidence:"high"
         ~next_tool:"Grep"
         ~next_args:
           [ "pattern", `String pattern
           ; "path", `String "REPO_OR_WORKTREE_CWD/SCOPED_PATH"
           ; "glob", `String "*.ml"
           ]
         ~instruction:(bash_shape_block_hint ~cmd Chaining)
         ~reason:"cd_chained_search_rewrite"
         ())
  | Chaining ->
    Some
      (plan
         ~next_tool:"Bash"
         ~next_args:
           [ "command", `String "SINGLE_COMMAND"
           ; "cwd", `String "REPO_OR_WORKTREE_CWD"
           ]
         ~instruction:(bash_shape_block_hint ~cmd Chaining)
         ~reason:"command_chaining_blocked"
         ())
  | Substitution ->
    Some
      (plan
         ~next_tool:"Bash"
         ~next_args:
           [ "command", `String "DISCOVERY_COMMAND_WITHOUT_SUBSTITUTION"
           ; "cwd", `String "REPO_OR_WORKTREE_CWD"
           ]
         ~instruction:(bash_shape_block_hint ~cmd Substitution)
         ~reason:"substitution_requires_discovery_first"
         ())
  | Repo_wide_scan ->
    if command_looks_like_repo_wide_git_log_grep cmd then
      let grep = Option.value (repo_wide_git_log_grep cmd) ~default:"SEARCH_TERM" in
      Some
        (plan
           ~confidence:"high"
           ~next_tool:"Bash"
           ~next_args:
             [ "command", `String (bash_git_log_grep_command grep)
             ; "cwd", `String "REPO_OR_WORKTREE_CWD"
             ]
           ~instruction:(bash_shape_block_hint ~cmd Repo_wide_scan)
           ~reason:"repo_wide_git_history_scan_blocked"
           ())
    else if lowercase_contains cmd "find " then
      let pattern = Option.value (repo_wide_find_pattern cmd) ~default:"FILE_GLOB" in
      Some
        (plan
           ~confidence:"high"
           ~next_tool:"Bash"
           ~next_args:
             [ "command", `String (bash_find_command pattern)
             ; "cwd", `String "REPO_OR_WORKTREE_CWD"
             ]
           ~instruction:(bash_shape_block_hint ~cmd Repo_wide_scan)
           ~reason:"repo_wide_find_scan_blocked"
           ())
    else
      let pattern =
        repo_wide_rg_pattern cmd
        |> Option.value
             ~default:
               (Option.value (repo_wide_grep_pattern cmd) ~default:"SEARCH_TERM")
      in
      Some
        (plan
           ~confidence:"high"
           ~next_tool:"Grep"
           ~next_args:
             [ "pattern", `String pattern
             ; "path", `String (rg_scoped_path_placeholder cmd)
             ; "glob", `String "*.ml"
             ]
           ~instruction:(bash_shape_block_hint ~cmd Repo_wide_scan)
           ~reason:"repo_wide_scan_blocked"
           ())
