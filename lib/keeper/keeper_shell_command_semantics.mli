(** Keeper shell command semantics.

    Pure command-shape and cwd policy helpers shared by Local/Docker shell
    dispatch. This module does not execute commands and does not know how
    Docker is launched.

    IR-first variants ([parsed_stages_of_ir], [effective_stages_of_ir])
    accept pre-parsed [Shell_ir.t] and skip re-parsing.  The string-based
    counterparts are retained as bridges for callers that only have strings. *)

type parsed_stage = { bin : string; args : string list }

val parsed_stages_of_ir : Masc_exec.Shell_ir.t -> parsed_stage list
(** Extract literal command stages from a pre-parsed Shell IR. *)

val effective_stages_of_ir : Masc_exec.Shell_ir.t -> parsed_stage list
(** Extract effective command stages (after env/opam unwrap) from a
    pre-parsed Shell IR. *)

val cmd_targets_git_or_gh : string -> bool
(** [true] only when the typed bash subset parser identifies an effective
    command stage whose executable is [git] or [gh]. Parse failures and
    unsupported shell constructs fail closed as [false]. *)

val cmd_targets_gh : string -> bool
(** [true] only when the typed bash subset parser identifies an effective
    command stage whose executable is [gh]. *)

val cmd_prefix : string -> string
(** Prefix used for shell-history grouping. Uses the same typed bash subset
    parser and effective-command wrapper handling as command-shape policy.
    Unsupported command shapes fall back to the trimmed original command. *)

val detect_gh_repo_flag_with_api_misuse : string -> (string * string) option
(** Detect the invalid [gh --repo <repo> api <endpoint>] shape.  [--repo]
    is a subcommand flag, not a [gh api] global option. *)

val resolve_sandbox_root_git_cwd :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  cwd:string ->
  cmd:string ->
  string * string option

val resolve_sandbox_root_git_cwd_of_stages :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  cwd:string ->
  cmd:string ->
  parsed_stage list ->
  string * string option
(** Pre-computed stages variant of [resolve_sandbox_root_git_cwd].
    Callers that already hold [effective_stages_of_ir ir] pass them
    directly to avoid re-parsing. *)
