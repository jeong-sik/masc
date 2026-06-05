(** {1 Path resolution} *)

val resolve_tool_read_cwd :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  (string, string) result

val resolve_tool_write_cwd :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  (string, string) result
(** Resolve an Execute cwd inside the keeper write boundary. This is path
    resolution only: it never creates directories or changes repo/worktree
    state. *)

val resolve_tool_readonly_execute_cwd :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  (string, string) result
(** Resolve typed Execute cwd for readonly profiles. This preserves Execute cwd
    path semantics for explicit cwd values, but the omitted-cwd default computes
    the keeper playground root without creating the sandbox bundle. *)

type repo_path_context =
  { path_repo_name : string
  ; path_repo_root : string
  ; path_root : string
  ; accepted_toplevels : string list
  }
(** Path-only facts for any path inside a keeper sandbox repo. [path_root] is
    the expected git toplevel for the path: either the in-place clone root or a
    selected worktree root. *)

val repo_path_context :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  path:string ->
  repo_path_context option
(** Classify [path] as a keeper sandbox repo path. This performs no git probes
    and no repo setup. *)

type repo_cwd_context =
  { repo_name : string
  ; repo_root : string
  ; path_root : string
  ; is_direct_root : bool
  }
(** Path-only facts for a cwd inside a keeper sandbox repo. [path_root] is the
    selected git toplevel expected for the cwd: either [repo_root] or a worktree
    root. *)

val repo_cwd_context :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  cwd:string ->
  repo_cwd_context option
(** Classify [cwd] as a keeper sandbox repo cwd. This reports path facts only;
    callers own command-shape and write-gate policy. *)

val execution_location_json :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  cwd:string ->
  Yojson.Safe.t
(** Structured cwd contract for Execute responses.  The JSON tells the agent
    whether the effective cwd is inside the keeper playground
    ([playground_root], [playground_subpath], [repo_root], [repo_subpath],
    [repo_worktree_root], [repo_worktree_subpath]) or outside it
    ([outside_playground]).  [relative_cwd] is relative to [playground_root]
    for playground scopes and [null] when the cwd is outside the playground.
    Relative argv paths resolve against the effective cwd.  Worktree scopes also
    carry [worktree_selected] and [selected_worktree] so the keeper can observe
    the selected repo/worktree assignment without reparsing [cwd]. *)

val auto_correct_path :
  meta:Keeper_meta_contract.keeper_meta -> string -> string option
(** Auto-correct common LLM-hallucinated path prefixes
    ([/repos/…], [repos/…], [playground/…]) into the keeper's
    real playground bundle path.  Sanitization of [meta.name]
    happens through {!Playground_paths}. *)

val resolve_tool_read_path :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  (string, string) result
(** Resolve the [path] arg against the keeper's read root, with
    {!auto_correct_path} as a fallback when the initial resolution
    fails.  Guards against playground-prefix doubling when both
    [cwd] and [path] independently include the playground prefix. *)

val shell_command_available : string -> bool
(** PATH executable probe for workspace read fallback selection.
    This intentionally avoids [/bin/sh -c] and does not treat empty
    PATH entries as the current directory. *)

val in_playground :
  root:string -> cwd:string -> meta:Keeper_meta_contract.keeper_meta -> bool
(** [true] when [cwd] is inside the keeper's sandbox playground,
    or equal to it.  Normalises both paths before comparison so that
    trailing slashes do not affect the result. *)
