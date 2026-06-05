(** Execute command semantics.

    This module owns keeper-specific cwd policy and user-facing command
    guidance. Pure Shell IR command-shape extraction lives in
    {!Masc_exec.Shell_ir_command_shape}; callers pass [Shell_ir.t] rather than
    stage lists so the Shell IR boundary stays explicit. *)

val repo_hosting_cli_repo_flag_api_misuse :
  Masc_exec.Shell_ir.t -> (string * string) option
(** Detect the invalid [gh --repo <repo> api <endpoint>] shape from
    pre-parsed Shell IR. *)

val gh_pr_diff_misuse :
  Masc_exec.Shell_ir.t -> string list option
(** Detect invalid [gh pr diff] usage with file filters or extra positional args. *)

val cmd_prefix : string -> string
(** Return the leading command token used for user-facing Execute guidance. *)

val misuse_error : Masc_exec.Shell_ir.t -> string option
(** Perform all command syntax misuse checks and return a descriptive error message if any. *)

val resolve_sandbox_root_git_cwd :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  cwd:string ->
  cmd:string ->
  Masc_exec.Shell_ir.t ->
  string * string option
(** Resolve deterministic sandbox-root git/gh cwd policy from pre-parsed Shell
    IR. The command shape comes from {!Masc_exec.Shell_ir_command_shape}; this
    function adds keeper cwd, sandbox, and filesystem context. *)
