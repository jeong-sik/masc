(** Keeper shell command semantics.

    Pure command-shape and cwd policy helpers shared by Local/Docker shell
    dispatch. This module does not execute commands and does not know how
    Docker is launched. *)

val cmd_targets_git_or_gh : string -> bool
(** [true] only when the typed bash subset parser identifies an effective
    command stage whose executable is [git] or [gh]. Parse failures and
    unsupported shell constructs fail closed as [false]. *)

val cmd_targets_gh : string -> bool
(** [true] only when the typed bash subset parser identifies an effective
    command stage whose executable is [gh]. *)

val detect_gh_repo_flag_with_api_misuse : string -> (string * string) option
(** Detect the invalid [gh --repo <repo> api <endpoint>] shape.  [--repo]
    is a subcommand flag, not a [gh api] global option. *)

val resolve_sandbox_root_git_cwd :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  cwd:string ->
  cmd:string ->
  string * string option
