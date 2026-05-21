(** P0-X: Typed redirect predicates for keeper repo-wide discovery shells.

    Same playbook as [Keeper_shell_bash_task_state] (which took
    [task_state_file_probe] from 388/day to 0): identify the small set of
    [keeper_tool_policy_blocked] signatures that should be redirected to a
    typed MCP tool, and expose [string -> bool] predicates plus typed hint
    text and structured alternatives.

    Three signatures covered (3,117/24h regressions):

    1. Worktree discovery via [find repos -maxdepth 4 -type d -name .worktrees]
       -> redirect to [masc_worktree_list].

    2. Cross-repo content scan via [rg -l "current_task" repos/] (or
       equivalent [grep]).
       -> redirect to [Grep] with a scoped [path=repos/REPO/...].

    3. Cross-host probe via [find /home/.../ -type d -name "*task*"] or
       [find /Users/.../ ...].
       -> redirect to [keeper_context_status] (the keeper-scoped sandbox
       path source of truth).

    Boundaries:
    - Input: raw shell command text.
    - Output: [bool] predicates + static typed strings; no side effects.
    - Callers (after wiring): [Keeper_shell_bash_shape_messages] for #1/#2
      and [Keeper_shell_bash] sandbox boundary for #3. *)

open Keeper_shell_bash_task_state
(* [lowercase_contains] lives in the task_state module and is already
   exported via its [.mli]; reuse rather than duplicate. *)

(** [command_looks_like_worktree_discovery cmd] returns [true] for shells
    of the form [find repos ... -name .worktrees] (or [.worktrees/...]). *)
let command_looks_like_worktree_discovery cmd =
  let mentions_find_repos =
    lowercase_contains cmd "find repos" || lowercase_contains cmd "find ./repos"
  in
  let mentions_worktrees_token =
    lowercase_contains cmd ".worktrees" || lowercase_contains cmd " worktrees"
  in
  mentions_find_repos && mentions_worktrees_token

(** [command_looks_like_cross_repo_grep cmd] returns [true] for shells
    that fan out [rg]/[grep] across the entire [repos/] subtree, e.g.
    [rg -l "current_task" repos/] or [grep -r foo repos/]. *)
let command_looks_like_cross_repo_grep cmd =
  let mentions_search_tool =
    lowercase_contains cmd "rg " || lowercase_contains cmd "grep "
  in
  let mentions_repos_root_path =
    (* Match [repos/] or [./repos/] or [ repos ] (trailing-space form
       used by [rg -l PATTERN repos/]). The check excludes anchored
       [repos/REPO/] paths by requiring [repos] near a word boundary,
       not [repos/<id>/<lib>/<...>] which is already scoped. *)
    lowercase_contains cmd " repos/" || lowercase_contains cmd " ./repos/"
  in
  mentions_search_tool && mentions_repos_root_path

(** [command_looks_like_cross_host_probe cmd] returns [true] for shells
    that walk absolute host paths outside the keeper sandbox, e.g.
    [find /home/... -type d -name "*task*"] or
    [find /Users/... -type d -name "*current*"]. *)
let command_looks_like_cross_host_probe cmd =
  let mentions_find =
    lowercase_contains cmd "find /home" || lowercase_contains cmd "find /Users"
  in
  let mentions_directory_walk =
    lowercase_contains cmd "-type d"
    || lowercase_contains cmd "-name"
    || lowercase_contains cmd "-maxdepth"
  in
  mentions_find && mentions_directory_walk

(** Aggregate predicate: any of the three cross-repo discovery signatures. *)
let command_looks_like_repo_wide_discovery cmd =
  command_looks_like_worktree_discovery cmd
  || command_looks_like_cross_repo_grep cmd
  || command_looks_like_cross_host_probe cmd

(** Typed hint shown to the keeper when one of the three signatures
    matches. Mirrors the shape of [task_state_shell_hint] from the
    precedent. *)
let repo_wide_discovery_shell_hint =
  "Do not enumerate keeper worktrees, scan the entire repos/ subtree, or \
   probe absolute host paths (/home, /Users) from raw Bash. Each of these \
   has a typed MCP tool: masc_worktree_list for worktree inventory, scoped \
   Grep with path=repos/REPO/SCOPED_PATH for cross-repo content search, \
   and keeper_context_status for current_task and sandbox-path lookup."

(** Tag for a matched discovery sub-pattern. Used by the dispatcher in
    [Keeper_shell_bash_shape_messages] / [Keeper_shell_bash] to pick the
    right structured recovery plan. *)
type discovery_sub_pattern =
  | Worktree_discovery
  | Cross_repo_grep
  | Cross_host_probe

(** Pattern -> (recommended tool name, args JSON skeleton) mapping.
    The args are deliberately string-literal placeholders so that the
    rewrite plan can be rendered by the existing
    [Keeper_shell_bash_shape_messages.plan] / [recovery_plan_to_json]
    machinery without re-implementing JSON construction here. *)
let repo_wide_discovery_alternatives :
      (discovery_sub_pattern * string * (string * string) list) list =
  [ Worktree_discovery,
    "masc_worktree_list",
    [ "include_remote", "false" ]
  ; Cross_repo_grep,
    "Grep",
    [ "pattern", "SEARCH_TERM"
    ; "path", "repos/REPO/SCOPED_PATH"
    ; "glob", "*.ml"
    ]
  ; Cross_host_probe,
    "keeper_context_status",
    []
  ]

(** Tag for the matched sub-pattern of [cmd], if any. Returns the first
    match in the order [Worktree_discovery -> Cross_repo_grep ->
    Cross_host_probe] which is the order most-specific first. *)
let classify_repo_wide_discovery cmd =
  if command_looks_like_worktree_discovery cmd then Some Worktree_discovery
  else if command_looks_like_cross_repo_grep cmd then Some Cross_repo_grep
  else if command_looks_like_cross_host_probe cmd then Some Cross_host_probe
  else None
