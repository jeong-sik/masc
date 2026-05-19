open Keeper_shell_bash_task_state

type bash_shape_block =
  | Gh_pr_checks
  | Pipe_or_redirect
  | Chaining
  | Substitution
  | Repo_wide_scan

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
    "keeper_bash accepts one direct command. Pipes and redirects such as |, \
     2>&1, 2&1, >/dev/null, <, and | head are blocked before execution."
  | Chaining ->
    "keeper_bash accepts one command per call. Chaining with &&, ||, ;, or \
     newlines is blocked before execution."
  | Substitution ->
    "Command substitution is blocked before execution. Compute values in a \
     separate tool call and pass literal arguments."
  | Repo_wide_scan ->
    "Repo-wide recursive scans are blocked in raw keeper_bash. Under long \
     running Keeper fleets they can stampede Docker bind mounts and exhaust \
     host file descriptors."

let bash_shape_block_hint ~cmd = function
  | _ when command_looks_like_task_state_discovery cmd -> task_state_shell_hint
  | Gh_pr_checks ->
    "Use keeper_pr_status. If raw gh is the only visible status path, use gh \
     pr view NUMBER --repo OWNER/REPO --json \
     statusCheckRollup,mergeStateStatus,isDraft."
  | Pipe_or_redirect when command_looks_like_search_pipeline cmd ->
    "Do not pipe grep/rg through keeper_bash. Use keeper_shell op=rg with a \
     scoped path and pattern instead; if the command starts with cd, pass that \
     directory as cwd instead of using cd &&."
  | Pipe_or_redirect when
      command_looks_like_find_pipeline cmd || lowercase_contains cmd "find " ->
    "Do not pipe find through keeper_bash. Use keeper_shell op=find with path, \
     pattern, and limit instead of | head; if the command needs multiple -name \
     globs, run one keeper_shell op=find call per pattern."
  | Pipe_or_redirect ->
    "Remove the pipe or redirect. Run the primary command once and summarize \
     the returned output; use keeper_shell op=head/tail for file slices."
  | Chaining when command_looks_like_cd_chained_search cmd ->
    "Do not prepend cd ... && to search commands. Pass the target repo or \
     worktree as cwd and use keeper_shell op=rg with a scoped path."
  | Chaining ->
    "Split the work into separate keeper_bash calls and use the cwd argument \
     instead of cd chaining."
  | Substitution ->
    "Run the discovery command first, then use its literal result in a second \
     keeper_bash call."
  | Repo_wide_scan ->
    if command_looks_like_repo_wide_git_log_grep cmd then
      "Do not use raw Bash for repo-wide git history grep. Use keeper_shell \
       op=git_log with cwd set to the repo/worktree, count=5, and grep=<term>."
    else if command_looks_like_repo_wide_rg cmd then
      "Do not scan repos/ from raw keeper_bash. Use keeper_shell op=rg with a \
       scoped path such as repos/masc-mcp/lib or repos/oas/src, plus type/glob \
       filters."
    else
      "Use keeper_shell op=rg/find with a scoped path such as lib/, test/, or a \
       specific repos/REPO subdirectory; avoid scanning . or repos/ from raw \
       bash."

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
        "keeper_shell op=rg pattern=search-term path=lib glob=*.ml";
        "keeper_shell op=rg pattern=search-term path=repos/REPO/lib glob=*.ml";
        "keeper_bash cmd='git status' cwd='repos/REPO'";
      ]
    else if command_looks_like_find_pipeline cmd || lowercase_contains cmd "find "
    then
      [
        "keeper_shell op=find path=repos/REPO/.worktrees/TASK pattern='*.ml' limit=30";
        "keeper_shell op=find path=repos/REPO/.worktrees/TASK pattern='*.mli' limit=30";
        "keeper_shell op=find path=lib pattern='*.ml' limit=30";
      ]
    else
      [
        "keeper_bash cmd='ls lib/'";
        "keeper_shell op=head path=file/path lines=20";
        "keeper_shell op=rg pattern=search-term path=dir/path";
      ]
  | Chaining ->
    if command_looks_like_cd_chained_search cmd
    then
      [
        "keeper_shell op=rg pattern=search-term path=lib glob=*.ml";
        "keeper_bash cmd='git status' cwd='repos/REPO'";
      ]
    else
      [
        "keeper_bash cmd='git status' cwd='repos/REPO'";
        "keeper_bash cmd='git log -1' cwd='repos/REPO'";
      ]
  | Substitution ->
    [
      "keeper_bash cmd='rg --files lib'";
      "keeper_bash cmd='cat path/from/previous-step'";
    ]
  | Repo_wide_scan ->
    if command_looks_like_repo_wide_git_log_grep cmd
    then
      [
        "keeper_shell op=git_log cwd=repos/REPO count=5 grep=search-term";
        "keeper_shell op=git_log cwd=repos/REPO/.worktrees/TASK count=5 grep=search-term";
      ]
    else if command_looks_like_repo_wide_rg cmd
    then
      [
        "keeper_shell op=rg pattern=search-term path=repos/masc-mcp/lib glob=*.ml";
        "keeper_shell op=rg pattern=search-term path=repos/oas/src glob=*.ml";
        "keeper_shell op=find path=repos/REPO/lib pattern='*.ml'";
      ]
    else
      [
        "keeper_shell op=rg pattern=search-term path=lib";
        "keeper_shell op=find path=lib pattern='*.ml'";
        "keeper_bash cmd='git log --oneline -20'";
      ]
