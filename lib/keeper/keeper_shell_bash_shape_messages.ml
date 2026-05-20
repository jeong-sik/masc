open Keeper_shell_bash_task_state

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
    Some
      (plan
         ~confidence:"high"
         ~next_tool:"Grep"
         ~next_args:
           [ "pattern", `String "SEARCH_TERM"
           ; "path", `String "SCOPED_PATH"
           ; "glob", `String "*.ml"
           ]
         ~instruction:(bash_shape_block_hint ~cmd Pipe_or_redirect)
         ~reason:"pipe_to_head_rewrite"
         ())
  | Pipe_or_redirect when
      command_looks_like_find_pipeline cmd || lowercase_contains cmd "find " ->
    Some
      (plan
         ~confidence:"high"
         ~next_tool:"Bash"
         ~next_args:
           [ "command", `String "find . -name FILE_GLOB"
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
    Some
      (plan
         ~confidence:"high"
         ~next_tool:"Grep"
         ~next_args:
           [ "pattern", `String "SEARCH_TERM"
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
      Some
        (plan
           ~confidence:"high"
           ~next_tool:"Bash"
           ~next_args:
             [ "command", `String "git log --oneline -5 --grep=SEARCH_TERM"
             ; "cwd", `String "REPO_OR_WORKTREE_CWD"
             ]
           ~instruction:(bash_shape_block_hint ~cmd Repo_wide_scan)
           ~reason:"repo_wide_git_history_scan_blocked"
           ())
    else
      Some
        (plan
           ~confidence:"high"
           ~next_tool:"Grep"
           ~next_args:
             [ "pattern", `String "SEARCH_TERM"
             ; "path", `String "SCOPED_PATH"
             ; "glob", `String "*.ml"
             ]
           ~instruction:(bash_shape_block_hint ~cmd Repo_wide_scan)
           ~reason:"repo_wide_scan_blocked"
           ())
