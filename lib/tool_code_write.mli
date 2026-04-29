(** Tool_code_write — File write / edit / delete / shell / git
    MCP tools for keeper agents.

    Sister module to {!Tool_code} (cycle 172, the read-side
    security gate).  All path validation reuses
    {!Tool_code.normalize_agent_relative_path} +
    {!Tool_code.validate_path}; the additional sandbox check
    here is what distinguishes write from read.

    Security model (pinned at module level):

    - Write operations restricted to allowed sandboxes
      ([.worktrees/] checkouts AND keeper playground clones —
      per-agent gated, see #6527 iter 6).
    - Shell commands restricted to a hard-coded allowlist.
    - Git push to main/master blocked.
    - Git clone restricted to allowed GitHub orgs (configured
      via [config/tool_policy.toml]) with optional repo-level
      deny list.
    - File size limit: 1 MiB ({!max_write_size}) for writes.
    - Binary file extension check inherited from
      {!Tool_code.is_binary_file}.

    Internal: ~28 helpers + 1 cache cell stay private —
    \[max_write_size] (1 MiB literal), \[normalize_dir_prefix],
    \[first_nonempty_line], \[allowed_shell_commands] data table,
    \[git_common_root], \[dedupe_keep_order],
    \[allowed_worktree_prefixes],
    \[git_action_to_string] / \[git_action_of_string_opt] /
    \[all_git_actions] (variant SSOT helpers — drift in any one
    forces compile error in the others, #8522), output truncation
    primitives (\[max_output_bytes], \[max_output_label],
    \[truncate_output]), the [_policy_config_cache] mutable cell
    + \[get_policy_config] / \[load_clone_allowed_orgs] /
    \[load_clone_denied_repos] policy loaders, and 6 per-tool
    handlers ([handle_code_write], [handle_code_edit],
    [handle_code_delete], [handle_code_shell],
    [handle_code_git], plus a clone-action sub-handler).  All
    consumed only inside {!dispatch}'s pipeline. *)

(** {1 Tool result + context} *)

type context = {
  config : Coord.config;
  agent_name : string;
}
(** Per-call context.  Concrete record because callers
    ([mcp_server_eio_execute], [keeper_tag_dispatch]) construct
    via [{ Tool_code_write.config; agent_name }] at the
    dispatch site. *)

type tool_result = bool * string

(** {1 Git action SSOT (issue #8522)} *)

(** Variant SSOT for git actions.  Adding a constructor forces
    compile errors in [git_action_to_string] AND extends
    {!valid_git_action_strings} via [List.map]; the schema enum
    derives from the SSOT, the allowlist {!allowed_git_actions}
    IS the SSOT (no separate hand-list), and downstream inline
    checks pattern-match on the variant for [push --force] and
    [clone] special paths. *)
type git_action =
  | Add
  | Commit
  | Push
  | Diff
  | Status
  | Log
  | Branch
  | Checkout
  | Stash
  | Fetch
  | Clone

val valid_git_action_strings : string list
(** [valid_git_action_strings] is the canonical lowercase label
    list (one per {!git_action} constructor: ["add"], ["commit"],
    ["push"], ["diff"], ["status"], ["log"], ["branch"],
    ["checkout"], ["stash"], ["fetch"], ["clone"]).  Used by
    error messages + the [masc_code_git] schema [enum] field —
    adding a constructor automatically updates both. *)

val allowed_git_actions : string list
(** Alias for {!valid_git_action_strings} pinned at the contract
    seam — the variant SSOT IS the allowlist (no separate
    hand-curated list to drift). *)

(** {1 Path + command validation} *)

val validate_writable_path :
  agent_name:string ->
  Coord.config ->
  string ->
  (string, Masc_error.t) result
(** [validate_writable_path ~agent_name config path] is the
    write-side sandbox gate:

    + Apply {!Tool_code.normalize_agent_relative_path} +
      {!Tool_code.validate_path} (git-root containment + symlink
      resolution).
    + Accept canonical paths inside an [allowed_worktree_prefix]
      (server-wide [.worktrees/] paths anchored at actual git
      common roots — drift to "any /.worktrees/ segment" would
      false-accept nested paths).
    + Accept canonical paths inside the agent's own playground
      bundle ([{base_path}/.masc/playground/{agent_name}/]).
    + Reject everything else with operator-readable error
      including the expected prefix + got path.

    Per-agent playground gating (#6527 iter 6) prevents one
    agent from mutating another agent's playground via the
    shared [masc_code_*] dispatch — pinned at the contract
    seam.  Server-wide [.worktrees/] remains allowed for
    legacy server operations. *)

val validate_code_shell_command :
  string -> (unit, string) result
(** [validate_code_shell_command command] delegates to
    {!Worker_dev_tools.validate_command_coding_with_allowlist}
    with [~allow_pipes:true] and the pinned
    [allowed_shell_commands] list (dune, make, npm/npx/node,
    git, ls, cat, head, tail, wc, rg, find, diff, patch, mkdir,
    opam, ocamlfind, tsc).  Drift in the allowlist changes the
    keeper sandbox surface — pinned at the contract seam. *)

(** {1 Git clone validation} *)

val extract_github_org : string -> string option
(** [extract_github_org url] parses the org segment from a
    GitHub clone URL:

    - [https://github.com/ORG/repo\[.git\]]
    - [git@github.com:ORG/repo\[.git\]]
    - [ssh://git@github.com/ORG/repo\[.git\]]

    Returns [None] when the URL does not match a recognised
    prefix OR the org segment contains characters outside
    [\[a-z0-9\-\]] (case-insensitive input is lowercased at
    parse time).  Restrictive validation prevents allowlist
    bypass via crafted hostnames. *)

val extract_github_org_repo : string -> string option
(** [extract_github_org_repo url] is similar to
    {!extract_github_org} but returns ["org/repo"] (lowercased,
    [.git] suffix and trailing slash stripped).  Returns [None]
    when the path is not exactly two segments — deeper paths
    are rejected so org-level allow + repo-level deny lookups
    cannot be confused by sub-paths. *)

val validate_clone_url :
  base_path:string -> string -> (unit, string) result
(** [validate_clone_url ~base_path url] validates the URL
    against the policy at
    [{base_path}/config/tool_policy.toml]:

    + Empty allowed-orgs list -> [Error] (no clones permitted
      until configured).
    + Org from {!extract_github_org} not in
      [git_clone.allowed_orgs] -> [Error].
    + ["org/repo"] from {!extract_github_org_repo} present in
      the policy's denied list -> [Error].
    + All checks pass -> [Ok ()].

    Operator-readable errors include the offending segment and
    the allowed list when applicable. *)

val validate_clone_cwd :
  agent_name:string ->
  Coord.config ->
  string ->
  (string, Masc_error.t) result
(** [validate_clone_cwd ~agent_name config cwd] gates the clone
    target directory:

    + Allow [.worktrees/] itself OR any sub-path under it
      (anchored at the actual git common root).
    + Allow this agent's
      [.masc/playground/{agent_name}/repos/] (or sub-paths).
    + Reject everything else, including other agents'
      playgrounds (#6527 iter 6 cross-agent block).

    Errors include the expected prefix + the offending
    canonical path + the resolved [agent_name] so operators can
    diagnose without re-running the tool. *)

val reset_policy_config_cache : unit -> unit
(** [reset_policy_config_cache ()] clears the cached
    [Keeper_tool_policy_config.t].  Used by tests to re-load
    after writing a new [tool_policy.toml] in a fixture
    directory.  Production code does NOT need to call this —
    the cache is process-wide and policy changes require a
    server restart by design. *)

(** {1 Dispatch + schema} *)

val dispatch :
  context ->
  name:string ->
  args:Yojson.Safe.t ->
  tool_result option
(** [dispatch ctx ~name ~args] routes [name] to the appropriate
    private handler ([handle_code_write], [handle_code_edit],
    [handle_code_delete], [handle_code_shell],
    [handle_code_git]).  Returns [None] when [name] is not a
    code-write tool — caller treats as "not my tool". *)

val schemas : Types.tool_schema list
(** [schemas] is the [Types.tool_schema list] consumed by
    {!Tools.schemas} / {!Config.visible_tool_schemas}.  Used by
    the side-effect [Tool_spec.register] block at module load. *)

val tool_names : string list
(** [tool_names] is the canonical list of tool names registered
    by this module ([masc_code_write], [masc_code_edit],
    [masc_code_delete], [masc_code_shell], [masc_code_git]).
    Used by upstream catalogs that need to enumerate this
    module's contributions without parsing schemas. *)
